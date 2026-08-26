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

let expect_error_containing result text =
  match result with
  | Ok _ -> failwith "deployment unexpectedly succeeded"
  | Error error ->
      assert (String.is_substring (Error.to_string_hum error) ~substring:text)

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
    if [ "${NIXPLOY_TEST_BINDS:-}" = "1" ]; then
      cat <<'JSON'
{"__schema":"v0.4","project":"sample","targets":{"worker":{"image":"workerImage","ip":"worker.invalid","run":{"command":["/app/worker","--once"],"environment":{"MODE":"worker"},"preStart":[["/app/migrate"],["/app/seed"]],"network":"private","ports":["127.0.0.1:9000:9000"],"readOnlyBinds":[{"source":"/srv/reference data","destination":"/app/reference data"}]}}}}
JSON
    elif [ "${NIXPLOY_TEST_SECRETS:-}" = "1" ]; then
      secret_path=${NIXPLOY_TEST_SECRET_PATH:-config/secrets.env}
      printf '{"__schema":"v0.3","project":"sample","targets":{"worker":{"image":"workerImage","ip":"worker.invalid","run":{"command":["/app/worker",""]},"secrets":{"app":"%s"}}}}\n' "$secret_path"
    elif [ "${NIXPLOY_TEST_PRODUCTION:-}" = "1" ]; then
      cat <<'JSON'
{"__schema":"v0.4","project":"sample","targets":{"worker":{"image":"workerImage","ip":"worker.invalid","user":"deploy","production":{"coordinationScope":"sample-worker"}}}}
JSON
    elif [ "${NIXPLOY_TEST_WEB:-}" = "1" ]; then
      cat <<'JSON'
{"__schema":"v0.3","project":"sample","targets":{"worker":{"image":"workerImage","ip":"worker.invalid","run":{"command":["/app/worker","--once"],"environment":{"PORT":"{port}","MODE":"worker","RELEASE_REVISION":"{revision}","RELEASE_BINDING":"{revision}:{port}"},"preStart":[["/app/migrate"],["/app/seed"]],"network":"private","ports":["127.0.0.1:9000:9000"]},"web":{"domain":"worker.example.invalid","healthPath":"/health","slots":{"blue":8080,"green":8081}}}}}
JSON
    else
      cat <<'JSON'
{"__schema":"v0.3","project":"sample","targets":{"worker":{"image":"workerImage","ip":"worker.invalid","run":{"command":["/app/worker","--once"],"environment":{"PORT":"{port}","MODE":"worker","RELEASE_REVISION":"{revision}"},"preStart":[["/app/migrate"],["/app/seed"]],"network":"private","ports":["127.0.0.1:9000:9000"]}}}}
JSON
    fi
    ;;
  build) printf '/nix/store/nixploy-fake-image\n' ;;
  *) echo "unexpected nix command" >&2; exit 97 ;;
esac
|};
  install_executable bin "ssh-to-age"
    {|#!/bin/sh
set -eu
printf 'ssh-to-age' >> "$NIXPLOY_TEST_TRACE"
printf '|%s' "$@" >> "$NIXPLOY_TEST_TRACE"
printf '\n' >> "$NIXPLOY_TEST_TRACE"
printf 'AGE-SECRET-KEY-TEST\n'
|};
  install_executable bin "sops"
    {|#!/bin/sh
set -eu
printf 'sops' >> "$NIXPLOY_TEST_TRACE"
printf '|%s' "$@" >> "$NIXPLOY_TEST_TRACE"
printf '\n' >> "$NIXPLOY_TEST_TRACE"
last=""
for argument in "$@"; do last="$argument"; done
case "$last" in
  */config/secrets.env) : ;;
  *) echo "unexpected secret path: $last" >&2; exit 96 ;;
esac
printf 'EMPTY=\n'
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
  "'test' '-e' '/srv/reference data'")
    if [ "${NIXPLOY_TEST_MISSING_BIND:-}" = "1" ]; then
      echo 'missing bind source' >&2
      exit 1
    fi
    ;;
  *"'curl' '-fsS' '--max-time' '2'"*) : ;;
  *"'-X' 'GET'"*"/config/apps/http/servers/nixploy"*) printf '\n200' ;;
  *"'-X' 'POST'"*"/config/apps/http/servers/nixploy/routes"*)
    body=$(cat)
    printf '%s' "$body" | grep -q '"host":\["worker.example.invalid"\]'
    printf '8080\nworker.example.invalid\n' > "$NIXPLOY_TEST_ROUTE_STATE"
    printf '\n200'
    ;;
  *"'-X' 'PATCH'"*"/id/nixploy-route-"*)
    body=$(cat)
    port=$(printf '%s' "$body" | sed -n 's/.*127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p')
    domain=$(printf '%s' "$body" | sed -n 's/.*"host":\["\([^"]*\)"\].*/\1/p')
    [ -n "$port" ] && [ -n "$domain" ]
    printf '%s\n%s\n' "$port" "$domain" > "$NIXPLOY_TEST_ROUTE_STATE"
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
      port=$(sed -n '1p' "$NIXPLOY_TEST_ROUTE_STATE")
      domain=$(sed -n '2p' "$NIXPLOY_TEST_ROUTE_STATE")
      printf '{"@id":"%s","match":[{"host":["%s"]}],"handle":[{"handler":"subroute","routes":[{"handle":[{"@id":"%s","handler":"reverse_proxy","upstreams":[{"dial":"127.0.0.1:%s"}]}]}]}],"terminal":true}\n200' "$route_id" "$domain" "$proxy_id" "$port"
    fi
    ;;
  *"'-X' 'GET'"*"/id/nixploy-proxy-"*"/upstreams"*)
    port=$(sed -n '1p' "$NIXPLOY_TEST_ROUTE_STATE")
    printf '[{"dial":"127.0.0.1:%s"}]\n200' "$port"
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
  *" secret rm "*) exit 1 ;;
  *" secret create "*) cat >/dev/null; exit 0 ;;
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
  if [ "${NIXPLOY_TEST_FAIL_RETIREMENT:-}" = "${5:-}" ]; then exit 0; fi
  if [ -f "$NIXPLOY_TEST_STATE" ]; then exit 0; fi
  if [ "${NIXPLOY_TEST_EXISTING_WEB:-}" = "1" ]; then
    case "${5:-}" in *-blue) exit 0 ;; esac
  fi
  if [ "${NIXPLOY_TEST_EXISTING_SINGLE:-}" = "1" ]; then
    case "${5:-}" in *-blue|*-green) ;; *) exit 0 ;; esac
  fi
  if [ "${NIXPLOY_TEST_FOREIGN_SINGLE:-}" = "1" ]; then
    case "${5:-}" in *-blue|*-green) ;; *) exit 0 ;; esac
  fi
  if [ "${NIXPLOY_TEST_WEB:-}" = "1" ]; then exit 1; fi
  exit 0
fi
if [ "${3:-}" = "inspect" ] && [ "${5:-}" = "container" ]; then
  name="${6}"
  if [ -f "$NIXPLOY_TEST_STATE" ]; then
    IFS='|' read -r runtime_name digest operation revision resource < "$NIXPLOY_TEST_STATE"
    image='sha256:image-id'
    if [ "${NIXPLOY_TEST_VERIFY_MISMATCH:-}" = "1" ]; then image='sha256:wrong-image'; fi
    printf '[{"Id":"candidate-id","Name":"%s","Image":"%s","State":{"Running":true},"Config":{"Labels":{"io.nixploy.managed":"true","io.nixploy.project":"sample","io.nixploy.target":"worker","io.nixploy.resource_key":"%s","io.nixploy.repository":"git@example.invalid:test.git","io.nixploy.repository_identity":"git@example.invalid:test.git","io.nixploy.revision":"%s","io.nixploy.configuration_digest":"%s","io.nixploy.operation_id":"%s"}}}]\n' "$runtime_name" "$image" "$resource" "$revision" "$digest" "$operation"
  elif [ "${NIXPLOY_TEST_UNOWNED:-}" = "1" ] || { [ "${NIXPLOY_TEST_FOREIGN_SINGLE:-}" = "1" ] && ! printf '%s' "$name" | grep -Eq -- '-(blue|green)$'; }; then
    printf '[{"Id":"foreign-id","Name":"%s","Config":{"Labels":{"io.nixploy.managed":"true","io.nixploy.project":"sample","io.nixploy.target":"worker","io.nixploy.resource_key":"conflicting-modern-resource","io.nixploy.repository_identity":"git@example.invalid:foreign.git","nixploy.project":"sample","nixploy.target":"worker"}}}]\n' "$name"
  else
    resource=${name%-blue}
    resource=${resource%-green}
    case "$name" in
      *-blue|*-green) old_id=old-slot-id ;;
      *) old_id=single-id ;;
    esac
    case "${NIXPLOY_TEST_LABEL_MODE:-valid}" in
      valid)
        labels='"io.nixploy.managed":"true","io.nixploy.project":"sample","io.nixploy.target":"worker","io.nixploy.resource_key":"'"$resource"'","io.nixploy.repository_identity":"git@example.invalid:test.git"'
        ;;
      legacy)
        labels='"nixploy.project":"sample","nixploy.target":"worker","nixploy.resource_key":"'"$resource"'","nixploy.repository":"git@example.invalid:test.git"'
        ;;
      mixed)
        labels='"io.nixploy.managed":"true","io.nixploy.project":"sample","nixploy.target":"worker","nixploy.resource_key":"'"$resource"'","io.nixploy.repository_identity":"git@example.invalid:test.git"'
        ;;
      partial)
        labels='"io.nixploy.managed":"true","io.nixploy.project":"sample","io.nixploy.target":"worker","io.nixploy.repository_identity":"git@example.invalid:test.git"'
        ;;
      wrong-resource)
        labels='"io.nixploy.managed":"true","io.nixploy.project":"sample","io.nixploy.target":"worker","io.nixploy.resource_key":"wrong","io.nixploy.repository_identity":"git@example.invalid:test.git"'
        ;;
      *) echo "unexpected label mode" >&2; exit 95 ;;
    esac
    printf '[{"Id":"%s","Name":"%s","Config":{"Labels":{%s}}}]\n' "$old_id" "$name" "$labels"
  fi
  exit 0
fi
if [ "${3:-}" = "rm" ] && [ "${4:-}" = "-f" ] && [ -n "${5:-}" ] && [ -z "${6:-}" ]; then
  if [ "${NIXPLOY_TEST_FAIL_RETIREMENT:-}" = "${5:-}" ]; then
    echo 'retirement failed' >&2
    exit 42
  fi
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
      "NIXPLOY_TEST_PRODUCTION";
      "NIXPLOY_TEST_EXISTING_WEB";
      "NIXPLOY_TEST_EXISTING_SINGLE";
      "NIXPLOY_TEST_FOREIGN_SINGLE";
      "NIXPLOY_TEST_LABEL_MODE";
      "NIXPLOY_TEST_FAIL_RETIREMENT";
      "NIXPLOY_TEST_BINDS";
      "NIXPLOY_TEST_MISSING_BIND";
      "NIXPLOY_TEST_SECRETS";
      "NIXPLOY_TEST_SECRET_PATH";
      "NIXPLOY_TEST_EXPECTED_SECRET";
      "NIXPLOY_REVISION";
      "SOPS_AGE_KEY_FILE";
      "NIXPLOY_SOPS_AGE_SSH_PRIVATE_KEY_FILE";
      "SOPS_AGE_SSH_PRIVATE_KEY_FILE";
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
        "NIXPLOY_TEST_PRODUCTION";
        "NIXPLOY_TEST_EXISTING_WEB";
        "NIXPLOY_TEST_EXISTING_SINGLE";
        "NIXPLOY_TEST_FOREIGN_SINGLE";
        "NIXPLOY_TEST_LABEL_MODE";
        "NIXPLOY_TEST_FAIL_RETIREMENT";
        "NIXPLOY_TEST_BINDS";
        "NIXPLOY_TEST_MISSING_BIND";
        "NIXPLOY_TEST_SECRETS";
        "NIXPLOY_TEST_SECRET_PATH";
        "NIXPLOY_TEST_EXPECTED_SECRET";
        "NIXPLOY_REVISION";
        "SOPS_AGE_KEY_FILE";
        "NIXPLOY_SOPS_AGE_SSH_PRIVATE_KEY_FILE";
        "SOPS_AGE_SSH_PRIVATE_KEY_FILE";
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
      let expected_revision = Nixploy.Source.commit_revision commit in
      let target = Nixploy.Target_name.of_string "worker" |> assert_ok in
      let authorization ?expected_project ?expected_intent ?managed_application
          ?(managed_applications = []) source =
        let application_key =
          Option.map managed_application ~f:Nixploy.Managed_application.key
        in
        let expected_project =
          Option.first_some expected_project
            (Option.map managed_application
               ~f:Nixploy.Managed_application.project)
        in
        Nixploy.Operation_receipt.direct_deploy ~application_key ~expected_project
          ~intent:expected_intent ~application:managed_application
          ~managed_applications ~working_directory:repository ~source ~target
        |> assert_ok
      in
      let direct_store () =
        Nixploy.Store.open_ ~path:(Filename.concat root "direct.sqlite")
      in
      let deploy ?record_stage ?expected_project ?expected_intent
          ?managed_application ?managed_applications _operation_id =
        ignore record_stage;
        let authorization =
          authorization ?expected_project ?expected_intent ?managed_application
            ?managed_applications
            (Nixploy.Source.immutable commit)
        in
        let open Deferred.Or_error.Let_syntax in
        let%bind store = direct_store () in
        let source = Nixploy.Operation_receipt.deploy_source authorization in
        let working_directory =
          Nixploy.Operation_receipt.deploy_working_directory authorization
        in
        let target = Nixploy.Operation_receipt.deploy_target authorization in
        let%bind operation =
          Nixploy.Store.request store ~application_key:None ~working_directory
            ~target
            ~commit:(Nixploy.Source.selection_commit source)
        in
        Nixploy.Deployment.deploy ~store ~authorization
          ~operation_id:(Nixploy.Store.id operation)
          ()
      in
      let deploy_source _operation_id source =
        let authorization = authorization source in
        let open Deferred.Or_error.Let_syntax in
        let%bind store = direct_store () in
        let working_directory =
          Nixploy.Operation_receipt.deploy_working_directory authorization
        in
        let target = Nixploy.Operation_receipt.deploy_target authorization in
        let%bind operation =
          Nixploy.Store.request store ~application_key:None ~working_directory
            ~target
            ~commit:(Nixploy.Source.selection_commit source)
        in
        Nixploy.Deployment.deploy ~store ~authorization
          ~operation_id:(Nixploy.Store.id operation)
          ()
      in
      let application_store_path = Filename.concat root "application.sqlite" in
      let%bind application_store =
        Nixploy.Store.open_ ~path:application_store_path
      in
      let application_store = assert_ok application_store in
      let application =
        Nixploy.Application.create ~store:application_store ()
      in
      let%bind application_commit =
        Nixploy.Application.preview_main_commit application
          ~working_directory:repository
      in
      let application_commit = assert_ok application_commit in
      let expect_application_failure_leaves_unknown () =
        let%bind marked_present =
          Nixploy.Store.set_resource_state application_store
            ~working_directory:repository ~target Present
        in
        assert_ok marked_present;
        let%bind deployment =
          Nixploy.Application.deploy_non_production application
            ~working_directory:repository
            ~source:(Nixploy.Application.immutable_source application_commit)
            ~target ()
        in
        let deployment = assert_ok deployment in
        assert (
          [%equal: Nixploy.Application.deployment_state]
            (Nixploy.Application.deployment_state deployment)
            Failed);
        let%map resource_state =
          Nixploy.Application.resource_state application
            ~working_directory:repository ~target
        in
        assert (
          [%equal: Nixploy.Application.resource_state]
            (assert_ok resource_state) Unknown)
      in

      let expected_configuration_json =
        {|{"__schema":"v0.4","project":"sample","targets":{"worker":{"image":"workerImage","ip":"worker.invalid","user":"deploy","nonProduction":{"coordinationScope":"test-staging"},"run":{"command":["/app/worker","--once"],"environment":{"PORT":"{port}","MODE":"worker","RELEASE_REVISION":"{revision}"},"preStart":[["/app/migrate"],["/app/seed"]],"network":"private","ports":["127.0.0.1:9000:9000"]}}}}|}
      in
      let expected_configuration =
        Nixploy.Configuration.of_json expected_configuration_json |> assert_ok
      in
      let managed =
        Nixploy.Managed_application.all_of_json
          (sprintf
             {|{"app":{"project":"sample","target":"worker","repository":"%s","repositoryIdentity":"git@example.invalid:test.git","repositoryProvenance":"git@example.invalid:test.git","nonProduction":{"host":"worker.invalid","user":"deploy","port":22,"kind":"non-web","coordinationScope":"test-staging"}}}|}
             repository)
        |> assert_ok |> List.hd_exn
      in
      let production_managed =
        Nixploy.Managed_application.all_of_json
          (sprintf
             {|{"app":{"project":"sample","target":"worker","repository":"%s","repositoryIdentity":"git@example.invalid:test.git","repositoryProvenance":"git@example.invalid:test.git","repositoryReference":"refs/heads/main","repositoryEvidenceFile":"/root/test-evidence.json","production":{"host":"worker.invalid","user":"deploy","port":22,"kind":"non-web","coordinationScope":"sample-worker"}}}|}
             repository)
        |> assert_ok |> List.hd_exn
      in
      let expected_intent =
        Nixploy.Deployment_intent.create ~application:managed
          ~source_authority:None
          ~revision:(Nixploy.Source.commit_revision commit)
          ~configuration:expected_configuration
          ~configuration_json:expected_configuration_json
        |> assert_ok
      in
      let other_managed =
        Nixploy.Managed_application.all_of_json
          (sprintf
             {|{"other":{"project":"sample","target":"worker","repository":"%s","repositoryIdentity":"owner/other","repositoryProvenance":"git@example.invalid:other.git","nonProduction":{"host":"other.invalid","user":"deploy","port":22,"kind":"non-web","coordinationScope":"other-staging"}}}|}
             repository)
        |> assert_ok |> List.hd_exn
      in
      assert (
        Result.is_error
          (Nixploy.Deployment_intent.validate_application expected_intent
             other_managed));
      clear_scenario ();
      Caml_unix.putenv "NIXPLOY_TEST_PRODUCTION" "1";
      let%bind production_direct =
        deploy ~managed_applications:[ production_managed ]
          "operation-production-direct"
      in
      ignore (assert_ok production_direct : Nixploy.Deployment.t);
      let lines = In_channel.read_lines trace in
      [%test_eq: int] 1 (count lines "nix|eval|");
      [%test_eq: int] 1 (count lines "nix|build|");
      assert (List.exists lines ~f:(String.is_prefix ~prefix:"podman|"));

      clear_scenario ();
      Caml_unix.putenv "NIXPLOY_TEST_WEB" "1";
      let%bind intent_mismatch =
        deploy ~expected_intent ~managed_application:managed
          "operation-intent-mismatch"
      in
      expect_error_containing intent_mismatch
        "deployment preview intent no longer matches";
      let lines = In_channel.read_lines trace in
      [%test_eq: int] 1 (count lines "nix|eval|");
      [%test_eq: int] 0 (count lines "nix|build|");
      assert (
        List.for_all lines ~f:(Fn.non (String.is_prefix ~prefix:"podman|")));
      assert (List.for_all lines ~f:(Fn.non (String.is_prefix ~prefix:"ssh|")));

      let wrong_project =
        Nixploy.Project_name.of_string "another-project" |> assert_ok
      in
      clear_scenario ();
      let%bind project_mismatch =
        deploy ~expected_project:wrong_project "operation-project-mismatch"
      in
      expect_error_containing project_mismatch "managed project mismatch";
      let lines = In_channel.read_lines trace in
      [%test_eq: int] 1 (count lines "nix|eval|");
      [%test_eq: int] 0 (count lines "nix|build|");
      assert (
        List.for_all lines ~f:(Fn.non (String.is_prefix ~prefix:"podman|")));
      assert (List.for_all lines ~f:(Fn.non (String.is_prefix ~prefix:"ssh|")));

      clear_scenario ();
      let%bind marked_present =
        Nixploy.Store.set_resource_state application_store
          ~working_directory:repository ~target Present
      in
      assert_ok marked_present;
      let%bind rejected_application =
        Nixploy.Application.deploy_non_production
          ~expected_project:wrong_project application
          ~working_directory:repository
          ~source:(Nixploy.Application.immutable_source application_commit)
          ~target ()
      in
      expect_error_containing rejected_application "managed project mismatch";
      let%bind rejected_history =
        Nixploy.Store.list_for_scope application_store
          ~working_directory:repository ~target ~limit:10
      in
      [%test_eq: int] 0 (List.length (assert_ok rejected_history));
      let%bind rejected_state =
        Nixploy.Application.resource_state application
          ~working_directory:repository ~target
      in
      assert (
        [%equal: Nixploy.Application.resource_state] (assert_ok rejected_state)
          Present);
      let lines = In_channel.read_lines trace in
      [%test_eq: int] 0 (count lines "nix|build|");
      assert (
        List.for_all lines ~f:(Fn.non (String.is_prefix ~prefix:"podman|")));
      assert (List.for_all lines ~f:(Fn.non (String.is_prefix ~prefix:"ssh|")));

      clear_scenario ();
      Caml_unix.putenv "NIXPLOY_TEST_BINDS" "1";
      Caml_unix.putenv "NIXPLOY_TEST_MISSING_BIND" "1";
      let%bind missing_bind = deploy "operation-missing-bind" in
      expect_error_containing missing_bind
        "read-only bind source /srv/reference data is missing or inaccessible";
      let lines = In_channel.read_lines trace in
      [%test_eq: int] 1 (count lines "'test' '-e' '/srv/reference data'");
      [%test_eq: int] 0 (count lines "nix|build|");
      [%test_eq: int] 0 (count lines "|run|--rm|");
      [%test_eq: int] 0 (count lines "|run|-d|--name|");

      clear_scenario ();
      Caml_unix.putenv "NIXPLOY_TEST_BINDS" "1";
      let%bind mounted = deploy "operation-mounted" in
      ignore (assert_ok mounted : Nixploy.Deployment.t);
      let lines = In_channel.read_lines trace in
      let source_preflight =
        index_of lines
          (String.is_substring ~substring:"'test' '-e' '/srv/reference data'")
      in
      let build = index_of lines (String.is_prefix ~prefix:"nix|build|") in
      assert (source_preflight < build);
      let container_runs =
        List.filter lines ~f:(fun line ->
            String.is_substring line ~substring:"|run|--rm|"
            || String.is_substring line ~substring:"|run|-d|--name|")
      in
      [%test_eq: int] 3 (List.length container_runs);
      let expected_mount =
        "|--mount|type=bind,source=/srv/reference \
         data,destination=/app/reference data,ro=true|"
      in
      List.iter container_runs ~f:(fun line ->
          assert (String.is_substring line ~substring:expected_mount);
          assert (not (String.is_substring line ~substring:"ro=false")));

      clear_scenario ();
      Caml_unix.putenv "NIXPLOY_REVISION"
        "ffffffffffffffffffffffffffffffffffffffff";
      let record_stage _stage _message = Deferred.Or_error.return () in
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
            "podman|--connection|%s|run|--rm|--network|private|-e|PORT={port}|-e|MODE=worker|-e|RELEASE_REVISION=%s|loaded@sha256:immutable|/app/migrate"
            expected_name expected_revision;
          sprintf
            "podman|--connection|%s|run|--rm|--network|private|-e|PORT={port}|-e|MODE=worker|-e|RELEASE_REVISION=%s|loaded@sha256:immutable|/app/seed"
            expected_name expected_revision;
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
        (sprintf "podman|--connection|%s|rm|-f|single-id" expected_name)
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
          "|-e|RELEASE_REVISION=" ^ expected_revision ^ "|";
          "|-p|127.0.0.1:9000:9000|";
          "|--label|io.nixploy.managed=true|";
          "|--label|io.nixploy.project=sample|";
          "|--label|io.nixploy.target=worker|";
          "|--label|io.nixploy.resource_key=" ^ expected_name ^ "|";
          "|--label|io.nixploy.repository_identity=git@example.invalid:test.git|";
          "|--label|io.nixploy.revision=" ^ expected_revision ^ "|";
          "|--label|io.nixploy.operation_id="
          ^ Nixploy.Deployment.operation_id deployed
          ^ "|";
          "|loaded@sha256:immutable|/app/worker|--once";
        ]
        ~f:(fun substring ->
          assert (String.is_substring runtime_line ~substring));
      assert (
        not (String.is_substring runtime_line ~substring:"|--label|nixploy."));
      List.iter (pre_starts @ [ runtime_line ]) ~f:(fun line ->
          assert (not (String.is_substring line ~substring:"{revision}"));
          assert (
            not
              (String.is_substring line
                 ~substring:"ffffffffffffffffffffffffffffffffffffffff")));
      let secret_directory = Filename.concat repository "config" in
      Core_unix.mkdir secret_directory;
      write (Filename.concat secret_directory "secrets.env") "encrypted\n";
      let%bind _ =
        run_git ~working_directory:repository
          [ "add"; "-N"; "--"; "config/secrets.env" ]
      in
      clear_scenario ();
      Caml_unix.putenv "NIXPLOY_TEST_SECRETS" "1";
      Caml_unix.putenv "NIXPLOY_TEST_EXPECTED_SECRET" "config/secrets.env";
      let%bind local_source =
        Nixploy.Source.local ~working_directory:repository
      in
      let local_source = assert_ok local_source in
      let%bind local_deployment =
        deploy_source "operation-local" local_source
      in
      ignore (assert_ok local_deployment : Nixploy.Deployment.t);
      let lines = In_channel.read_lines trace in
      assert (
        List.exists lines
          ~f:
            (String.equal
               "nix|eval|--json|--no-update-lock-file|--no-write-lock-file|.#nixploy"));
      assert (
        List.exists lines ~f:(String.is_substring ~substring:"|.#workerImage|"));
      assert (
        List.find_exn lines ~f:(String.is_prefix ~prefix:"sops|")
        |> String.is_suffix ~suffix:"/config/secrets.env");
      let runtime =
        List.find_exn lines
          ~f:(String.is_substring ~substring:"|run|-d|--name|")
      in
      assert (
        String.is_suffix runtime ~suffix:"|loaded@sha256:immutable|/app/worker|");

      let age_identity = Filename.concat root "age-identity" in
      let ssh_identity = Filename.concat root "sops-ssh-identity" in
      write age_identity "AGE-SECRET-KEY-INHERITED\n";
      write ssh_identity "PRIVATE SSH IDENTITY\n";
      List.iter [ age_identity; ssh_identity ] ~f:(fun path ->
          Core_unix.chmod path ~perm:0o600);
      clear_scenario ();
      Caml_unix.putenv "NIXPLOY_TEST_SECRETS" "1";
      Caml_unix.putenv "NIXPLOY_TEST_EXPECTED_SECRET" "config/secrets.env";
      Caml_unix.putenv "SOPS_AGE_KEY_FILE" age_identity;
      Caml_unix.putenv "NIXPLOY_SOPS_AGE_SSH_PRIVATE_KEY_FILE" ssh_identity;
      let%bind credential_deployment =
        deploy_source "operation-private-identities" local_source
      in
      ignore (assert_ok credential_deployment : Nixploy.Deployment.t);
      let lines = In_channel.read_lines trace in
      let ssh_to_age =
        index_of lines (String.is_prefix ~prefix:"ssh-to-age|")
      in
      let sops = index_of lines (String.is_prefix ~prefix:"sops|") in
      assert (ssh_to_age < sops);

      clear_scenario ();
      Core_unix.chmod age_identity ~perm:0o640;
      Caml_unix.putenv "NIXPLOY_TEST_SECRETS" "1";
      Caml_unix.putenv "SOPS_AGE_KEY_FILE" age_identity;
      Caml_unix.putenv "NIXPLOY_SOPS_AGE_SSH_PRIVATE_KEY_FILE" ssh_identity;
      let%bind insecure_age =
        deploy_source "operation-insecure-age" local_source
      in
      expect_error_containing insecure_age "group or other permissions";
      let lines = In_channel.read_lines trace in
      [%test_eq: int] 0 (count lines "ssh-to-age|");
      [%test_eq: int] 0 (count lines "sops|");

      clear_scenario ();
      Core_unix.chmod age_identity ~perm:0o600;
      Core_unix.chmod ssh_identity ~perm:0o604;
      Caml_unix.putenv "NIXPLOY_TEST_SECRETS" "1";
      Caml_unix.putenv "SOPS_AGE_KEY_FILE" age_identity;
      Caml_unix.putenv "NIXPLOY_SOPS_AGE_SSH_PRIVATE_KEY_FILE" ssh_identity;
      let%bind insecure_ssh =
        deploy_source "operation-insecure-ssh" local_source
      in
      expect_error_containing insecure_ssh "group or other permissions";
      let lines = In_channel.read_lines trace in
      [%test_eq: int] 0 (count lines "ssh-to-age|");
      [%test_eq: int] 0 (count lines "sops|");

      clear_scenario ();
      Caml_unix.putenv "NIXPLOY_TEST_SECRETS" "1";
      Caml_unix.putenv "NIXPLOY_TEST_SECRET_PATH" "../outside.env";
      let%bind traversal =
        deploy_source "operation-secret-traversal" local_source
      in
      expect_error_containing traversal "relative secret path";
      [%test_eq: int] 0
        (In_channel.read_lines trace
        |> List.count ~f:(String.is_prefix ~prefix:"sops|"));

      let outside_secret = Filename.concat root "outside.env" in
      write outside_secret "encrypted\n";
      let escaping_link = Filename.concat secret_directory "escape.env" in
      Caml_unix.symlink outside_secret escaping_link;
      let%bind _ =
        run_git ~working_directory:repository
          [ "add"; "-N"; "--"; "config/escape.env" ]
      in
      clear_scenario ();
      Caml_unix.putenv "NIXPLOY_TEST_SECRETS" "1";
      Caml_unix.putenv "NIXPLOY_TEST_SECRET_PATH" "config/escape.env";
      let%bind symlink_escape =
        deploy_source "operation-secret-symlink" local_source
      in
      expect_error_containing symlink_escape "relative secret path";
      [%test_eq: int] 0
        (In_channel.read_lines trace
        |> List.count ~f:(String.is_prefix ~prefix:"sops|"));

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
      Caml_unix.putenv "NIXPLOY_TEST_FAIL_PRESTART" "1";
      let%bind () = expect_application_failure_leaves_unknown () in

      clear_scenario ();
      Caml_unix.putenv "NIXPLOY_TEST_UNOWNED" "1";
      let%bind unowned = deploy "operation-unowned" in
      expect_error unowned;
      let lines = In_channel.read_lines trace in
      assert (count lines "|inspect|--type|container|" = 1);
      assert (count lines "|rm|-f|" = 0);
      assert (count lines "|run|-d|--name|" = 0);

      let%bind () =
        Deferred.List.iter [ "legacy"; "mixed"; "partial"; "wrong-resource" ]
          ~how:`Sequential ~f:(fun mode ->
            clear_scenario ();
            Caml_unix.putenv "NIXPLOY_TEST_WEB" "1";
            Caml_unix.putenv "NIXPLOY_TEST_EXISTING_WEB" "1";
            Caml_unix.putenv "NIXPLOY_TEST_LABEL_MODE" mode;
            write route_state "8080\nworker.example.invalid\n";
            let%map rejected = deploy ("operation-active-" ^ mode) in
            expect_error_containing rejected "not owned by this repository";
            let lines = In_channel.read_lines trace in
            assert (count lines "nix|build|" = 0);
            assert (count lines "|rm|-f|" = 0);
            assert (count lines "|run|-d|--name|" = 0))
      in

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
          ~substring:"|rm|-f|single-id");
      assert (
        String.is_substring (List.nth_exn removals 1)
          ~substring:"|rm|-f|candidate-id");
      clear_scenario ();
      Caml_unix.putenv "NIXPLOY_TEST_VERIFY_MISMATCH" "1";
      let%bind () = expect_application_failure_leaves_unknown () in

      clear_scenario ();
      Caml_unix.putenv "NIXPLOY_TEST_WEB" "1";
      Caml_unix.putenv "NIXPLOY_TEST_EXISTING_SINGLE" "1";
      Caml_unix.putenv "NIXPLOY_REVISION"
        "ffffffffffffffffffffffffffffffffffffffff";
      let%bind transitioned = deploy "operation-single-transition" in
      let transitioned = assert_ok transitioned in
      assert (Option.is_none (Nixploy.Deployment.warning transitioned));
      let lines = In_channel.read_lines trace in
      let web_pre_starts =
        List.filter lines ~f:(String.is_substring ~substring:"|run|--rm|")
      in
      [%test_eq: int] 2 (List.length web_pre_starts);
      let web_runtime =
        List.find_exn lines
          ~f:(String.is_substring ~substring:"|run|-d|--name|")
      in
      List.iter (web_pre_starts @ [ web_runtime ]) ~f:(fun line ->
          List.iter
            [
              "|-e|PORT=8080|";
              "|-e|RELEASE_REVISION=" ^ expected_revision ^ "|";
              "|-e|RELEASE_BINDING=" ^ expected_revision ^ ":8080|";
            ]
            ~f:(fun expected ->
              assert (String.is_substring line ~substring:expected));
          List.iter
            [
              "{revision}"; "{port}"; "ffffffffffffffffffffffffffffffffffffffff";
            ] ~f:(fun forbidden ->
              assert (not (String.is_substring line ~substring:forbidden))));
      let single_inspect =
        index_of lines (fun line ->
            String.is_suffix line
              ~suffix:("|inspect|--type|container|" ^ expected_name))
      in
      let build =
        index_of lines (String.is_substring ~substring:"nix|build|")
      in
      let switch =
        index_of lines (String.is_substring ~substring:"'-X' 'POST'")
      in
      let single_retirement =
        index_of lines (String.is_suffix ~suffix:"|rm|-f|single-id")
      in
      assert (single_inspect < build && switch < single_retirement);
      assert (
        List.for_all lines
          ~f:(Fn.non (String.is_substring ~substring:"unrelated-resource")));
      assert (
        List.for_all lines
          ~f:(Fn.non (String.is_suffix ~suffix:("|rm|-f|" ^ expected_name))));

      clear_scenario ();
      Caml_unix.putenv "NIXPLOY_TEST_WEB" "1";
      Caml_unix.putenv "NIXPLOY_TEST_FOREIGN_SINGLE" "1";
      let%bind foreign_single = deploy "operation-foreign-single" in
      expect_error_containing foreign_single "not owned by this repository";
      let lines = In_channel.read_lines trace in
      [%test_eq: int] 0 (count lines "nix|build|");
      [%test_eq: int] 0 (count lines "|rm|-f|");
      [%test_eq: int] 0 (count lines "|run|-d|--name|");
      assert (
        List.for_all lines
          ~f:(Fn.non (String.is_substring ~substring:"unrelated-resource")));

      clear_scenario ();
      Caml_unix.putenv "NIXPLOY_TEST_WEB" "1";
      Caml_unix.putenv "NIXPLOY_TEST_EXISTING_WEB" "1";
      Caml_unix.putenv "NIXPLOY_TEST_EXISTING_SINGLE" "1";
      Caml_unix.putenv "NIXPLOY_TEST_FAIL_RETIREMENT" "old-slot-id";
      write route_state "8080\nworker.example.invalid\n";
      let%bind warned = deploy "operation-retirement-warning" in
      let warned = assert_ok warned in
      let warning = Nixploy.Deployment.warning warned |> Option.value_exn in
      assert (String.length warning <= 4096);
      assert (String.is_substring warning ~substring:"retirement failed");
      let lines = In_channel.read_lines trace in
      let failed_retirement =
        index_of lines (String.is_suffix ~suffix:"|rm|-f|old-slot-id")
      in
      let attempted_single =
        index_of lines (String.is_suffix ~suffix:"|rm|-f|single-id")
      in
      assert (failed_retirement < attempted_single);

      clear_scenario ();
      Caml_unix.putenv "NIXPLOY_TEST_WEB" "1";
      Caml_unix.putenv "NIXPLOY_TEST_EXISTING_WEB" "1";
      write route_state "8080\nretired.example.invalid\n";
      let%bind updated_domain = deploy "operation-domain-update" in
      ignore (assert_ok updated_domain : Nixploy.Deployment.t);
      let lines = In_channel.read_lines trace in
      let route_read =
        index_of lines (String.is_substring ~substring:"'-X' 'GET'")
      in
      let route_update =
        index_of lines (String.is_substring ~substring:"'-X' 'PATCH'")
      in
      assert (route_read < route_update);
      [%test_eq: string list]
        [ "8081"; "worker.example.invalid" ]
        (In_channel.read_lines route_state);

      Deferred.unit)

let () =
  don't_wait_for
    ( Monitor.try_with run_tests >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1 );
  never_returns (Scheduler.go ())
