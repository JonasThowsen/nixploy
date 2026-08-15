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

let run_tests () =
  let open Deferred.Let_syntax in
  let root = Filename_unix.temp_dir "nixploy-non-web-test-" "" in
  let repository = Filename.concat root "repository" in
  let bin = Filename.concat root "bin" in
  let trace = Filename.concat root "trace" in
  let state = Filename.concat root "state" in
  Core_unix.mkdir repository;
  Core_unix.mkdir bin;
  write trace "";
  install_executable bin "nix"
    {|#!/bin/sh
set -eu
printf 'nix' >> "$NIXPLOY_TEST_TRACE"
printf '|%s' "$@" >> "$NIXPLOY_TEST_TRACE"
printf '\n' >> "$NIXPLOY_TEST_TRACE"
if [ "$1" = "eval" ]; then
  cat <<'JSON'
{"__schema":"v0.3","project":"sample","targets":{"worker":{"image":"workerImage","ip":"worker.invalid","run":{"command":["/app/worker","--once"],"environment":{"PORT":"{port}","MODE":"worker"},"preStart":[["/app/migrate"],["/app/seed"]],"network":"private","ports":["127.0.0.1:9000:9000"]}}}}
JSON
elif [ "$1" = "build" ]; then
  printf '/nix/store/nixploy-fake-image\n'
else
  exit 2
fi
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
  *) : ;;
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
  *"load -i /nix/store/nixploy-fake-image") printf 'Loaded image: loaded@sha256:immutable\n'; exit 0 ;;
  *"inspect --type image loaded@sha256:immutable") printf '[{"Id":"sha256:image-id"}]\n'; exit 0 ;;
esac
if [ "${3:-}" = "container" ] && [ "${4:-}" = "exists" ]; then
  exit 0
fi
if [ "${3:-}" = "inspect" ] && [ "${5:-}" = "container" ]; then
  name="${6}"
  if [ -f "$NIXPLOY_TEST_STATE" ]; then
    IFS='|' read -r runtime_name digest operation revision resource < "$NIXPLOY_TEST_STATE"
    printf '[{"Id":"candidate-id","Name":"%s","Image":"sha256:image-id","State":{"Running":true},"Config":{"Labels":{"io.nixploy.managed":"true","io.nixploy.project":"sample","io.nixploy.target":"worker","io.nixploy.resource_key":"%s","io.nixploy.revision":"%s","io.nixploy.configuration_digest":"%s","io.nixploy.operation_id":"%s"}}}]\n' "$runtime_name" "$resource" "$revision" "$digest" "$operation"
  else
    printf '[{"Id":"old-id","Name":"%s","Config":{"Labels":{"io.nixploy.managed":"true","io.nixploy.project":"sample","io.nixploy.target":"worker","io.nixploy.resource_key":"%s"}}}]\n' "$name" "$name"
  fi
  exit 0
fi
if [ "${3:-}" = "run" ] && [ "${4:-}" = "-d" ]; then
  name=""; digest=""; operation=""; revision=""; resource=""
  previous=""
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
exit 0
|};
  let old_path = Sys.getenv_exn "PATH" in
  Caml_unix.putenv "PATH" (bin ^ ":" ^ old_path);
  Caml_unix.putenv "NIXPLOY_TEST_TRACE" trace;
  Caml_unix.putenv "NIXPLOY_TEST_STATE" state;
  let cleanup () =
    Caml_unix.putenv "PATH" old_path;
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
      let stages = ref [] in
      let on_stage stage _message =
        stages := stage :: !stages;
        Deferred.unit
      in
      let%bind deployed =
        Nixploy.Deployment.deploy ~on_stage ~operation_id:"operation-1"
          ~working_directory:repository ~commit
          ~target:(Nixploy.Target_name.of_string "worker" |> assert_ok)
          ()
      in
      let deployed = assert_ok deployed in
      [%test_eq: Nixploy.Deployment_plan.placement]
        Nixploy.Deployment_plan.Single_container
        (Nixploy.Deployment.placement deployed);
      let lines = In_channel.read_lines trace in
      let first_pre_start =
        index_of lines (String.is_substring ~substring:"run|--rm")
      in
      let replacement =
        index_of lines (String.is_substring ~substring:"container|exists")
      in
      let runtime =
        index_of lines (String.is_substring ~substring:"run|-d|--name")
      in
      let verification =
        List.findi_exn lines ~f:(fun index line ->
            index > runtime
            && String.is_substring line ~substring:"inspect|--type|container")
        |> fst
      in
      assert (
        first_pre_start < replacement
        && replacement < runtime && runtime < verification);
      let pre_start_lines =
        List.filter lines ~f:(String.is_substring ~substring:"run|--rm")
      in
      [%test_eq: int] 2 (List.length pre_start_lines);
      assert (
        List.for_all pre_start_lines ~f:(fun line ->
            (not (String.is_substring line ~substring:"|-p|"))
            && String.is_substring line ~substring:"|--network|private|"
            && String.is_substring line ~substring:"|-e|PORT={port}|"));
      let runtime_line = List.nth_exn lines runtime in
      assert (
        String.is_substring runtime_line
          ~substring:
            ("|--name|" ^ Nixploy.Deployment.container_name deployed ^ "|"));
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
      assert (
        List.for_all lines ~f:(fun line ->
            not (String.is_substring line ~substring:"curl")));
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
      Deferred.unit)

let () =
  don't_wait_for
    ( Monitor.try_with run_tests >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1 );
  never_returns (Scheduler.go ())
