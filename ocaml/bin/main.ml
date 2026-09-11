open Async
open Core
module Application = Nixploy.Application
module Deployment_observer = Nixploy_cli_mapping.Deployment_observer
module Inspection_output = Nixploy_cli_mapping.Inspection_output

let fail error =
  eprintf "%s\n%!" (Error.to_string_hum error);
  Shutdown.exit 1

let with_application ~target ~state_db action =
  match Nixploy.Target_name.of_string target with
  | Error error ->
      eprintf "%s\n%!" (Error.to_string_hum error);
      Shutdown.exit 2
  | Ok target -> (
      let open Deferred.Let_syntax in
      let%bind result =
        let open Deferred.Or_error.Let_syntax in
        let%bind application = Application.open_ ~state_path:state_db () in
        action application target
      in
      match result with Ok () -> Deferred.unit | Error error -> fail error)

let common_flags =
  let open Command.Let_syntax in
  let%map_open target =
    flag "--target" (required string) ~aliases:[ "-t" ]
      ~doc:"TARGET target declared by .#nixploy"
  and working_directory =
    flag "--directory"
      (optional_with_default "." string)
      ~aliases:[ "-C" ] ~doc:"DIRECTORY project flake directory"
  and state_db =
    flag "--state-db"
      (optional_with_default (Nixploy.State_path.default ()) string)
      ~doc:"PATH local history and uncertainty database"
  and json =
    flag "--json" no_arg
      ~doc:" emit structured output; diagnostics remain on stderr"
  in
  (target, working_directory, state_db, json)

let status_command =
  Async.Command.async ~summary:"Inspect one target"
    (let%map_open.Command flags = common_flags in
     fun () ->
       let target, working_directory, state_db, json = flags in
       with_application ~target ~state_db (fun application target ->
           let open Deferred.Or_error.Let_syntax in
           let%bind scope =
             Deferred.return
               (Application.local_scope ~working_directory ~target)
           in
           let%map status = Application.live_status application ~scope in
           printf "%s%!"
             ((if json then Inspection_output.status_json
               else Inspection_output.status)
                status)))

let history_command =
  Async.Command.async
    ~summary:"List bounded local deployment history (not remote health)"
    (let%map_open.Command flags = common_flags
     and limit =
       flag "--limit"
         (optional_with_default 25 int)
         ~doc:"COUNT recent operations (1-100)"
     in
     fun () ->
       let target, working_directory, state_db, json = flags in
       with_application ~target ~state_db (fun application target ->
           let open Deferred.Or_error.Let_syntax in
           let%map deployments =
             Application.local_history application ~working_directory ~target
               ~limit
           in
           printf "%s%!"
             ((if json then Inspection_output.history_json
               else Inspection_output.history)
                deployments)))

let logs_command =
  Async.Command.async
    ~summary:"Read a bounded snapshot of the owned running container's logs"
    (let%map_open.Command flags = common_flags in
     fun () ->
       let target, working_directory, state_db, json = flags in
       with_application ~target ~state_db (fun application target ->
           let open Deferred.Or_error.Let_syntax in
           let%map logs =
             Application.local_logs application ~working_directory ~target
           in
           if json then printf "%s%!" (Inspection_output.logs_json logs)
           else (
             eprintf "Container: %s%s\n%!" logs.container_name
               (if logs.truncated then " (truncated)" else "");
             List.iter logs.lines ~f:(fun line ->
                 printf "%s%s\n%!"
                   (Option.value_map line.timestamp ~default:""
                      ~f:(fun timestamp -> timestamp ^ " "))
                   line.text))))

let prune_command =
  Async.Command.async
    ~summary:
      "Remove owned containers, secrets and configured route; retain images, \
       volumes and data"
    (let%map_open.Command flags = common_flags
     and confirmed =
       flag "--yes" no_arg ~doc:" confirm removal without prompting"
     in
     fun () ->
       let target, working_directory, state_db, json = flags in
       if not confirmed then (
         eprintf
           "NIXPLOY_PRUNE_CONFIRMATION_REQUIRED: pass --yes; no resources were \
            changed\n\
            %!";
         Shutdown.exit 2)
       else (
         Nixploy.Process_runner.handle_termination_signals ();
         with_application ~target ~state_db (fun application target ->
             let open Deferred.Or_error.Let_syntax in
             let%map result =
               Application.prune_local application ~working_directory ~target
                 ~confirmed
             in
             if json then
               printf
                 "{\"containersRemoved\":%d,\"secretsRemoved\":%d,\"secretsRetained\":%d}\n\
                  %!"
                 (Application.prune_containers_removed result)
                 (Application.prune_secrets_removed result)
                 (Application.prune_secrets_retained result)
             else
               printf
                 "Removed %d owned containers and %d owned secrets; processed \
                  the configured route. Images, volumes and data retained.\n\
                  %!"
                 (Application.prune_containers_removed result)
                 (Application.prune_secrets_removed result);
             if Application.prune_secrets_retained result > 0 then
               eprintf
                 "Warning: retained %d unlabelled legacy secrets; explicit \
                  ownership migration required.\n\
                  %!"
                 (Application.prune_secrets_retained result))))

let deploy_command =
  Async.Command.async
    ~summary:"Deploy one target from a consistent local source snapshot"
    (let%map_open.Command flags = common_flags in
     fun () ->
       let target, working_directory, state_db, json = flags in
       Nixploy.Process_runner.handle_termination_signals ();
       with_application ~target ~state_db (fun application target ->
           let open Deferred.Or_error.Let_syntax in
           eprintf "Preparing local source snapshot...\n%!";
           let%bind scope =
             Deferred.return
               (Application.local_scope ~working_directory ~target)
           in
           let%bind started =
             Application.start_local_deployment application ~working_directory
               ~target
           in
           let%bind observed =
             Deployment_observer.observe_and_drain application ~scope started
               ~render_stage:(fun stage message ->
                 eprintf "%s: %s\n%!" stage message)
           in
           match observed with
           | Deployment_observer.Interrupted signal ->
               eprintf
                 "Deploy interrupted by %s; remote uncertainty evidence may \
                  require reconciliation\n\
                  %!"
                 (Signal.to_string signal);
               Shutdown.exit 130
           | Completed deployment -> (
               if json then
                 printf "%s%!" (Inspection_output.deployment_json deployment);
               match Application.deployment_state deployment with
               | Succeeded ->
                   if not json then
                     printf "Deployment %s succeeded\n%!"
                       (Application.deployment_id deployment);
                   Deferred.Or_error.return ()
               | Requested | Running | Failed | Cancelled ->
                   Deferred.Or_error.errorf "Deploy failed at %s: %s"
                     (Application.deployment_stage deployment)
                     (Application.deployment_message deployment))))

let command =
  Command.group ~summary:"Daemonless deployment and operations over strict SSH"
    ~readme:(fun () ->
      "Exit codes: 0 success; 1 operation or command-parser error; 2 invalid \
       target or missing prune confirmation; 130 deployment interrupted after \
       admission. JSON results use stdout; progress and errors use stderr. \
       Preparation failures produce no result object. History is local \
       evidence, not remote health. Logs are bounded to 500 lines and 64 KiB \
       by the Podman adapter. Failed mutations retain remote uncertainty \
       evidence: never retry or remove it until remote effects have been \
       reconciled.")
    ([
       ("deploy", deploy_command);
       ("status", status_command);
       ("history", history_command);
       ("logs", logs_command);
       ("prune", prune_command);
     ]
    @ Nixploy_runbook_cli.Runbook_commands.commands ~list:Application.runbook
        ~run:Application.run)

let () = Command_unix.run ~version:"0.1.0-ocaml" command
