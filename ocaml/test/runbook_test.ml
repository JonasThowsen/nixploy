open Async
open Core
open Nixploy

let assert_ok = Or_error.ok_exn
let target = Target_name.of_string "production" |> assert_ok
let container_id = String.make 64 'a'
let literal_argv = [ "/app/bin/app"; "migrate"; ""; "$(touch nope); * ' \"" ]

let config ?(web = false) ?(interactive = false) () =
  let command =
    `Assoc
      [
        ("description", `String "Migrate");
        ("command", `List (List.map literal_argv ~f:(fun x -> `String x)));
        ("interactive", `Bool interactive);
      ]
  in
  `Assoc
    [
      ("__schema", `String "v0.5");
      ("project", `String "example");
      ( "targets",
        `Assoc
          [
            ( "production",
              `Assoc
                ([
                   ("image", `String "worker");
                   ("ip", `String "test.invalid");
                   ("user", `String "deploy");
                   ("runbook", `Assoc [ ("migrate", command) ]);
                 ]
                @
                if web then
                  [
                    ("web", `Assoc [ ("domain", `String "app.example.invalid") ]);
                  ]
                else []) );
          ] );
    ]
  |> Yojson.Safe.to_string

let command_from json =
  Configuration.of_json json |> assert_ok |> fun configuration ->
  Configuration.find_target configuration target
  |> assert_ok |> Configuration.Target.runbook |> List.hd_exn

let configuration_tests () =
  let command = command_from (config ()) in
  [%test_eq: string list] literal_argv
    (Configuration.Runbook_command.command command);
  assert (not (Configuration.Runbook_command.interactive command));
  [%test_eq: string list]
    ([ "--connection"; "owned"; "exec"; "--"; container_id ] @ literal_argv)
    (Podman.For_testing.runbook_argv ~connection:"owned" ~container_id ~command);
  [%test_eq: string list]
    ([
       "--connection";
       "owned";
       "exec";
       "--interactive";
       "--tty";
       "--";
       container_id;
     ]
    @ literal_argv)
    (Podman.For_testing.runbook_argv ~connection:"owned" ~container_id
       ~command:(command_from (config ~interactive:true ())));
  let invalid_runbooks =
    [
      {|{"migrate":{"command":["app"]}}|};
      {|{"migrate":{"description":"","command":["app"]}}|};
      {|{"migrate":{"description":"x","command":[]}}|};
      {|{"migrate":{"description":"x","command":[""]}}|};
      {|{"migrate":{"description":"x","command":["app","\u0000"]}}|};
      {|{"migrate":{"description":"\u0000","command":["app"]}}|};
      {|{"migrate":{"description":"x","command":["app"],"interactive":"true"}}|};
      {|{"migrate":{"description":"x","command":["app"],"shell":true}}|};
      {|{"migrate":{"description":"x","command":["app"],"command":["other"]}}|};
      {|{"-bad":{"description":"x","command":["app"]}}|};
      {|{"Bad":{"description":"x","command":["app"]}}|};
      {|{"migrate":{"description":"x","command":["app"]},"migrate":{"description":"x","command":["other"]}}|};
    ]
  in
  List.iter invalid_runbooks ~f:(fun runbook ->
      let json =
        sprintf
          {|{"__schema":"v0.5","project":"example","targets":{"production":{"image":"worker","ip":"test.invalid","runbook":%s}}}|}
          runbook
      in
      assert (Result.is_error (Configuration.of_json json)));
  let default =
    {|{"__schema":"v0.5","project":"example","targets":{"production":{"image":"worker","ip":"test.invalid"}}}|}
  in
  ignore (Configuration.of_json default |> assert_ok : Configuration.t);
  let legacy =
    String.substr_replace_all default ~pattern:"v0.5" ~with_:"v0.4"
  in
  ignore (Configuration.of_json legacy |> assert_ok : Configuration.t);
  assert (
    Result.is_error
      (Configuration.of_json
         (String.substr_replace_all (config ()) ~pattern:"v0.5" ~with_:"v0.4")));
  let managed =
    String.substr_replace_all default ~pattern:{|"project":"example"|}
      ~with_:
        {|"project":"example","controlPlane":{"authorityAlias":"old","managedApplicationKey":"example"}|}
  in
  assert (
    Result.is_error
      (Configuration.require_daemonless
         (Configuration.of_json managed |> assert_ok)))

let write_executable path contents =
  Out_channel.write_all path ~data:contents;
  Core_unix.chmod path ~perm:0o755

let with_guard _ f =
  let directory = Sys.getenv_exn "RUNBOOK_FIXTURE" in
  let guard = Filename.concat directory "guard" in
  if String.equal (Sys.getenv_exn "RUNBOOK_CASE") "guard-refused" then
    Deferred.Or_error.error_string "runbook test guard conflict"
  else (
    assert (not (Sys_unix.file_exists_exn guard));
    Out_channel.write_all guard ~data:"held";
    Monitor.protect f ~finally:(fun () -> Async.Unix.unlink guard))

let probe () =
  let directory = Sys.getenv_exn "RUNBOOK_FIXTURE" in
  let guard = Filename.concat directory "guard" in
  let on_selection (selection : Runbook.selection) =
    assert (Sys_unix.file_exists_exn guard);
    eprintf "selected:%s:%s\n%!" selection.container_name selection.container_id;
    Deferred.unit
  in
  if String.equal (Sys.getenv_exn "RUNBOOK_MODE") "list" then (
    let%map result = Runbook.list ~working_directory:directory ~target in
    let commands = assert_ok result in
    printf "%s\n%!" (Configuration.Runbook_command.name (List.hd_exn commands));
    0)
  else
    let%map result =
      Runbook.run ~with_guard ~on_selection ~working_directory:directory ~target
        ~name:(Option.value (Sys.getenv "RUNBOOK_NAME") ~default:"migrate")
    in
    match result with
    | Error error ->
        eprintf "ERROR:%s\n%!" (Error.to_string_hum error);
        70
    | Ok outcome ->
        Option.iter outcome.uncertainty ~f:(fun message ->
            eprintf "UNCERTAIN:%s\n%!" message);
        outcome.exit_code

let integration_tests () =
  let open Deferred.Let_syntax in
  let directory = Filename_unix.temp_dir "nixploy-runbook-test-" "" in
  let fake_bin = Filename.concat directory "bin" in
  Core_unix.mkdir fake_bin;
  let git args =
    Process_runner.run_stdout ~working_directory:directory
      ~timeout:(Time_ns.Span.of_sec 10.) ~max_output_bytes:65536 ~prog:"git"
      ~args ()
    >>| assert_ok
  in
  let%bind _ = git [ "init"; "-q" ] in
  let%bind _ =
    git [ "remote"; "add"; "origin"; "https://example.invalid/app.git" ]
  in
  let repository_identity = "https://example.invalid/app.git" in
  let project = Project_name.of_string "example" |> assert_ok in
  let key =
    Resource_key.derive ~project ~target ~repository_identity
    |> assert_ok |> Resource_key.to_string
  in
  let legacy_key =
    Resource_key.derive_current ~project ~target
    |> assert_ok |> Resource_key.to_string
  in
  let labels key =
    `Assoc
      [
        ("io.nixploy.managed", `String "true");
        ("io.nixploy.project", `String "example");
        ("io.nixploy.target", `String "production");
        ("io.nixploy.resource_key", `String key);
        ("io.nixploy.repository_identity", `String repository_identity);
      ]
  in
  Out_channel.write_all
    (Filename.concat directory "ambiguous.json")
    ~data:
      (`List
         (List.map [ key; legacy_key ] ~f:(fun key ->
              `Assoc [ ("Labels", labels key) ]))
      |> Yojson.Safe.to_string);
  write_executable
    (Filename.concat fake_bin "nix")
    {|#!/bin/sh
set -eu
[ "$*" = "eval --json --no-update-lock-file --no-write-lock-file .#nixploy" ] || exit 91
cat "$RUNBOOK_FIXTURE/config.json"
|};
  write_executable
    (Filename.concat fake_bin "ssh")
    {|#!/bin/sh
set -eu
[ -e "$RUNBOOK_FIXTURE/guard" ] || exit 92
printf '%s\n' "$*" >> "$RUNBOOK_FIXTURE/ssh-log"
case "$*" in
  *StrictHostKeyChecking=yes*) :;; *) exit 93;;
esac
case "$*" in
  *"'podman' 'ps'"*)
    if [ "$RUNBOOK_CASE" = ambiguous ]; then cat "$RUNBOOK_FIXTURE/ambiguous.json"; else printf '[]\n'; fi;;
  *"/upstreams"*)
    if [ "$RUNBOOK_CASE" = upstream ]; then printf '[{"dial":"127.0.0.1:8080"},{"dial":"127.0.0.1:8081"}]\n200';
    else printf '[{"dial":"127.0.0.1:%s"}]\n200' "$RUNBOOK_PORT"; fi;;
  *"nixploy-route-"*)
    if [ "$RUNBOOK_CASE" = route-missing ]; then printf '{}\n404'; else cat "$RUNBOOK_FIXTURE/route.json"; printf '\n200'; fi;;
  *"'true'"*) :;;
  *) exit 94;;
esac
|};
  write_executable
    (Filename.concat fake_bin "podman")
    {|#!/bin/sh
set -eu
[ -e "$RUNBOOK_FIXTURE/guard" ] || exit 92
case "$*" in
  "system connection list --format json") printf '[]\n';;
  "system connection add "*) :;;
  *" info") :;;
  *" inspect --type container "*)
    for name in "$@"; do :; done
    if [ "$RUNBOOK_CASE" = missing ]; then printf '[]\n'; exit 0; fi
    repository='https://example.invalid/app.git'
    [ "$RUNBOOK_CASE" != foreign ] || repository='foreign'
    running=true
    [ "$RUNBOOK_CASE" != stopped ] || running=false
    printf '[{"Id":"%s","Name":"%s","State":{"Running":%s},"Config":{"Labels":{"io.nixploy.managed":"true","io.nixploy.project":"example","io.nixploy.target":"production","io.nixploy.resource_key":"%s","io.nixploy.repository_identity":"%s","io.nixploy.revision":"deployed-revision","io.nixploy.operation_id":"op"}}}]' "$RUNBOOK_ID" "$name" "$running" "$RUNBOOK_KEY" "$repository";;
  *" exec "*)
    printf 'exec\n' >> "$RUNBOOK_FIXTURE/exec-log"
    [ "$1" = --connection ]; shift 2
    [ "$1" = exec ]; shift
    if [ "$RUNBOOK_CASE" = tty ]; then
      [ "$1" = --interactive ]; shift
      [ "$1" = --tty ]; shift
    fi
    [ "$1" = -- ]; shift
    [ "$1" = "$RUNBOOK_ID" ]; shift
    [ "$1" = /app/bin/app ]; shift
    [ "$1" = migrate ]; shift
    [ "$1" = '' ]; shift
    [ "$1" = '$(touch nope); * '\'' "' ]; shift
    [ "$#" = 0 ]
    if [ "$RUNBOOK_CASE" = tty ]; then
      [ -t 0 ] && [ -t 1 ]
      read -r input
      [ "$input" = console-input ]
      printf 'tty-input-received\n'
    else
      [ ! -t 0 ]
      read -r input && exit 95
    fi
    printf 'runbook-out\n'
    printf 'runbook-err\n' >&2
    if [ "$RUNBOOK_CASE" = stream ] || [ "$RUNBOOK_CASE" = interrupt ]; then
      while [ ! -e "$RUNBOOK_FIXTURE/release" ]; do sleep 0.02; done
    fi
    exit "$RUNBOOK_EXIT";;
  *) printf 'unexpected podman argv\n' >&2; exit 96;;
esac
|};
  let route ~domain ~route_key =
    sprintf
      {|{"@id":"nixploy-route-%s","terminal":true,"match":[{"host":["%s"]}],"handle":[{"handler":"subroute","routes":[{"handle":[{"@id":"nixploy-proxy-%s","handler":"reverse_proxy"}]}]}]}|}
      route_key domain key
  in
  let environment ?(web = false) ?(interactive = false) ?(mode = "run")
      ?(name = "migrate") ?(domain = "app.example.invalid") ?(route_key = key)
      ?(port = "8080") ?(exit = 0) case =
    Out_channel.write_all
      (Filename.concat directory "config.json")
      ~data:(config ~web ~interactive ());
    Out_channel.write_all
      (Filename.concat directory "route.json")
      ~data:(route ~domain ~route_key);
    Out_channel.write_all (Filename.concat directory "exec-log") ~data:"";
    Out_channel.write_all (Filename.concat directory "ssh-log") ~data:"";
    `Extend
      [
        ("PATH", fake_bin ^ ":" ^ Sys.getenv_exn "PATH");
        ("RUNBOOK_FIXTURE", directory);
        ("RUNBOOK_KEY", key);
        ("RUNBOOK_ID", container_id);
        ("RUNBOOK_MODE", mode);
        ("RUNBOOK_NAME", name);
        ("RUNBOOK_CASE", case);
        ("RUNBOOK_PORT", port);
        ("RUNBOOK_EXIT", Int.to_string exit);
      ]
  in
  let run ?web ?interactive ?mode ?name ?domain ?route_key ?port ?exit case =
    Process_runner.run ~timeout:(Time_ns.Span.of_sec 15.)
      ~max_output_bytes:65536
      ~env:
        (environment ?web ?interactive ?mode ?name ?domain ?route_key ?port
           ?exit case)
      ~prog:Sys_unix.executable_name ~args:[ "--probe" ] ()
    >>| assert_ok
  in
  let exec_count () =
    In_channel.read_lines (Filename.concat directory "exec-log") |> List.length
  in
  let%bind listed = run ~mode:"list" "ok" in
  [%test_eq: string] "migrate\n" listed.stdout;
  assert (exec_count () = 0);
  assert (
    String.is_empty (In_channel.read_all (Filename.concat directory "ssh-log")));
  let%bind refused = run "guard-refused" in
  assert (String.is_substring refused.stderr ~substring:"guard conflict");
  assert (exec_count () = 0);
  assert (
    String.is_empty (In_channel.read_all (Filename.concat directory "ssh-log")));
  let%bind completed = run ~exit:23 "ok" in
  assert (Poly.equal completed.exit_status (Error (`Exit_non_zero 23)));
  [%test_eq: string] "runbook-out\n" completed.stdout;
  assert (String.is_substring completed.stderr ~substring:"runbook-err\n");
  assert (
    String.is_substring completed.stderr
      ~substring:("selected:" ^ key ^ ":" ^ container_id));
  assert (exec_count () = 1);
  let%bind () =
    Deferred.List.iter ~how:`Sequential [ "stream"; "interrupt" ]
      ~f:(fun case ->
        let%bind created =
          Process.create ~env:(environment case) ~prog:Sys_unix.executable_name
            ~args:[ "--probe" ] ()
        in
        let child = assert_ok created in
        let%bind () = Writer.close (Process.stdin child) in
        let wait = Process.wait child in
        let read_line reader =
          Clock_ns.with_timeout (Time_ns.Span.of_sec 10.)
            (Reader.read_line reader)
          >>| function
          | `Result (`Ok line) -> line
          | _ -> failwith "stream was not delivered before child completion"
        in
        let%bind stdout = read_line (Process.stdout child) in
        [%test_eq: string] "runbook-out" stdout;
        let%bind selection = read_line (Process.stderr child) in
        assert (String.is_prefix selection ~prefix:"selected:");
        let%bind stderr = read_line (Process.stderr child) in
        [%test_eq: string] "runbook-err" stderr;
        assert (not (Deferred.is_determined wait));
        if String.equal case "interrupt" then
          Signal_unix.send_i Signal.term (`Pid (Process.pid child))
        else
          Out_channel.write_all
            (Filename.concat directory "release")
            ~data:"release";
        let%bind remaining = Reader.contents (Process.stderr child) in
        let%bind status = wait in
        assert (exec_count () = 1);
        let%bind () = Reader.close (Process.stdout child) in
        if String.equal case "interrupt" then (
          assert (Result.is_error status);
          assert (
            String.is_substring remaining
              ~substring:"remote command may still be running");
          Deferred.unit)
        else (
          assert (Result.is_ok status);
          Async.Unix.unlink (Filename.concat directory "release")))
  in
  let%bind tty =
    Process_runner.run ~timeout:(Time_ns.Span.of_sec 15.)
      ~max_output_bytes:65536
      ~env:(environment ~interactive:true "tty")
      ~stdin:"console-input\n" ~prog:"script"
      ~args:
        [
          "-q";
          "-e";
          "-c";
          Filename.quote Sys_unix.executable_name ^ " --probe";
          "/dev/null";
        ]
      ()
  in
  let tty = assert_ok tty in
  assert (Result.is_ok tty.exit_status);
  assert (String.is_substring tty.stdout ~substring:"tty-input-received");
  assert (exec_count () = 1);
  let%bind () =
    Deferred.List.iter ~how:`Sequential
      [ ("8080", "blue"); ("8081", "green") ]
      ~f:(fun (port, slot) ->
        let%map completed = run ~web:true ~port "ok" in
        assert (Result.is_ok completed.exit_status);
        assert (
          String.is_substring completed.stderr
            ~substring:("selected:" ^ key ^ "-" ^ slot ^ ":"));
        assert (exec_count () = 1))
  in
  let%bind () =
    Deferred.List.iter ~how:`Sequential
      [ "missing"; "foreign"; "stopped"; "ambiguous" ] ~f:(fun case ->
        let%map failed = run case in
        assert (Result.is_error failed.exit_status);
        assert (exec_count () = 0))
  in
  let%bind () =
    Deferred.List.iter ~how:`Sequential [ "route-missing"; "upstream" ]
      ~f:(fun case ->
        let%map failed = run ~web:true case in
        assert (Result.is_error failed.exit_status);
        assert (exec_count () = 0))
  in
  let%bind wrong_domain = run ~web:true ~domain:"foreign.invalid" "ok" in
  assert (Result.is_error wrong_domain.exit_status);
  assert (exec_count () = 0);
  let%bind wrong_route = run ~web:true ~route_key:"foreign" "ok" in
  assert (Result.is_error wrong_route.exit_status);
  assert (exec_count () = 0);
  let%bind invalid_port = run ~web:true ~port:"9999" "ok" in
  assert (Result.is_error invalid_port.exit_status);
  assert (exec_count () = 0);
  let%bind interactive = run ~interactive:true "ok" in
  assert (String.is_substring interactive.stderr ~substring:"requires attached");
  assert (exec_count () = 0);
  assert (
    String.is_empty (In_channel.read_all (Filename.concat directory "ssh-log")));
  let%bind undeclared = run ~name:"undeclared" "ok" in
  assert (String.is_substring undeclared.stderr ~substring:"not declared");
  assert (exec_count () = 0);
  let%bind transport = run ~exit:125 "ok" in
  assert (Poly.equal transport.exit_status (Error (`Exit_non_zero 125)));
  assert (String.is_substring transport.stderr ~substring:"UNCERTAIN:");
  assert (exec_count () = 1);
  let cli_run args =
    Process_runner.run ~timeout:(Time_ns.Span.of_sec 15.)
      ~max_output_bytes:65536
      ~env:(environment ~exit:23 "ok")
      ~prog:Sys_unix.executable_name ~args:("--cli" :: args) ()
    >>| assert_ok
  in
  let%bind cli_list =
    cli_run [ "runbook"; "-t"; "production"; "-C"; directory; "--json" ]
  in
  assert (Result.is_ok cli_list.exit_status);
  assert (String.is_substring cli_list.stdout ~substring:{|"name":"migrate"|});
  assert (exec_count () = 0);
  let%bind cli_exec =
    cli_run [ "run"; "-t"; "production"; "-C"; directory; "migrate" ]
  in
  assert (Poly.equal cli_exec.exit_status (Error (`Exit_non_zero 23)));
  [%test_eq: string] "runbook-out\n" cli_exec.stdout;
  assert (
    String.is_substring cli_exec.stderr
      ~substring:"deployed revision deployed-revision");
  assert (exec_count () = 1);
  let%bind cli_extra =
    cli_run [ "run"; "-t"; "production"; "-C"; directory; "migrate"; "extra" ]
  in
  assert (Result.is_error cli_extra.exit_status);
  assert (exec_count () = 0);
  let%bind cli_no_target = cli_run [ "runbook"; "-C"; directory ] in
  assert (Result.is_error cli_no_target.exit_status);
  assert (exec_count () = 0);
  printf "runbook tests passed (fixture %s)\n%!" directory;
  Deferred.unit

let streaming_terminal_probe () =
  let directory = Sys.getenv_exn "RUNBOOK_TERMINAL_FIXTURE" in
  let token = Cancellation.create () in
  let double_signal = Bool.of_string (Sys.getenv_exn "RUNBOOK_DOUBLE_SIGNAL") in
  let rec await_cancel () =
    if Sys_unix.file_exists_exn (Filename.concat directory "cancel") then (
      ignore (Cancellation.request token : Cancellation.request);
      Deferred.unit)
    else
      let%bind () = Clock_ns.after (Time_ns.Span.of_ms 10.) in
      await_cancel ()
  in
  if not double_signal then don't_wait_for (await_cancel ());
  Out_channel.write_all
    (Filename.concat directory "parent.pid")
    ~data:(Pid.to_string (Core_unix.getpid ()));
  let%map result =
    Cancellation.within token (fun () ->
        Process_runner.run_streaming ~interactive:true ~prog:"sh"
          ~args:[ Filename.concat directory "client.sh" ]
          ())
  in
  assert (Result.is_error result);
  assert (Cancellation.was_acknowledged token);
  assert (
    String.is_substring
      (Error.to_string_hum (Result.error result |> Option.value_exn))
      ~substring:"remote command may still be running");
  0

let wait_for_fixture_file path =
  let rec loop () =
    if Sys_unix.file_exists_exn path then Deferred.unit
    else
      let%bind () = Clock_ns.after (Time_ns.Span.of_ms 10.) in
      loop ()
  in
  Clock_ns.with_timeout (Time_ns.Span.of_sec 10.) (loop ()) >>| function
  | `Result () -> ()
  | `Timeout -> failwithf "fixture did not become ready: %s" path ()

let streaming_terminal_test ~double_signal =
  let directory = Filename_unix.temp_dir "runbook-terminal-" "" in
  let file name = Filename.concat directory name in
  Out_channel.write_all (file "client.sh")
    ~data:
      {|set -eu
stty raw -echo
echo $$ > "$RUNBOOK_TERMINAL_FIXTURE/client.pid"
if [ "$RUNBOOK_DOUBLE_SIGNAL" = true ]; then trap '' TERM; else trap 'exit 130' TERM; fi
sh -c 'trap "" TERM; echo ready > "$RUNBOOK_TERMINAL_FIXTURE/ready"; while :; do sleep 1; done' &
echo $! > "$RUNBOOK_TERMINAL_FIXTURE/descendant.pid"
wait
|};
  Out_channel.write_all (file "supervisor.sh")
    ~data:
      {|set -u
before=$(stty -g)
"$RUNBOOK_TEST_EXE" --terminal-probe
status=$?
after=$(stty -g)
if [ "$before" != "$after" ]; then
  stty "$before"
  echo 'raw terminal leaked' >&2
  exit 90
fi
if [ "$RUNBOOK_DOUBLE_SIGNAL" = true ]; then
  [ "$status" = 143 ] || exit 91
else
  [ "$status" = 0 ] || exit 92
fi
echo terminal-restored
|};
  let%bind created =
    Process.create ~prog:"script"
      ~args:
        [
          "-q";
          "-e";
          "-c";
          "sh " ^ Filename.quote (file "supervisor.sh");
          "/dev/null";
        ]
      ~env:
        (`Extend
           [
             ("RUNBOOK_TERMINAL_FIXTURE", directory);
             ("RUNBOOK_TEST_EXE", Sys_unix.executable_name);
             ("RUNBOOK_DOUBLE_SIGNAL", Bool.to_string double_signal);
           ])
      ()
  in
  let child = assert_ok created in
  let%bind () = Writer.close (Process.stdin child) in
  let output = Process.collect_output_and_wait child in
  let%bind () = wait_for_fixture_file (file "ready") in
  let%bind () = wait_for_fixture_file (file "descendant.pid") in
  let pid name =
    In_channel.read_all (file name) |> String.strip |> Pid.of_string
  in
  let parent = pid "parent.pid" in
  let descendant = pid "descendant.pid" in
  let client = pid "client.pid" in
  let owned_group =
    Option.equal Pid.equal (Core_unix.getpgid client) (Some client)
    && not (Option.equal Pid.equal (Core_unix.getpgid parent) (Some client))
  in
  if double_signal then Signal_unix.send_i Signal.term (`Pid parent)
  else Out_channel.write_all (file "cancel") ~data:"cancel";
  let%bind () =
    if double_signal then
      let%map () = Clock_ns.after (Time_ns.Span.of_ms 100.) in
      Signal_unix.send_i Signal.term (`Pid parent)
    else Deferred.unit
  in
  let%bind completed = Clock_ns.with_timeout (Time_ns.Span.of_sec 8.) output in
  let live pid =
    match
      Or_error.try_with (fun () ->
          In_channel.read_all (sprintf "/proc/%d/stat" (Pid.to_int pid)))
    with
    | Error _ -> false
    | Ok stat -> not (String.is_substring stat ~substring:") Z ")
  in
  (* Cleanup remains test-owned even when a regression leaves clients alive. *)
  let leaked = live descendant || live client in
  List.iter [ descendant; client; parent ] ~f:(fun pid ->
      if live pid then Signal_unix.send_i Signal.kill (`Pid pid));
  assert (not leaked);
  assert owned_group;
  let output =
    match completed with
    | `Result output -> output
    | `Timeout -> failwith "terminal cleanup timed out"
  in
  assert (Result.is_ok output.exit_status);
  assert (String.is_substring output.stdout ~substring:"terminal-restored");
  Deferred.unit

let streaming_completion_test () =
  let status = Error (`Exit_non_zero 130) in
  assert (
    Result.is_error
      (Process_runner.For_testing.streaming_completed ~interrupted:true status));
  let token = Cancellation.create () in
  Cancellation.within token (fun () ->
      ignore (Cancellation.request token : Cancellation.request);
      assert (
        Result.is_error
          (Process_runner.For_testing.streaming_completed ~interrupted:false
             status));
      assert (Cancellation.was_acknowledged token));
  assert (
    Poly.equal
      (Process_runner.For_testing.streaming_completed ~interrupted:false status)
      (Ok status))

let streaming_flush_probe ~signal () =
  let token = Cancellation.create () in
  Writer.write (Lazy.force Writer.stdout) (String.make 4_194_304 'x');
  don't_wait_for
    ( Clock_ns.after (Time_ns.Span.of_sec 0.1) >>| fun () ->
      if signal then Signal_unix.send_i Signal.term (`Pid (Core_unix.getpid ()))
      else ignore (Cancellation.request token : Cancellation.request) );
  let%map result =
    Cancellation.within token (fun () ->
        Process_runner.run_streaming ~interactive:false ~prog:"touch"
          ~args:[ Sys.getenv_exn "RUNBOOK_EXEC_MARKER" ]
          ())
  in
  assert (Result.is_error result);
  if not signal then assert (Cancellation.was_acknowledged token);
  eprintf "cancelled-before-exec\n%!";
  0

let streaming_flush_test ~signal () =
  let marker = Filename_unix.temp_file "runbook-no-exec-" "" in
  Core_unix.unlink marker;
  let%bind created =
    Process.create ~prog:Sys_unix.executable_name
      ~args:[ (if signal then "--signal-flush" else "--cancel-flush") ]
      ~env:(`Extend [ ("RUNBOOK_EXEC_MARKER", marker) ])
      ()
  in
  let child = assert_ok created in
  let%bind () = Writer.close (Process.stdin child) in
  let%bind receipt =
    Clock_ns.with_timeout (Time_ns.Span.of_sec 3.)
      (Reader.read_line (Process.stderr child))
  in
  (* Drain only after cancellation must have returned: the child's stdout flush
     cannot be used as the cancellation wakeup. *)
  let drain = Reader.contents (Process.stdout child) in
  let%bind status = Process.wait child in
  let%bind _ = drain in
  assert (not (Sys_unix.file_exists_exn marker));
  assert (Poly.equal receipt (`Result (`Ok "cancelled-before-exec")));
  assert (Result.is_ok status);
  Reader.close (Process.stderr child)

let () =
  if Array.mem (Sys.get_argv ()) "--cli" ~equal:String.equal then
    Command_unix.run
      ~argv:
        (Sys.get_argv () |> Array.to_list
        |> List.filter ~f:(fun arg -> not (String.equal arg "--cli")))
      (Command.group ~summary:"Runbook test consumer"
         (Nixploy_runbook_cli.Runbook_commands.commands ~list:Runbook.list
            ~run:(Runbook.run ~with_guard)))
  else (
    don't_wait_for
      ( Monitor.try_with (fun () ->
            if Array.mem (Sys.get_argv ()) "--probe" ~equal:String.equal then
              probe ()
            else if
              Array.mem (Sys.get_argv ()) "--cancel-flush" ~equal:String.equal
            then streaming_flush_probe ~signal:false ()
            else if
              Array.mem (Sys.get_argv ()) "--signal-flush" ~equal:String.equal
            then streaming_flush_probe ~signal:true ()
            else if
              Array.mem (Sys.get_argv ()) "--terminal-probe" ~equal:String.equal
            then streaming_terminal_probe ()
            else (
              configuration_tests ();
              streaming_completion_test ();
              let%bind () = streaming_flush_test ~signal:false () in
              let%bind () = streaming_flush_test ~signal:true () in
              let%bind () = streaming_terminal_test ~double_signal:false in
              let%bind () = streaming_terminal_test ~double_signal:true in
              integration_tests () >>| fun () -> 0))
      >>| function
        | Ok code -> Shutdown.shutdown code
        | Error error ->
            eprintf "%s\n%!" (Exn.to_string error);
            Shutdown.shutdown 1 );
    never_returns (Scheduler.go ()))
