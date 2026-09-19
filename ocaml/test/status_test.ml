open Async
open Core
module Inspection_output = Nixploy_cli_mapping.Inspection_output

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let expect_error_containing result text =
  match result with
  | Ok _ -> failwith "status unexpectedly succeeded"
  | Error error ->
      assert (String.is_substring (Error.to_string_hum error) ~substring:text)

let write path contents = Out_channel.write_all path ~data:contents

let install_executable directory name contents =
  let path = Filename.concat directory name in
  write path contents;
  Caml_unix.chmod path 0o755

let set_or_unset name = function
  | Some value -> Caml_unix.putenv name value
  | None -> Core_unix.unsetenv name

let run_git ?working_directory args =
  Nixploy.Process_runner.run_stdout ?working_directory
    ~timeout:(Time_ns.Span.of_sec 10.) ~max_output_bytes:65_536 ~prog:"git"
    ~args ()
  >>| Or_error.ok_exn

let run_tests () =
  let open Deferred.Let_syntax in
  let root = Filename_unix.temp_dir "nixploy-status-test-" "" in
  let repository = Filename.concat root "repository" in
  let bin = Filename.concat root "bin" in
  let trace = Filename.concat root "trace" in
  Core_unix.mkdir repository;
  Core_unix.mkdir bin;
  write trace "";
  write (Filename.concat repository "flake.nix") "{ outputs = _: {}; }\n";
  let%bind _ = run_git [ "init"; "-b"; "main"; repository ] in
  let%bind _ =
    run_git ~working_directory:repository
      [ "config"; "remote.origin.url"; "git@example.invalid:sample.git" ]
  in
  let project = Nixploy.Project_name.of_string "sample" |> assert_ok in
  let target_name = Nixploy.Target_name.of_string "worker" |> assert_ok in
  let%bind application =
    Nixploy.Application.open_
      ~state_path:(Filename.concat root "state.sqlite")
      ()
  in
  let application = assert_ok application in
  let scope =
    Nixploy.Application.local_scope ~working_directory:repository
      ~target:target_name
    |> assert_ok
  in
  let resource_key =
    Nixploy.Resource_key.derive ~project ~target:target_name
      ~repository_identity:"git@example.invalid:sample.git"
    |> assert_ok |> Nixploy.Resource_key.to_string
  in
  install_executable bin "nix"
    {|#!/bin/sh
set -eu
printf 'nix' >> "$NIXPLOY_TEST_TRACE"
printf '|%s' "$@" >> "$NIXPLOY_TEST_TRACE"
printf '\n' >> "$NIXPLOY_TEST_TRACE"
printf '%s\n' '{"__schema":"v0.3","project":"sample","targets":{"worker":{"image":"workerImage","ip":"worker.invalid","user":"deployer","port":2222}}}'
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
  "'id' '-u'") printf '1001\n' ;;
  "'loginctl' 'show-user' 'deployer' '--property=Linger' '--value'") printf 'yes\n' ;;
  "'systemctl' '--user' 'is-enabled' 'podman-restart.service'") printf 'disabled\n'; exit 1 ;;
  "'test' '-d' '.nixploy-mutations/"*) exit 1 ;;
  "'df' '-P' '-k' '--' '/home/deployer/storage'")
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 40000000 20000000 20000000 50%% /\n'
    ;;
  *"'podman' 'ps'"*)
    printf '[{"Labels":{"io.nixploy.managed":"true","io.nixploy.project":"sample","io.nixploy.target":"worker","io.nixploy.resource_key":"%s","io.nixploy.repository_identity":"git@example.invalid:sample.git"}}]\n' "$NIXPLOY_TEST_KEY"
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
  "system connection list --format json")
    printf '[{"Name":"%s","URI":"ssh://deployer@worker.invalid:2222/run/user/1000/podman/podman.sock"}]\n' "$NIXPLOY_TEST_KEY"
    ;;
  *" ps --all "*)
    case "$*" in
      *"name=^$NIXPLOY_TEST_KEY\$"*) ;;
      *) printf '[]\n'; exit 0 ;;
    esac
    case "${NIXPLOY_TEST_LABEL_MODE:-valid}" in
      valid)
        labels='"io.nixploy.managed":"true","io.nixploy.project":"sample","io.nixploy.target":"worker","io.nixploy.resource_key":"'"$NIXPLOY_TEST_KEY"'","io.nixploy.repository_identity":"git@example.invalid:sample.git"'
        ;;
      legacy)
        labels='"nixploy.project":"sample","nixploy.target":"worker","nixploy.resource_key":"'"$NIXPLOY_TEST_KEY"'","nixploy.repository":"git@example.invalid:sample.git"'
        ;;
      mixed)
        labels='"io.nixploy.managed":"true","io.nixploy.project":"sample","nixploy.target":"worker","nixploy.resource_key":"'"$NIXPLOY_TEST_KEY"'","io.nixploy.repository_identity":"git@example.invalid:sample.git"'
        ;;
      partial)
        labels='"io.nixploy.managed":"true","io.nixploy.project":"sample","io.nixploy.target":"worker","io.nixploy.repository_identity":"git@example.invalid:sample.git"'
        ;;
      wrong-resource)
        labels='"io.nixploy.managed":"true","io.nixploy.project":"sample","io.nixploy.target":"worker","io.nixploy.resource_key":"wrong","io.nixploy.repository_identity":"git@example.invalid:sample.git"'
        ;;
      foreign-repository)
        labels='"io.nixploy.managed":"true","io.nixploy.project":"sample","io.nixploy.target":"worker","io.nixploy.resource_key":"'"$NIXPLOY_TEST_KEY"'","io.nixploy.repository_identity":"git@example.invalid:other.git"'
        ;;
      *) echo "unexpected label mode" >&2; exit 96 ;;
    esac
    printf '[{"Names":["%s"],"Id":"container-id","Image":"sample","State":"running","Status":"Up 3 hours","Restarts":2,"StartedAt":1789811772,"Labels":{%s}}]\n' "$NIXPLOY_TEST_KEY" "$labels"
    ;;
  *" inspect --type container "*)
    printf '[{"Name":"%s","HostConfig":{"RestartPolicy":{"Name":"always"}}}]\n' "$NIXPLOY_TEST_KEY"
    ;;
  *" stats --no-stream --format json "*)
    printf '[{"name":"%s","cpu_percent":"1.50%%","mem_usage":"256MiB / 1GiB","pids":"7"}]\n' "$NIXPLOY_TEST_KEY"
    ;;
  *" secret ls "*) printf 'abcdefghijklmnopqrstuvwxy\t%s-DATABASE_URL\n' "$NIXPLOY_TEST_KEY" ;;
  *" secret inspect abcdefghijklmnopqrstuvwxy")
    printf '[{"ID":"abcdefghijklmnopqrstuvwxy","Spec":{"Name":"%s-DATABASE_URL","Labels":{}}}]\n' "$NIXPLOY_TEST_KEY"
    ;;
  *" images --format json")
    printf '[{"Id":"image-a","Names":["localhost/nixploy/%s:20260919T101500Z-abc"],"Size":1073741824,"Containers":1},{"Id":"image-b","Names":["localhost/nixploy/%s-2:20260919T101500Z-abc","docker.io/library/unrelated:latest"],"Size":5,"Containers":0}]\n' "$NIXPLOY_TEST_KEY" "$NIXPLOY_TEST_KEY"
    ;;
  *" system df --format json")
    printf '[{"Type":"Images","RawSize":3221225472,"RawReclaimable":1073741824},{"Type":"Containers","RawSize":4096,"RawReclaimable":0},{"Type":"Local Volumes","RawSize":0,"RawReclaimable":0}]\n'
    ;;
  *" info --format json")
    printf '{"host":{"cpus":4,"memTotal":8589934592,"memFree":2147483648},"store":{"graphRoot":"/home/deployer/storage"}}\n'
    ;;
  *) echo "unexpected podman command: $*" >&2; exit 99 ;;
esac
|};
  let environment_names =
    [
      "PATH";
      "SSH_AUTH_SOCK";
      "NIXPLOY_TEST_TRACE";
      "NIXPLOY_TEST_KEY";
      "NIXPLOY_TEST_LABEL_MODE";
    ]
  in
  let old_environment =
    List.map environment_names ~f:(fun name -> (name, Sys.getenv name))
  in
  Caml_unix.putenv "PATH" (bin ^ ":" ^ Sys.getenv_exn "PATH");
  Core_unix.unsetenv "SSH_AUTH_SOCK";
  Caml_unix.putenv "NIXPLOY_TEST_TRACE" trace;
  Caml_unix.putenv "NIXPLOY_TEST_KEY" resource_key;
  let clear_scenario () =
    Core_unix.unsetenv "NIXPLOY_TEST_LABEL_MODE";
    write trace ""
  in
  let cleanup () =
    List.iter old_environment ~f:(fun (name, value) -> set_or_unset name value);
    Nixploy.Process_runner.run_stdout ~timeout:(Time_ns.Span.of_sec 5.)
      ~max_output_bytes:65_536 ~prog:"rm" ~args:[ "-rf"; "--"; root ] ()
    >>| fun _ -> ()
  in
  Monitor.protect ~finally:cleanup (fun () ->
      clear_scenario ();
      let%bind modern = Nixploy.Application.live_status application ~scope in
      let modern = assert_ok modern in
      [%test_eq: int] 1
        (modern |> Nixploy.Application.status_workloads |> List.length);
      let rendered = Inspection_output.status modern in
      List.iter
        [
          "Project:  sample";
          resource_key;
          "(4 CPUs, 8.0 GiB memory, 2.0 GiB free)";
          "Up 3 hours";
          "1.5%";
          "256.0 MiB / 1.0 GiB";
          "Secrets:  0 owned, 1 unlabelled legacy";
          "Images:   1 owned (1.0 GiB), 1 in use";
          "images 3.0 GiB (1.0 GiB reclaimable)";
          "19.1 GiB free of 38.1 GiB on /home/deployer/storage";
          "Guard:    idle";
          "Reboot:   not ready";
          "has restarted 2 times";
          "podman-restart.service starts owned containers at boot";
        ] ~f:(fun expected ->
          if not (String.is_substring rendered ~substring:expected) then
            failwithf "status output lacks %S:\n%s" expected rendered ());
      assert (not (String.is_substring rendered ~substring:"unavailable"));
      let json =
        Inspection_output.status_json modern |> Yojson.Safe.from_string
      in
      let open Yojson.Safe.Util in
      let container = json |> member "containers" |> index 0 in
      [%test_eq: string] "app" (container |> member "role" |> to_string);
      [%test_eq: string] "always"
        (container |> member "restartPolicy" |> to_string);
      [%test_eq: int] 7 (container |> member "pids" |> to_int);
      [%test_eq: string] "idle"
        (json |> member "guard" |> member "state" |> to_string);
      assert (not (List.is_empty (json |> member "issues" |> to_list)));
      let lines = In_channel.read_lines trace in
      List.iter
        [ "|rm|"; "|secret|rm|"; "|secret|create|"; "'mkdir'"; "'rmdir'" ]
        ~f:(fun mutation ->
          assert (
            not (List.exists lines ~f:(String.is_substring ~substring:mutation))));
      assert (
        List.exists lines
          ~f:
            (String.is_substring
               ~substring:("|--filter|name=^" ^ resource_key ^ "$|")));

      let%bind () =
        Deferred.List.iter
          [
            "legacy"; "mixed"; "partial"; "wrong-resource"; "foreign-repository";
          ] ~how:`Sequential ~f:(fun mode ->
            clear_scenario ();
            Caml_unix.putenv "NIXPLOY_TEST_LABEL_MODE" mode;
            let%map inspected =
              Nixploy.Application.live_status application ~scope
            in
            expect_error_containing inspected
              "ownership does not match this repository and resource")
      in
      Deferred.unit)

let () =
  don't_wait_for
    ( Monitor.try_with run_tests >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1 );
  never_returns (Scheduler.go ())
