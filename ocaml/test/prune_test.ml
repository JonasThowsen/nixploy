open Async
open Core

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let expect_error = function
  | Ok _ -> failwith "prune unexpectedly succeeded"
  | Error _ -> ()

let write path contents = Out_channel.write_all path ~data:contents

let install_executable directory name contents =
  let path = Filename.concat directory name in
  write path contents;
  Caml_unix.chmod path 0o755

let set_or_unset name = function
  | Some value -> Caml_unix.putenv name value
  | None -> Core_unix.unsetenv name

let count lines substring = List.count lines ~f:(String.is_substring ~substring)

let run_tests () =
  let open Deferred.Let_syntax in
  let root = Filename_unix.temp_dir "nixploy-prune-test-" "" in
  let project_directory = Filename.concat root "project" in
  let bin = Filename.concat root "bin" in
  let trace = Filename.concat root "trace" in
  Core_unix.mkdir project_directory;
  Core_unix.mkdir bin;
  write (Filename.concat project_directory "flake.nix") "{ outputs = _: {}; }\n";
  let project = Nixploy.Project_name.of_string "sample" |> assert_ok in
  let target_name = Nixploy.Target_name.of_string "worker" |> assert_ok in
  let resource_key =
    Nixploy.Resource_key.derive ~project ~target:target_name |> assert_ok
  in
  let key = Nixploy.Resource_key.to_string resource_key in
  install_executable bin "nix"
    {|#!/bin/sh
set -eu
printf 'nix' >> "$NIXPLOY_TEST_TRACE"
printf '|%s' "$@" >> "$NIXPLOY_TEST_TRACE"
printf '\n' >> "$NIXPLOY_TEST_TRACE"
if [ "$*" != "eval --json --no-write-lock-file .#nixploy" ]; then
  echo "unexpected nix command: $*" >&2
  exit 97
fi
if [ "${NIXPLOY_TEST_WEB:-}" = "1" ]; then
  printf '%s\n' '{"__schema":"v0.3","project":"sample","targets":{"worker":{"image":"workerImage","ip":"worker.invalid","web":{"domain":"worker.example.invalid"}}}}'
else
  printf '%s\n' '{"__schema":"v0.3","project":"sample","targets":{"worker":{"image":"workerImage","ip":"worker.invalid"}}}'
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
  "'true'") : ;;
  *"'-X' 'DELETE'"*"/id/nixploy-route-$NIXPLOY_TEST_KEY"*)
    if [ "${NIXPLOY_TEST_WEB:-}" != "1" ]; then
      echo "Caddy called for non-web target" >&2
      exit 96
    fi
    if [ "${NIXPLOY_TEST_CADDY_MISSING:-}" = "1" ]; then
      printf '\n404'
    else
      printf '\n204'
    fi
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
esac
if [ "${3:-}" = "container" ] && [ "${4:-}" = "exists" ]; then
  case "${5:-}" in
    "$NIXPLOY_TEST_KEY"|"$NIXPLOY_TEST_KEY-blue") exit 0 ;;
    "$NIXPLOY_TEST_KEY-green") exit 1 ;;
    *) echo "arbitrary container name: ${5:-}" >&2; exit 94 ;;
  esac
fi
if [ "${3:-}" = "inspect" ] && [ "${5:-}" = "container" ]; then
  name="${6:-}"
  if [ "${NIXPLOY_TEST_UNOWNED:-}" = "1" ] && [ "$name" = "$NIXPLOY_TEST_KEY" ]; then
    printf '[{"Id":"foreign-id","Config":{"Labels":{"io.nixploy.managed":"true","io.nixploy.project":"sample","io.nixploy.target":"worker","io.nixploy.resource_key":"contradictory","nixploy.project":"sample","nixploy.target":"worker"}}}]\n'
  else
    id="single-id"
    if [ "$name" = "$NIXPLOY_TEST_KEY-blue" ]; then id="blue-id"; fi
    printf '[{"Id":"%s","Config":{"Labels":{"io.nixploy.managed":"true","io.nixploy.project":"sample","io.nixploy.target":"worker","io.nixploy.resource_key":"%s"}}}]\n' "$id" "$NIXPLOY_TEST_KEY"
  fi
  exit 0
fi
if [ "${3:-}" = "secret" ] && [ "${4:-}" = "ls" ]; then
  if [ "${NIXPLOY_TEST_FAIL_SECRET_LIST:-}" = "1" ]; then
    echo "secret listing failed" >&2
    exit 42
  fi
  printf '[{"Name":"%s-db"},{"Spec":{"Name":"%s-api"}},{"Name":"%sish-unrelated"},{"Name":"unrelated"}]\n' "$NIXPLOY_TEST_KEY" "$NIXPLOY_TEST_KEY" "$NIXPLOY_TEST_KEY"
  exit 0
fi
if [ "${3:-}" = "rm" ] && [ "${4:-}" = "-f" ]; then
  case "${5:-}" in single-id|blue-id) exit 0 ;; *) exit 93 ;; esac
fi
if [ "${3:-}" = "secret" ] && [ "${4:-}" = "rm" ]; then
  case "${5:-}" in
    "$NIXPLOY_TEST_KEY-api"|"$NIXPLOY_TEST_KEY-db")
      if [ "${NIXPLOY_TEST_FAIL_SECRET_REMOVE:-}" = "1" ]; then
        echo "secret removal failed" >&2
        exit 43
      fi
      exit 0
      ;;
    *) echo "unrelated secret selected: ${5:-}" >&2; exit 92 ;;
  esac
fi
echo "unexpected podman command: $*" >&2
exit 99
|};
  let environment_names =
    [
      "PATH";
      "NIXPLOY_TEST_TRACE";
      "NIXPLOY_TEST_KEY";
      "NIXPLOY_TEST_WEB";
      "NIXPLOY_TEST_UNOWNED";
      "NIXPLOY_TEST_FAIL_SECRET_LIST";
      "NIXPLOY_TEST_FAIL_SECRET_REMOVE";
      "NIXPLOY_TEST_CADDY_MISSING";
    ]
  in
  let old_environment =
    List.map environment_names ~f:(fun name -> (name, Sys.getenv name))
  in
  Caml_unix.putenv "PATH" (bin ^ ":" ^ Sys.getenv_exn "PATH");
  Caml_unix.putenv "NIXPLOY_TEST_TRACE" trace;
  Caml_unix.putenv "NIXPLOY_TEST_KEY" key;
  let clear_scenario () =
    List.iter
      [
        "NIXPLOY_TEST_WEB";
        "NIXPLOY_TEST_UNOWNED";
        "NIXPLOY_TEST_FAIL_SECRET_LIST";
        "NIXPLOY_TEST_FAIL_SECRET_REMOVE";
        "NIXPLOY_TEST_CADDY_MISSING";
      ]
      ~f:Core_unix.unsetenv;
    write trace ""
  in
  let cleanup () =
    List.iter old_environment ~f:(fun (name, value) -> set_or_unset name value);
    Nixploy.Process_runner.run_stdout ~timeout:(Time_ns.Span.of_sec 5.)
      ~max_output_bytes:65_536 ~prog:"rm" ~args:[ "-rf"; "--"; root ] ()
    >>| fun _ -> ()
  in
  Monitor.protect ~finally:cleanup (fun () ->
      let prune () =
        Nixploy.Prune.prune ~working_directory:project_directory
          ~target:target_name
      in
      clear_scenario ();
      let%bind non_web = prune () in
      let non_web = assert_ok non_web in
      [%test_eq: string] key
        (Nixploy.Prune.resource_key non_web |> Nixploy.Resource_key.to_string);
      [%test_eq: int] 2 (Nixploy.Prune.containers_removed non_web);
      [%test_eq: int] 2 (Nixploy.Prune.secrets_removed non_web);
      [%test_eq: Nixploy.Prune.route] Not_configured
        (Nixploy.Prune.route non_web);
      let lines = In_channel.read_lines trace in
      [%test_eq: int] 3 (count lines "|container|exists|");
      [%test_eq: int] 2 (count lines "|inspect|--type|container|");
      [%test_eq: int] 2 (count lines "|rm|-f|");
      [%test_eq: int] 2 (count lines "|secret|rm|");
      assert (count lines "curl" = 0);
      assert (
        List.for_all lines ~f:(fun line ->
            not (String.is_substring line ~substring:"ish-unrelated")));

      clear_scenario ();
      Caml_unix.putenv "NIXPLOY_TEST_WEB" "1";
      let%bind web = prune () in
      let web = assert_ok web in
      [%test_eq: int] 2 (Nixploy.Prune.containers_removed web);
      [%test_eq: int] 2 (Nixploy.Prune.secrets_removed web);
      [%test_eq: Nixploy.Prune.route] Removed (Nixploy.Prune.route web);
      let lines = In_channel.read_lines trace in
      [%test_eq: int] 1
        (List.count lines ~f:(fun line ->
             String.is_prefix line ~prefix:"ssh|"
             && String.is_substring line ~substring:"'-X' 'DELETE'"));
      assert (
        List.exists lines
          ~f:(String.is_substring ~substring:("/id/nixploy-route-" ^ key)));

      clear_scenario ();
      Caml_unix.putenv "NIXPLOY_TEST_WEB" "1";
      Caml_unix.putenv "NIXPLOY_TEST_CADDY_MISSING" "1";
      let%bind missing_route = prune () in
      let missing_route = assert_ok missing_route in
      [%test_eq: Nixploy.Prune.route] Missing
        (Nixploy.Prune.route missing_route);

      clear_scenario ();
      Caml_unix.putenv "NIXPLOY_TEST_UNOWNED" "1";
      let%bind unowned = prune () in
      expect_error unowned;
      let lines = In_channel.read_lines trace in
      assert (count lines "|rm|-f|" = 0);
      assert (count lines "|secret|rm|" = 0);

      clear_scenario ();
      Caml_unix.putenv "NIXPLOY_TEST_FAIL_SECRET_LIST" "1";
      let%bind list_failure = prune () in
      expect_error list_failure;
      let lines = In_channel.read_lines trace in
      assert (count lines "|rm|-f|" = 0);
      assert (count lines "|secret|rm|" = 0);

      clear_scenario ();
      Caml_unix.putenv "NIXPLOY_TEST_FAIL_SECRET_REMOVE" "1";
      let%map removal_failure = prune () in
      expect_error removal_failure;
      let lines = In_channel.read_lines trace in
      assert (count lines "|secret|rm|" = 1))

let () =
  don't_wait_for
    ( Monitor.try_with run_tests >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1 );
  never_returns (Scheduler.go ())
