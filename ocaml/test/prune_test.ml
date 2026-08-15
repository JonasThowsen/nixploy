open Async
open Core

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let expect_error_containing result text =
  match result with
  | Ok _ -> failwith "prune unexpectedly succeeded"
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

let count lines substring = List.count lines ~f:(String.is_substring ~substring)

let index_of lines substring =
  List.find_mapi lines ~f:(fun index line ->
      if String.is_substring line ~substring then Some index else None)
  |> Option.value_exn

let run_git ?working_directory args =
  Nixploy.Process_runner.run_stdout ?working_directory
    ~timeout:(Time_ns.Span.of_sec 10.) ~max_output_bytes:65_536 ~prog:"git"
    ~args ()
  >>| Or_error.ok_exn

let run_tests () =
  let open Deferred.Let_syntax in
  let root = Filename_unix.temp_dir "nixploy-prune-test-" "" in
  let project_directory = Filename.concat root "project" in
  let bin = Filename.concat root "bin" in
  let trace = Filename.concat root "trace" in
  let remote_state = Filename.concat root "remote-state" in
  Core_unix.mkdir project_directory;
  Core_unix.mkdir bin;
  Core_unix.mkdir remote_state;
  write (Filename.concat project_directory "flake.nix") "{ outputs = _: {}; }\n";
  let%bind _ = run_git [ "init"; "-b"; "main"; project_directory ] in
  let%bind _ =
    run_git ~working_directory:project_directory
      [ "config"; "remote.origin.url"; "git@example.invalid:sample.git" ]
  in
  let project = Nixploy.Project_name.of_string "sample" |> assert_ok in
  let target_name = Nixploy.Target_name.of_string "worker" |> assert_ok in
  let target =
    Nixploy.Configuration.of_json
      {|{"__schema":"v0.3","project":"sample","targets":{"worker":{"image":"workerImage","ip":"worker.invalid","user":"deployer","port":2222}}}|}
    |> assert_ok
    |> fun configuration ->
    Nixploy.Configuration.find_target configuration target_name |> assert_ok
  in
  let canonical =
    Nixploy.Resource_key.derive ~project ~target:target_name
      ~repository_identity:"git@example.invalid:sample.git"
    |> assert_ok
  in
  let current =
    Nixploy.Resource_key.derive_current ~project ~target:target_name
    |> assert_ok
  in
  let legacy =
    Nixploy.Resource_key.derive_legacy ~project ~target:target_name
      ~repository:"git@example.invalid:sample.git"
    |> assert_ok
  in
  let canonical_key = Nixploy.Resource_key.to_string canonical in
  let current_key = Nixploy.Resource_key.to_string current in
  let legacy_key = Nixploy.Resource_key.to_string legacy in
  install_executable bin "nix"
    {|#!/bin/sh
set -eu
printf 'nix' >> "$NIXPLOY_TEST_TRACE"
printf '|%s' "$@" >> "$NIXPLOY_TEST_TRACE"
printf '\n' >> "$NIXPLOY_TEST_TRACE"
if [ "$*" != "eval --json --no-write-lock-file path:.#nixploy" ]; then
  echo "unexpected nix command: $*" >&2
  exit 97
fi
if [ "${NIXPLOY_TEST_WEB:-}" = "1" ]; then
  printf '%s\n' '{"__schema":"v0.3","project":"sample","targets":{"worker":{"image":"workerImage","ip":"worker.invalid","user":"deployer","port":2222,"web":{"domain":"worker.example.invalid"}}}}'
else
  printf '%s\n' '{"__schema":"v0.3","project":"sample","targets":{"worker":{"image":"workerImage","ip":"worker.invalid","user":"deployer","port":2222}}}'
fi
|};
  install_executable bin "ssh"
    {|#!/bin/sh
set -eu
printf 'ssh' >> "$NIXPLOY_TEST_TRACE"
printf '|%s' "$@" >> "$NIXPLOY_TEST_TRACE"
printf '\n' >> "$NIXPLOY_TEST_TRACE"
[ "$#" -eq 11 ]
[ "$1" = "-o" ] && [ "$2" = "BatchMode=yes" ]
[ "$3" = "-o" ] && [ "$4" = "StrictHostKeyChecking=yes" ]
[ "$5" = "-o" ] && [ "$6" = "ConnectTimeout=10" ]
[ "$7" = "-p" ] && [ "$8" = "2222" ]
[ "$9" = "--" ] && [ "${10}" = "deployer@worker.invalid" ]
remote=${11}
case "$remote" in
  *"'podman' 'ps'"*)
    if [ -n "${NIXPLOY_TEST_REMOTE_RESOURCE:-}" ]; then
      printf '[{"Labels":{"io.nixploy.resource_key":"%s","io.nixploy.repository":"%s"}}]\n' "$NIXPLOY_TEST_REMOTE_RESOURCE" "${NIXPLOY_TEST_REMOTE_REPOSITORY:-git@example.invalid:sample.git}"
    else
      printf '[]\n'
    fi
    ;;
  "'true'") : ;;
  *"'-X' 'GET'"*"/id/nixploy-proxy-"*"/upstreams"*)
    printf '[{"dial":"127.0.0.1:8080"}]\n200'
    ;;
  *"'-X' 'GET'"*"/id/nixploy-route-$NIXPLOY_TEST_KEY"*)
    if [ "${NIXPLOY_TEST_CADDY_INSPECT_ERROR:-}" = "1" ]; then
      printf '\n500'
    elif [ "${NIXPLOY_TEST_CADDY_MISSING:-}" = "1" ] || [ -f "$NIXPLOY_TEST_REMOTE_STATE/route-deleted" ]; then
      printf '\n404'
    else
      printf '{"@id":"nixploy-route-%s","match":[{"host":["%s"]}],"handle":[{"handler":"subroute","routes":[{"handle":[{"@id":"nixploy-proxy-%s","handler":"reverse_proxy","upstreams":[{"dial":"127.0.0.1:8080"}]}]}]}],"terminal":true}\n200' "$NIXPLOY_TEST_KEY" "${NIXPLOY_TEST_ROUTE_DOMAIN:-worker.example.invalid}" "$NIXPLOY_TEST_KEY"
    fi
    ;;
  *"'-X' 'DELETE'"*"/id/nixploy-route-$NIXPLOY_TEST_KEY"*)
    if [ "${NIXPLOY_TEST_CADDY_DELETE_ERROR:-}" = "1" ]; then
      printf '\n500'
    elif [ "${NIXPLOY_TEST_CADDY_MISSING:-}" = "1" ] || [ -f "$NIXPLOY_TEST_REMOTE_STATE/route-deleted" ]; then
      printf '\n404'
    else
      : > "$NIXPLOY_TEST_REMOTE_STATE/route-deleted"
      printf '\n204'
    fi
    ;;
  *) echo "unexpected ssh command: $remote" >&2; exit 98 ;;
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
    if [ "${NIXPLOY_TEST_WRONG_CONNECTION:-}" = "1" ]; then
      printf '[{"Name":"%s","URI":"ssh://deployer@wrong.invalid:2222/run/user/1000/podman/podman.sock"}]\n' "$NIXPLOY_TEST_KEY"
    elif [ "${NIXPLOY_TEST_CHANGED_IDENTITY:-}" = "1" ]; then
      printf '[{"Name":"%s","URI":"ssh://deployer@worker.invalid:2222/run/user/1000/podman/podman.sock","Identity":"/retired/key"}]\n' "$NIXPLOY_TEST_KEY"
    elif [ "${NIXPLOY_TEST_LEGACY_CONNECTION:-}" = "1" ]; then
      printf '[{"Name":"%s","URI":"ssh://deployer@worker.invalid:2222/run/user/1000/podman/podman.sock"}]\n' "$NIXPLOY_TEST_LEGACY_KEY"
    elif [ "${NIXPLOY_TEST_CURRENT_CONNECTION:-}" = "1" ]; then
      printf '[{"Name":"%s","URI":"ssh://deployer@worker.invalid:2222/run/user/1000/podman/podman.sock"}]\n' "$NIXPLOY_TEST_CURRENT_KEY"
    else
      printf '[]\n'
    fi
    exit 0
    ;;
  system\ connection\ remove\ *)
    [ "$*" = "system connection remove $NIXPLOY_TEST_KEY" ]
    if [ "${NIXPLOY_TEST_FAIL_CONNECTION_REMOVE:-}" = "1" ]; then
      echo 'connection removal failed' >&2
      exit 45
    fi
    exit 0
    ;;
  system\ connection\ add\ *)
    [ "$*" = "system connection add $NIXPLOY_TEST_KEY --port 2222 deployer@worker.invalid" ]
    exit 0
    ;;
esac
if [ "${1:-}" = "--connection" ]; then
  [ "${2:-}" = "$NIXPLOY_TEST_KEY" ] || { echo "wrong connection: ${2:-}" >&2; exit 90; }
fi
if [ "$*" = "--connection $NIXPLOY_TEST_KEY info" ]; then exit 0; fi
if [ "${3:-}" = "container" ] && [ "${4:-}" = "exists" ]; then
  name=${5:-}
  case "$name" in
    "$NIXPLOY_TEST_KEY") id=single-id ;;
    "$NIXPLOY_TEST_KEY-blue") id=blue-id ;;
    "$NIXPLOY_TEST_KEY-green") exit 1 ;;
    *) echo "arbitrary container name: $name" >&2; exit 94 ;;
  esac
  [ -f "$NIXPLOY_TEST_REMOTE_STATE/removed-$id" ] && exit 1
  exit 0
fi
if [ "${3:-}" = "inspect" ] && [ "${5:-}" = "container" ]; then
  name=${6:-}
  id=single-id
  [ "$name" = "$NIXPLOY_TEST_KEY-blue" ] && id=blue-id
  resource=$NIXPLOY_TEST_KEY
  if [ "${NIXPLOY_TEST_UNOWNED_BLUE:-}" = "1" ] && [ "$name" = "$NIXPLOY_TEST_KEY-blue" ]; then resource=foreign-resource; fi
  printf '[{"Id":"%s","Config":{"Labels":{"io.nixploy.managed":"true","io.nixploy.project":"sample","io.nixploy.target":"worker","io.nixploy.resource_key":"%s"}}}]\n' "$id" "$resource"
  exit 0
fi
if [ "${3:-}" = "secret" ] && [ "${4:-}" = "ls" ]; then
  [ "${NIXPLOY_TEST_FAIL_SECRET_LIST:-}" = "1" ] && { echo "secret listing failed" >&2; exit 42; }
  printf '['
  separator=''
  if [ ! -f "$NIXPLOY_TEST_REMOTE_STATE/secret-api" ]; then printf '%s{"Name":"%s-api"}' "$separator" "$NIXPLOY_TEST_KEY"; separator=,; fi
  if [ ! -f "$NIXPLOY_TEST_REMOTE_STATE/secret-db" ]; then printf '%s{"Spec":{"Name":"%s-db"}}' "$separator" "$NIXPLOY_TEST_KEY"; separator=,; fi
  printf '%s{"Name":"%sish-unrelated"},{"Name":"unrelated"}]\n' "$separator" "$NIXPLOY_TEST_KEY"
  exit 0
fi
if [ "${3:-}" = "rm" ] && [ "${4:-}" = "-f" ]; then
  id=${5:-}
  case "$id" in single-id|blue-id) : ;; *) exit 93 ;; esac
  if [ "${NIXPLOY_TEST_FAIL_CONTAINER_ONCE:-}" = "1" ] && [ "$id" = "blue-id" ] && [ ! -f "$NIXPLOY_TEST_REMOTE_STATE/container-failed" ]; then
    : > "$NIXPLOY_TEST_REMOTE_STATE/container-failed"
    echo "container removal failed" >&2
    exit 43
  fi
  : > "$NIXPLOY_TEST_REMOTE_STATE/removed-$id"
  exit 0
fi
if [ "${3:-}" = "secret" ] && [ "${4:-}" = "rm" ]; then
  name=${5:-}
  case "$name" in "$NIXPLOY_TEST_KEY-api") short=api ;; "$NIXPLOY_TEST_KEY-db") short=db ;; *) echo "unrelated secret selected: $name" >&2; exit 92 ;; esac
  if [ "${NIXPLOY_TEST_FAIL_SECRET_ONCE:-}" = "1" ] && [ "$short" = "db" ] && [ ! -f "$NIXPLOY_TEST_REMOTE_STATE/secret-failed" ]; then
    : > "$NIXPLOY_TEST_REMOTE_STATE/secret-failed"
    echo "secret removal failed" >&2
    exit 44
  fi
  : > "$NIXPLOY_TEST_REMOTE_STATE/secret-$short"
  exit 0
fi
echo "unexpected podman command: $*" >&2
exit 99
|};
  let environment_names =
    [
      "PATH";
      "SSH_AUTH_SOCK";
      "NIXPLOY_TEST_TRACE";
      "NIXPLOY_TEST_KEY";
      "NIXPLOY_TEST_LEGACY_KEY";
      "NIXPLOY_TEST_CURRENT_KEY";
      "NIXPLOY_TEST_REMOTE_STATE";
      "NIXPLOY_TEST_WEB";
      "NIXPLOY_TEST_REMOTE_RESOURCE";
      "NIXPLOY_TEST_REMOTE_REPOSITORY";
      "NIXPLOY_TEST_LEGACY_CONNECTION";
      "NIXPLOY_TEST_CURRENT_CONNECTION";
      "NIXPLOY_TEST_WRONG_CONNECTION";
      "NIXPLOY_TEST_CHANGED_IDENTITY";
      "NIXPLOY_TEST_FAIL_CONNECTION_REMOVE";
      "NIXPLOY_TEST_ROUTE_DOMAIN";
      "NIXPLOY_TEST_UNOWNED_BLUE";
      "NIXPLOY_TEST_FAIL_SECRET_LIST";
      "NIXPLOY_TEST_CADDY_MISSING";
      "NIXPLOY_TEST_CADDY_INSPECT_ERROR";
      "NIXPLOY_TEST_CADDY_DELETE_ERROR";
      "NIXPLOY_TEST_FAIL_CONTAINER_ONCE";
      "NIXPLOY_TEST_FAIL_SECRET_ONCE";
    ]
  in
  let old_environment =
    List.map environment_names ~f:(fun name -> (name, Sys.getenv name))
  in
  Caml_unix.putenv "PATH" (bin ^ ":" ^ Sys.getenv_exn "PATH");
  Core_unix.unsetenv "SSH_AUTH_SOCK";
  Caml_unix.putenv "NIXPLOY_TEST_TRACE" trace;
  Caml_unix.putenv "NIXPLOY_TEST_REMOTE_STATE" remote_state;
  Caml_unix.putenv "NIXPLOY_TEST_LEGACY_KEY" legacy_key;
  Caml_unix.putenv "NIXPLOY_TEST_CURRENT_KEY" current_key;
  let scenario_names = List.drop environment_names 7 in
  let clear_scenario key =
    List.iter scenario_names ~f:Core_unix.unsetenv;
    Caml_unix.putenv "NIXPLOY_TEST_KEY" key;
    Sys_unix.ls_dir remote_state
    |> List.iter ~f:(fun name ->
        Core_unix.unlink (Filename.concat remote_state name));
    write trace ""
  in
  let cleanup () =
    List.iter old_environment ~f:(fun (name, value) -> set_or_unset name value);
    Nixploy.Process_runner.run_stdout ~timeout:(Time_ns.Span.of_sec 5.)
      ~max_output_bytes:65_536 ~prog:"rm" ~args:[ "-rf"; "--"; root ] ()
    >>| fun _ -> ()
  in
  Monitor.protect ~finally:cleanup (fun () ->
      let%bind opened =
        Nixploy.Store.open_ ~path:(Filename.concat root "state.sqlite")
      in
      let application =
        Nixploy.Application.create ~store:(assert_ok opened) ()
      in
      let prune ?expected_project () =
        Nixploy.Application.prune ?expected_project application
          ~working_directory:project_directory ~target:target_name
      in

      let wrong_project =
        Nixploy.Project_name.of_string "another-project" |> assert_ok
      in
      clear_scenario canonical_key;
      let%bind marked_present =
        Nixploy.Store.set_resource_state (assert_ok opened)
          ~working_directory:project_directory ~target:target_name Present
      in
      assert_ok marked_present;
      let%bind project_mismatch = prune ~expected_project:wrong_project () in
      expect_error_containing project_mismatch "managed project mismatch";
      let lines = In_channel.read_lines trace in
      [%test_eq: int] 1 (count lines "nix|eval|");
      assert (
        List.for_all lines ~f:(Fn.non (String.is_prefix ~prefix:"podman|")));
      assert (List.for_all lines ~f:(Fn.non (String.is_prefix ~prefix:"ssh|")));
      let%bind rejected_state =
        Nixploy.Application.resource_state application
          ~working_directory:project_directory ~target:target_name
      in
      assert (
        [%equal: Nixploy.Application.resource_state] (assert_ok rejected_state)
          Unknown);

      clear_scenario canonical_key;
      Caml_unix.putenv "NIXPLOY_TEST_REMOTE_RESOURCE" canonical_key;
      let other_repository = "git@example.invalid:other.git" in
      let other_candidates =
        Nixploy.Resource_key.candidates ~project ~target:target_name
          ~repository_identity:other_repository
        |> assert_ok
      in
      let%bind selected_for_other_repository =
        Nixploy.Podman.select_resource_key ~project ~target
          ~repository_identity:other_repository ~candidates:other_candidates
      in
      [%test_eq: string]
        (List.hd_exn other_candidates |> Nixploy.Resource_key.to_string)
        (assert_ok selected_for_other_repository
        |> Nixploy.Resource_key.to_string);

      clear_scenario canonical_key;
      let%bind non_web = prune () in
      let non_web = assert_ok non_web in
      [%test_eq: string] canonical_key
        (Nixploy.Application.prune_resource_key non_web
        |> Nixploy.Resource_key.to_string);
      [%test_eq: int] 2 (Nixploy.Application.prune_containers_removed non_web);
      [%test_eq: int] 2 (Nixploy.Application.prune_secrets_removed non_web);
      [%test_eq: Nixploy.Application.prune_route_state] Not_configured
        (Nixploy.Application.prune_route_state non_web);
      let lines = In_channel.read_lines trace in
      [%test_eq: int] 3 (count lines "|container|exists|");
      [%test_eq: int] 2 (count lines "|inspect|--type|container|");
      [%test_eq: int] 2 (count lines "|rm|-f|");
      [%test_eq: int] 2 (count lines "|secret|rm|");
      assert (count lines "curl" = 0);
      assert (
        List.for_all lines
          ~f:(Fn.non (String.is_substring ~substring:"ish-unrelated")));

      clear_scenario canonical_key;
      Caml_unix.putenv "NIXPLOY_TEST_WEB" "1";
      let%bind web = prune () in
      let web = assert_ok web in
      [%test_eq: Nixploy.Application.prune_route_state] Removed
        (Nixploy.Application.prune_route_state web);
      let lines = In_channel.read_lines trace in
      let last_inspect =
        index_of lines ("|inspect|--type|container|" ^ canonical_key ^ "-blue")
      in
      let secrets_list = index_of lines "|secret|ls|--format|json" in
      let route_get =
        index_of lines
          ("'-X' 'GET' '--write-out' '\\n%{http_code}' \
            'http://127.0.0.1:2019/id/nixploy-route-" ^ canonical_key)
      in
      let upstream_get =
        index_of lines ("/id/nixploy-proxy-" ^ canonical_key ^ "/upstreams")
      in
      let route_delete =
        index_of lines
          ("'-X' 'DELETE' '--write-out' '\\n%{http_code}' \
            'http://127.0.0.1:2019/id/nixploy-route-" ^ canonical_key)
      in
      let first_container_remove = index_of lines "|rm|-f|single-id" in
      let first_secret_remove = index_of lines "|secret|rm|" in
      assert (
        last_inspect < secrets_list
        && secrets_list < route_get && route_get < upstream_get
        && upstream_get < route_delete
        && route_delete < first_container_remove
        && first_container_remove < first_secret_remove);
      let ssh_prefix =
        "ssh|-o|BatchMode=yes|-o|StrictHostKeyChecking=yes|-o|ConnectTimeout=10|-p|2222|--|deployer@worker.invalid|"
      in
      [%test_eq: string list]
        [
          ssh_prefix
          ^ "'curl' '-sS' '-X' 'GET' '--write-out' '\\n%{http_code}' \
             'http://127.0.0.1:2019/id/nixploy-route-" ^ canonical_key ^ "'";
          ssh_prefix
          ^ "'curl' '-sS' '-X' 'GET' '--write-out' '\\n%{http_code}' \
             'http://127.0.0.1:2019/id/nixploy-proxy-" ^ canonical_key
          ^ "/upstreams'";
          ssh_prefix
          ^ "'curl' '-sS' '-X' 'DELETE' '--write-out' '\\n%{http_code}' \
             'http://127.0.0.1:2019/id/nixploy-route-" ^ canonical_key ^ "'";
        ]
        (List.filter lines ~f:(String.is_substring ~substring:"|'curl'"));

      clear_scenario canonical_key;
      Caml_unix.putenv "NIXPLOY_TEST_WEB" "1";
      Caml_unix.putenv "NIXPLOY_TEST_CADDY_MISSING" "1";
      let%bind missing = prune () in
      let missing = assert_ok missing in
      [%test_eq: Nixploy.Application.prune_route_state] Missing
        (Nixploy.Application.prune_route_state missing);

      clear_scenario canonical_key;
      Caml_unix.putenv "NIXPLOY_TEST_WEB" "1";
      Caml_unix.putenv "NIXPLOY_TEST_ROUTE_DOMAIN" "retired.example.invalid";
      let%bind changed_domain = prune () in
      let changed_domain = assert_ok changed_domain in
      [%test_eq: Nixploy.Application.prune_route_state] Removed
        (Nixploy.Application.prune_route_state changed_domain);
      let lines = In_channel.read_lines trace in
      let route_get = index_of lines "'-X' 'GET'" in
      let route_delete = index_of lines "'-X' 'DELETE'" in
      assert (route_get < route_delete);

      clear_scenario canonical_key;
      Caml_unix.putenv "NIXPLOY_TEST_UNOWNED_BLUE" "1";
      let%bind unowned = prune () in
      expect_error_containing unowned "not owned";
      let lines = In_channel.read_lines trace in
      assert (count lines "|rm|-f|" = 0);
      assert (count lines "|secret|rm|" = 0);

      clear_scenario canonical_key;
      Caml_unix.putenv "NIXPLOY_TEST_WEB" "1";
      Caml_unix.putenv "NIXPLOY_TEST_WRONG_CONNECTION" "1";
      let%bind changed_connection = prune () in
      ignore (assert_ok changed_connection : Nixploy.Application.prune_result);
      let lines = In_channel.read_lines trace in
      let ssh_preflight = index_of lines "|'true'" in
      let removed = index_of lines "|system|connection|remove|" in
      let added = index_of lines "|system|connection|add|" in
      let verified =
        index_of lines ("|--connection|" ^ canonical_key ^ "|info")
      in
      let first_resource_use = index_of lines "|container|exists|" in
      assert (
        ssh_preflight < removed && removed < added && added < verified
        && verified < first_resource_use);

      clear_scenario canonical_key;
      Caml_unix.putenv "NIXPLOY_TEST_CHANGED_IDENTITY" "1";
      let%bind changed_identity = prune () in
      ignore (assert_ok changed_identity : Nixploy.Application.prune_result);
      let lines = In_channel.read_lines trace in
      assert (count lines "|system|connection|remove|" = 1);
      assert (count lines "|system|connection|add|" = 1);
      assert (count lines ("|--connection|" ^ canonical_key ^ "|info") = 1);

      clear_scenario canonical_key;
      Caml_unix.putenv "NIXPLOY_TEST_WRONG_CONNECTION" "1";
      Caml_unix.putenv "NIXPLOY_TEST_FAIL_CONNECTION_REMOVE" "1";
      let%bind removal_failure = prune () in
      expect_error_containing removal_failure "connection removal failed";
      let lines = In_channel.read_lines trace in
      assert (count lines "|system|connection|remove|" = 1);
      assert (count lines "|system|connection|add|" = 0);
      assert (count lines "|container|exists|" = 0);

      clear_scenario canonical_key;
      Caml_unix.putenv "NIXPLOY_TEST_WEB" "1";
      Caml_unix.putenv "NIXPLOY_TEST_CADDY_INSPECT_ERROR" "1";
      let%bind caddy_preflight_failure = prune () in
      expect_error_containing caddy_preflight_failure
        "Caddy route read returned HTTP 500";
      let lines = In_channel.read_lines trace in
      assert (count lines "'-X' 'DELETE'" = 0);
      assert (count lines "|rm|-f|" = 0);
      assert (count lines "|secret|rm|" = 0);

      clear_scenario canonical_key;
      Caml_unix.putenv "NIXPLOY_TEST_WEB" "1";
      Caml_unix.putenv "NIXPLOY_TEST_CADDY_DELETE_ERROR" "1";
      let%bind caddy_failure = prune () in
      expect_error_containing caddy_failure
        "Caddy route deletion returned HTTP 500";
      let lines = In_channel.read_lines trace in
      assert (count lines "|rm|-f|" = 0);
      assert (count lines "|secret|rm|" = 0);

      clear_scenario canonical_key;
      Caml_unix.putenv "NIXPLOY_TEST_FAIL_SECRET_LIST" "1";
      let%bind list_failure = prune () in
      expect_error_containing list_failure "secret listing failed";
      let lines = In_channel.read_lines trace in
      assert (count lines "|rm|-f|" = 0);
      assert (count lines "|secret|rm|" = 0);

      clear_scenario canonical_key;
      Caml_unix.putenv "NIXPLOY_TEST_WEB" "1";
      Caml_unix.putenv "NIXPLOY_TEST_FAIL_CONTAINER_ONCE" "1";
      let%bind container_failure = prune () in
      expect_error_containing container_failure
        ("could not remove owned container " ^ canonical_key ^ "-blue");
      let%bind container_rerun = prune () in
      let container_rerun = assert_ok container_rerun in
      [%test_eq: Nixploy.Application.prune_route_state] Missing
        (Nixploy.Application.prune_route_state container_rerun);

      clear_scenario canonical_key;
      Caml_unix.putenv "NIXPLOY_TEST_FAIL_SECRET_ONCE" "1";
      let%bind secret_failure = prune () in
      expect_error_containing secret_failure
        ("could not remove owned secret " ^ canonical_key ^ "-db");
      let%bind secret_rerun = prune () in
      ignore (assert_ok secret_rerun : Nixploy.Application.prune_result);

      clear_scenario current_key;
      Caml_unix.putenv "NIXPLOY_TEST_REMOTE_RESOURCE" current_key;
      let%bind adopted_current = prune () in
      let adopted_current = assert_ok adopted_current in
      [%test_eq: string] current_key
        (Nixploy.Application.prune_resource_key adopted_current
        |> Nixploy.Resource_key.to_string);

      clear_scenario canonical_key;
      Caml_unix.putenv "NIXPLOY_TEST_REMOTE_RESOURCE" legacy_key;
      Caml_unix.putenv "NIXPLOY_TEST_REMOTE_REPOSITORY"
        "git@example.invalid:foreign.git";
      let%bind unrelated_repository = prune () in
      [%test_eq: string] canonical_key
        (assert_ok unrelated_repository
        |> Nixploy.Application.prune_resource_key
        |> Nixploy.Resource_key.to_string);

      clear_scenario canonical_key;
      Caml_unix.putenv "NIXPLOY_TEST_REMOTE_RESOURCE" "unexpected-resource";
      let%bind unexpected_owned = prune () in
      expect_error_containing unexpected_owned
        "owned by this repository use an unexpected resource identity";
      let lines = In_channel.read_lines trace in
      assert (count lines "|container|exists|" = 0);
      assert (count lines "|secret|rm|" = 0);

      clear_scenario legacy_key;
      Caml_unix.putenv "NIXPLOY_TEST_LEGACY_CONNECTION" "1";
      let%bind adopted_connection = prune () in
      let adopted_connection = assert_ok adopted_connection in
      [%test_eq: string] legacy_key
        (Nixploy.Application.prune_resource_key adopted_connection
        |> Nixploy.Resource_key.to_string);
      let lines = In_channel.read_lines trace in
      assert (count lines "|system|connection|add|" = 0);
      assert (
        List.exists lines
          ~f:(String.equal ("podman|--connection|" ^ legacy_key ^ "|info")));

      clear_scenario legacy_key;
      Caml_unix.putenv "NIXPLOY_TEST_REMOTE_RESOURCE" legacy_key;
      Caml_unix.putenv "NIXPLOY_TEST_LEGACY_CONNECTION" "1";
      let%map adopted_resource = prune () in
      let adopted_resource = assert_ok adopted_resource in
      [%test_eq: string] legacy_key
        (Nixploy.Application.prune_resource_key adopted_resource
        |> Nixploy.Resource_key.to_string))

let () =
  don't_wait_for
    ( Monitor.try_with run_tests >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1 );
  never_returns (Scheduler.go ())
