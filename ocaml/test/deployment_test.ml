open Async
open Core

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let write path contents = Out_channel.write_all path ~data:contents

let run_git ?working_directory args =
  Nixploy.Process_runner.run_stdout ?working_directory
    ~timeout:(Time_ns.Span.of_sec 10.) ~max_output_bytes:65_536 ~prog:"git"
    ~args ()
  >>| Or_error.ok_exn

let install_executable directory name contents =
  let path = Filename.concat directory name in
  write path contents;
  Caml_unix.chmod path 0o755

let index_of lines predicate =
  List.find_mapi lines ~f:(fun index line ->
      if predicate line then Some index else None)
  |> Option.value_exn

let count lines substring = List.count lines ~f:(String.is_substring ~substring)

let set_or_unset name = function
  | Some value -> Caml_unix.putenv name value
  | None -> Core_unix.unsetenv name

let expect_error = function
  | Ok _ -> failwith "deployment unexpectedly succeeded"
  | Error _ -> ()

let run_tests () =
  let open Deferred.Let_syntax in
  let root = Filename_unix.temp_dir "nixploy-deployment-test-" "" in
  let repository = Filename.concat root "repository" in
  let bin = Filename.concat root "bin" in
  let trace = Filename.concat root "trace" in
  let state = Filename.concat root "state" in
  let route_state = Filename.concat root "route-state" in
  Core_unix.mkdir repository;
  Core_unix.mkdir bin;
  install_executable bin "nix"
    {|#!/bin/sh
set -eu
printf 'nix' >> "$NIXPLOY_TEST_TRACE"
printf '|%s' "$@" >> "$NIXPLOY_TEST_TRACE"
printf '\n' >> "$NIXPLOY_TEST_TRACE"
case "$1" in
  eval)
    if [ "${NIXPLOY_TEST_WEB:-}" = "1" ]; then
      cat <<'JSON'
{"__schema":"v0.3","project":"sample","targets":{"worker":{"image":"workerImage","ip":"worker.invalid","run":{"command":["/app/worker","--once"],"environment":{"PORT":"{port}","MODE":"worker"},"preStart":[["/app/migrate"],["/app/seed"]],"network":"private","ports":["127.0.0.1:9000:9000"]},"web":{"domain":"worker.example.invalid","healthPath":"/health","slots":{"blue":8080,"green":8081}}}}}
JSON
    else
      cat <<'JSON'
{"__schema":"v0.3","project":"sample","targets":{"worker":{"image":"workerImage","ip":"worker.invalid","run":{"command":["/app/worker","--once"],"environment":{"PORT":"{port}","MODE":"worker"},"preStart":[["/app/migrate"],["/app/seed"]],"network":"private","ports":["127.0.0.1:9000:9000"]}}}}
JSON
    fi
    ;;
  build) printf '/nix/store/nixploy-fake-image\n' ;;
  *) echo "unexpected nix command" >&2; exit 97 ;;
esac
|};
  install_executable bin "ssh"
    {|#!/bin/sh
set -eu
printf 'ssh' >> "$NIXPLOY_TEST_TRACE"
printf '|%s' "$@" >> "$NIXPLOY_TEST_TRACE"
printf '\n' >> "$NIXPLOY_TEST_TRACE"
last=""
for argument in "$@"; do last="$argument"; done
case "$last" in
  *"'podman' 'ps'"*) printf '[]\n' ;;
  "'true'") : ;;
  *"'curl' '-fsS' '--max-time' '2'"*) : ;;
  *"'-X' 'GET'"*"/config/apps/http/servers/nixploy"*) printf '\n200' ;;
  *"'-X' 'POST'"*"/config/apps/http/servers/nixploy/routes"*)
    cat >/dev/null
    printf '8080\n' > "$NIXPLOY_TEST_ROUTE_STATE"
    printf '\n200'
    ;;
  *"'-X' 'DELETE'"*"/id/nixploy-route-"*)
    rm -f "$NIXPLOY_TEST_ROUTE_STATE"
    printf '\n204'
    ;;
  *"'-X' 'GET'"*"/id/nixploy-route-"*)
    if [ ! -f "$NIXPLOY_TEST_ROUTE_STATE" ]; then
      printf '\n404'
    else
      route_id=$(printf '%s' "$last" | sed -n 's#.*http://127.0.0.1:2019/id/\([^/ ]*\).*#\1#p' | tr -d "'")
      proxy_id=$(printf '%s' "$route_id" | sed 's/nixploy-route-/nixploy-proxy-/')
      printf '{"@id":"%s","match":[{"host":["worker.example.invalid"]}],"handle":[{"handler":"subroute","routes":[{"handle":[{"@id":"%s","handler":"reverse_proxy","upstreams":[{"dial":"127.0.0.1:8080"}]}]}]}],"terminal":true}\n200' "$route_id" "$proxy_id"
    fi
    ;;
  *"'-X' 'GET'"*"/id/nixploy-proxy-"*"/upstreams"*)
    printf '[{"dial":"127.0.0.1:8080"}]\n200'
    ;;
  *) echo "unexpected ssh command: $last" >&2; exit 98 ;;
esac
|};
  install_executable bin "podman"
    {|#!/bin/sh
set -eu
printf 'podman' >> "$NIXPLOY_TEST_TRACE"
printf '|%s' "$@" >> "$NIXPLOY_TEST_TRACE"
printf '\n' >> "$NIXPLOY_TEST_TRACE"
case "$*" in
  "system connection list --format json") printf '[]\n'; exit 0 ;;
  system\ connection\ add\ *) exit 0 ;;
  *" info") exit 0 ;;
  *" load -i /nix/store/nixploy-fake-image") printf 'Loaded image: loaded@sha256:immutable\n'; exit 0 ;;
  *" inspect --type image loaded@sha256:immutable") printf '[{"Id":"sha256:image-id"}]\n'; exit 0 ;;
esac
if [ "${3:-}" = "run" ] && [ "${4:-}" = "--rm" ]; then
  if [ "${NIXPLOY_TEST_FAIL_PRESTART:-}" = "1" ] && printf '%s\n' "$*" | grep -q '/app/migrate'; then
    echo 'pre-start failed' >&2
    exit 42
  fi
  exit 0
fi
if [ "${3:-}" = "container" ] && [ "${4:-}" = "exists" ]; then
  if [ -f "$NIXPLOY_TEST_STATE" ]; then exit 0; fi
  if [ "${NIXPLOY_TEST_WEB:-}" = "1" ]; then exit 1; fi
  exit 0
fi
if [ "${3:-}" = "inspect" ] && [ "${5:-}" = "container" ]; then
  name="${6}"
  if [ -f "$NIXPLOY_TEST_STATE" ]; then
    IFS='|' read -r runtime_name digest operation revision resource < "$NIXPLOY_TEST_STATE"
    image='sha256:image-id'
    if [ "${NIXPLOY_TEST_VERIFY_MISMATCH:-}" = "1" ]; then image='sha256:wrong-image'; fi
    printf '[{"Id":"candidate-id","Name":"%s","Image":"%s","State":{"Running":true},"Config":{"Labels":{"io.nixploy.managed":"true","io.nixploy.project":"sample","io.nixploy.target":"worker","io.nixploy.resource_key":"%s","io.nixploy.revision":"%s","io.nixploy.configuration_digest":"%s","io.nixploy.operation_id":"%s"}}}]\n' "$runtime_name" "$image" "$resource" "$revision" "$digest" "$operation"
  elif [ "${NIXPLOY_TEST_UNOWNED:-}" = "1" ]; then
    printf '[{"Id":"foreign-id","Name":"%s","Config":{"Labels":{"io.nixploy.managed":"true","io.nixploy.project":"sample","io.nixploy.target":"worker","io.nixploy.resource_key":"conflicting-modern-resource","nixploy.project":"sample","nixploy.target":"worker"}}}]\n' "$name"
  else
    printf '[{"Id":"old-id","Name":"%s","Config":{"Labels":{"io.nixploy.managed":"true","io.nixploy.project":"sample","io.nixploy.target":"worker","io.nixploy.resource_key":"%s"}}}]\n' "$name" "$name"
  fi
  exit 0
fi
if [ "${3:-}" = "rm" ] && [ "${4:-}" = "-f" ] && [ -n "${5:-}" ] && [ -z "${6:-}" ]; then
  rm -f "$NIXPLOY_TEST_STATE"
  exit 0
fi
if [ "${3:-}" = "run" ] && [ "${4:-}" = "-d" ]; then
  name=""; digest=""; operation=""; revision=""; resource=""; previous=""
  for argument in "$@"; do
    case "$previous" in
      --name) name="$argument" ;;
      --label)
        case "$argument" in
          io.nixploy.configuration_digest=*) digest="${argument#*=}" ;;
          io.nixploy.operation_id=*) operation="${argument#*=}" ;;
          io.nixploy.revision=*) revision="${argument#*=}" ;;
          io.nixploy.resource_key=*) resource="${argument#*=}" ;;
        esac
        ;;
    esac
    previous="$argument"
  done
  printf '%s|%s|%s|%s|%s\n' "$name" "$digest" "$operation" "$revision" "$resource" > "$NIXPLOY_TEST_STATE"
  printf 'candidate-id\n'
  exit 0
fi
echo "unexpected podman command: $*" >&2
exit 99
|};
  let environment_names =
    [
      "PATH";
      "NIXPLOY_TEST_TRACE";
      "NIXPLOY_TEST_STATE";
      "NIXPLOY_TEST_ROUTE_STATE";
      "NIXPLOY_TEST_FAIL_PRESTART";
      "NIXPLOY_TEST_UNOWNED";
      "NIXPLOY_TEST_VERIFY_MISMATCH";
      "NIXPLOY_TEST_WEB";
    ]
  in
  let old_environment =
    List.map environment_names ~f:(fun name -> (name, Sys.getenv name))
  in
  Caml_unix.putenv "PATH" (bin ^ ":" ^ Sys.getenv_exn "PATH");
  Caml_unix.putenv "NIXPLOY_TEST_TRACE" trace;
  Caml_unix.putenv "NIXPLOY_TEST_STATE" state;
  Caml_unix.putenv "NIXPLOY_TEST_ROUTE_STATE" route_state;
  let clear_scenario () =
    List.iter
      [
        "NIXPLOY_TEST_FAIL_PRESTART";
        "NIXPLOY_TEST_UNOWNED";
        "NIXPLOY_TEST_VERIFY_MISMATCH";
        "NIXPLOY_TEST_WEB";
      ]
      ~f:Core_unix.unsetenv;
    List.iter [ state; route_state ] ~f:(fun path ->
        if Sys_unix.file_exists_exn path then Core_unix.unlink path);
    write trace ""
  in
  let cleanup () =
    List.iter old_environment ~f:(fun (name, value) -> set_or_unset name value);
    Nixploy.Process_runner.run_stdout ~timeout:(Time_ns.Span.of_sec 5.)
      ~max_output_bytes:65_536 ~prog:"rm" ~args:[ "-rf"; "--"; root ] ()
    >>| fun _ -> ()
  in
  Monitor.protect ~finally:cleanup (fun () ->
      let%bind _ = run_git [ "init"; "-b"; "main"; repository ] in
      let%bind _ =
        run_git ~working_directory:repository
          [ "config"; "user.email"; "test@nixploy" ]
      in
      let%bind _ =
        run_git ~working_directory:repository
          [ "config"; "user.name"; "Nixploy Test" ]
      in
      let%bind _ =
        run_git ~working_directory:repository
          [ "config"; "remote.origin.url"; "git@example.invalid:test.git" ]
      in
      write (Filename.concat repository "flake.nix") "{ outputs = _: {}; }\n";
      write (Filename.concat repository "flake.lock") "{}\n";
      let%bind _ = run_git ~working_directory:repository [ "add"; "." ] in
      let%bind _ =
        run_git ~working_directory:repository [ "commit"; "-m"; "Test" ]
      in
      let%bind commit =
        Nixploy.Source.preview_main ~working_directory:repository
      in
      let commit = assert_ok commit in
      let target = Nixploy.Target_name.of_string "worker" |> assert_ok in
      let deploy ?record_stage operation_id =
        Nixploy.Deployment.deploy ?record_stage ~operation_id
          ~working_directory:repository ~commit ~target ()
      in

      clear_scenario ();
      let stages = ref [] in
      let record_stage stage _message =
        stages := stage :: !stages;
        Deferred.Or_error.return ()
      in
      let%bind deployed = deploy ~record_stage "operation-1" in
      let deployed = assert_ok deployed in
      [%test_eq: Nixploy.Deployment_plan.placement]
        Nixploy.Deployment_plan.Single_container
        (Nixploy.Deployment.placement deployed);
      let expected_name = Nixploy.Deployment.container_name deployed in
      let lines = In_channel.read_lines trace in
      let pre_starts =
        List.filter lines ~f:(String.is_substring ~substring:"|run|--rm|")
      in
      [%test_eq: string list]
        [
          sprintf
            "podman|--connection|%s|run|--rm|--network|private|-e|PORT={port}|-e|MODE=worker|loaded@sha256:immutable|/app/migrate"
            expected_name;
          sprintf
            "podman|--connection|%s|run|--rm|--network|private|-e|PORT={port}|-e|MODE=worker|loaded@sha256:immutable|/app/seed"
            expected_name;
        ]
        pre_starts;
      let first_pre_start =
        index_of lines (String.equal (List.nth_exn pre_starts 0))
      in
      let second_pre_start =
        index_of lines (String.equal (List.nth_exn pre_starts 1))
      in
      let ownership_inspect =
        index_of lines
          (String.is_substring ~substring:"|inspect|--type|container|")
      in
      let removal = index_of lines (String.is_substring ~substring:"|rm|-f|") in
      let runtime =
        index_of lines (String.is_substring ~substring:"|run|-d|--name|")
      in
      assert (
        first_pre_start < second_pre_start
        && second_pre_start < ownership_inspect
        && ownership_inspect < removal
        && removal < runtime);
      [%test_eq: int] 1 (count lines "|rm|-f|");
      [%test_eq: string]
        (sprintf "podman|--connection|%s|rm|-f|%s" expected_name expected_name)
        (List.nth_exn lines removal);
      assert (
        List.for_all lines ~f:(fun line ->
            not
              (String.is_prefix line ~prefix:"ssh|"
              && String.is_substring line ~substring:"curl")));
      let runtime_line = List.nth_exn lines runtime in
      List.iter
        [
          "|--network|private|";
          "|-e|PORT={port}|";
          "|-p|127.0.0.1:9000:9000|";
          "|--label|io.nixploy.managed=true|";
          "|--label|io.nixploy.operation_id=operation-1|";
          "|loaded@sha256:immutable|/app/worker|--once";
        ] ~f:(fun substring ->
          assert (String.is_substring runtime_line ~substring));
      [%test_eq: Nixploy.Deployment.stage list]
        [
          Preparing_source;
          Evaluating;
          Connecting;
          Building;
          Planning;
          Running_pre_start;
          Preparing_candidate;
          Starting;
          Verifying;
          Succeeded;
        ]
        (List.rev !stages);

      clear_scenario ();
      Caml_unix.putenv "NIXPLOY_TEST_FAIL_PRESTART" "1";
      let%bind failed_pre_start = deploy "operation-pre-start" in
      expect_error failed_pre_start;
      let lines = In_channel.read_lines trace in
      assert (count lines "|run|--rm|" = 1);
      assert (count lines "|inspect|--type|container|" = 0);
      assert (count lines "|rm|-f|" = 0);
      assert (count lines "|run|-d|--name|" = 0);

      clear_scenario ();
      Caml_unix.putenv "NIXPLOY_TEST_UNOWNED" "1";
      let%bind unowned = deploy "operation-unowned" in
      expect_error unowned;
      let lines = In_channel.read_lines trace in
      assert (count lines "|inspect|--type|container|" = 1);
      assert (count lines "|rm|-f|" = 0);
      assert (count lines "|run|-d|--name|" = 0);

      clear_scenario ();
      Caml_unix.putenv "NIXPLOY_TEST_VERIFY_MISMATCH" "1";
      let%bind mismatch = deploy "operation-mismatch" in
      expect_error mismatch;
      let lines = In_channel.read_lines trace in
      [%test_eq: int] 2 (count lines "|rm|-f|");
      let removals =
        List.filter lines ~f:(String.is_substring ~substring:"|rm|-f|")
      in
      assert (
        String.is_substring (List.nth_exn removals 0)
          ~substring:("|rm|-f|" ^ expected_name));
      assert (
        String.is_substring (List.nth_exn removals 1)
          ~substring:"|rm|-f|candidate-id");

      clear_scenario ();
      let record_stage stage _message =
        if Nixploy.Deployment.equal_stage stage Verifying then
          Deferred.Or_error.error_string "stage persistence failed"
        else Deferred.Or_error.return ()
      in
      let%bind stage_failure = deploy ~record_stage "operation-stage-failure" in
      expect_error stage_failure;
      let lines = In_channel.read_lines trace in
      [%test_eq: int] 2 (count lines "|rm|-f|");
      assert (not (Sys_unix.file_exists_exn state));

      clear_scenario ();
      let observer_store_path = Filename.concat root "observer.sqlite" in
      let%bind observer_store = Nixploy.Store.open_ ~path:observer_store_path in
      let observer_store = assert_ok observer_store in
      let observer_calls = ref 0 in
      let on_stage _stage _message =
        Int.incr observer_calls;
        raise_s [%message "observer failure"]
      in
      let%bind observer_result =
        Nixploy.Tracked_deployment.deploy ~on_stage ~store:observer_store
          ~working_directory:repository ~commit ~target ()
      in
      let observer_result = assert_ok observer_result in
      assert (!observer_calls > 0);
      assert (
        Nixploy.Store.equal_state
          (Nixploy.Store.state observer_result)
          Succeeded);

      clear_scenario ();
      let failing_store_path = Filename.concat root "failing.sqlite" in
      let%bind failing_store = Nixploy.Store.open_ ~path:failing_store_path in
      let failing_store = assert_ok failing_store in
      let on_stage stage _message =
        if Nixploy.Deployment.equal_stage stage Starting then (
          Core_unix.unlink failing_store_path;
          Core_unix.mkdir failing_store_path);
        Deferred.unit
      in
      let%bind persisted_stage_failure =
        Nixploy.Tracked_deployment.deploy ~on_stage ~store:failing_store
          ~working_directory:repository ~commit ~target ()
      in
      expect_error persisted_stage_failure;
      let lines = In_channel.read_lines trace in
      [%test_eq: int] 2 (count lines "|rm|-f|");
      assert (
        String.is_substring (List.last_exn lines)
          ~substring:"|rm|-f|candidate-id");
      Core_unix.rmdir failing_store_path;

      clear_scenario ();
      Caml_unix.putenv "NIXPLOY_TEST_WEB" "1";
      let terminal_stage_attempted = ref false in
      let record_stage stage _message =
        if Nixploy.Deployment.equal_stage stage Succeeded then (
          terminal_stage_attempted := true;
          Deferred.Or_error.error_string "terminal stage persistence failed")
        else Deferred.Or_error.return ()
      in
      let%bind web_stage_failure =
        deploy ~record_stage "operation-web-stage-failure"
      in
      expect_error web_stage_failure;
      let lines = In_channel.read_lines trace in
      if not !terminal_stage_attempted then
        failwithf "web deployment failed before terminal stage: %s\n%s"
          (Result.error web_stage_failure
          |> Option.value_exn |> Error.to_string_hum)
          (String.concat ~sep:"\n" lines)
          ();
      let switch =
        index_of lines (fun line ->
            String.is_prefix line ~prefix:"ssh|"
            && String.is_substring line ~substring:"'-X' 'POST'")
      in
      let restore =
        index_of lines (fun line ->
            String.is_prefix line ~prefix:"ssh|"
            && String.is_substring line ~substring:"'-X' 'DELETE'")
      in
      let cleanup_candidate =
        index_of lines (String.is_substring ~substring:"|rm|-f|")
      in
      assert (switch < restore && restore < cleanup_candidate);
      assert (not (Sys_unix.file_exists_exn state));
      assert (not (Sys_unix.file_exists_exn route_state));
      Deferred.unit)

let () =
  don't_wait_for
    ( Monitor.try_with run_tests >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1 );
  never_returns (Scheduler.go ())
