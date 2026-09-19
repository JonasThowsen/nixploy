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
      "Remove owned containers, secrets, images and route, or only stale ones"
    ~readme:(fun () ->
      "Without --stale, removes everything this target owns: containers, fully \
       owned secrets, owned image references and the configured Caddy route. \
       With --stale, removes only what the live deployment does not use: \
       unserved containers, owned secrets no retained container mounts, and \
       owned images beyond the newest --keep. With --orphan KEY, removes one \
       resource key listed by `nixploy resources` whose target this flake no \
       longer declares. Unlabelled secrets, other images, volumes and data are \
       always retained. Pass --dry-run to preview without changing anything, \
       or --yes to remove.")
    (let%map_open.Command flags = common_flags
     and confirmed =
       flag "--yes" no_arg ~doc:" confirm removal without prompting"
     and dry_run =
       flag "--dry-run" no_arg
         ~doc:" show what would be removed; change nothing"
     and stale =
       flag "--stale" no_arg
         ~doc:" remove only resources the live deployment does not use"
     and keep =
       flag "--keep" (optional int)
         ~doc:"COUNT newest owned images to keep with --stale (default 2)"
     and orphan =
       flag "--orphan" (optional string)
         ~doc:
           "RESOURCE_KEY remove another, undeclared target's resources on this \
            host (see `nixploy resources`)"
     in
     fun () ->
       let target, working_directory, state_db, json = flags in
       let mode :
           ( [ `Orphan of string | `Target of Application.prune_mode ],
             string )
           Result.t =
         match (stale, keep, orphan) with
         | true, _, Some _ | false, Some _, Some _ ->
             Error "--orphan cannot be combined with --stale or --keep"
         | false, None, Some key -> Ok (`Orphan key)
         | false, None, None -> Ok (`Target Application.Everything)
         | false, Some _, None -> Error "--keep requires --stale"
         | true, keep, None ->
             let keep = Option.value keep ~default:2 in
             if keep < 1 then Error "--keep must be at least 1"
             else Ok (`Target (Application.Stale { keep }))
       in
       match mode with
       | Error message ->
           eprintf "%s; no resources were changed\n%!" message;
           Shutdown.exit 2
       | Ok _ when confirmed && dry_run ->
           eprintf "pass either --yes or --dry-run, not both\n%!";
           Shutdown.exit 2
       | Ok _ when not (confirmed || dry_run) ->
           eprintf
             "NIXPLOY_PRUNE_CONFIRMATION_REQUIRED: pass --yes, or --dry-run to \
              preview; no resources were changed\n\
              %!";
           Shutdown.exit 2
       | Ok (`Orphan resource_key) ->
           if not dry_run then
             Nixploy.Process_runner.handle_termination_signals ();
           with_application ~target ~state_db (fun application target ->
               let open Deferred.Or_error.Let_syntax in
               let%map result =
                 Application.prune_orphan application ~dry_run
                   ~working_directory ~target ~resource_key ~confirmed
               in
               printf "%s%!"
                 ((if json then Inspection_output.orphan_prune_json
                   else Inspection_output.orphan_prune)
                    result))
       | Ok (`Target mode) ->
           if not dry_run then
             Nixploy.Process_runner.handle_termination_signals ();
           with_application ~target ~state_db (fun application target ->
               let open Deferred.Or_error.Let_syntax in
               let%map result =
                 Application.prune_local application ~mode ~dry_run
                   ~working_directory ~target ~confirmed
               in
               if json then printf "%s%!" (Inspection_output.prune_json result)
               else printf "%s%!" (Inspection_output.prune result);
               if Application.prune_secrets_retained result > 0 then
                 eprintf
                   "Warning: retained %d unlabelled legacy secrets; explicit \
                    ownership migration required.\n\
                    %!"
                   (Application.prune_secrets_retained result)))

let resources_command =
  Async.Command.async
    ~summary:"List every nixploy resource on the target's host"
    ~readme:(fun () ->
      "Groups containers, secrets, images, Caddy routes and mutation markers \
       on the target's host by resource key, and classifies each against this \
       flake: current, declared (another target of this project), orphaned \
       (this project, target no longer declared), other project, or \
       unattributed. Remove orphaned resources with `nixploy prune --orphan \
       KEY`. Read-only; opens no local history.")
    (let%map_open.Command target =
       flag "--target" (required string) ~aliases:[ "-t" ]
         ~doc:"TARGET target declared by .#nixploy whose host is listed"
     and working_directory =
       flag "--directory"
         (optional_with_default "." string)
         ~aliases:[ "-C" ] ~doc:"DIRECTORY project flake directory"
     and json =
       flag "--json" no_arg
         ~doc:" emit structured output; diagnostics remain on stderr"
     in
     fun () ->
       match Nixploy.Target_name.of_string target with
       | Error error ->
           eprintf "%s\n%!" (Error.to_string_hum error);
           Shutdown.exit 2
       | Ok target -> (
           let%bind.Deferred inventory =
             Application.resources ~working_directory ~target
           in
           match inventory with
           | Error error -> fail error
           | Ok inventory ->
               printf "%s%!"
                 ((if json then Inspection_output.resources_json
                   else Inspection_output.resources)
                    inventory);
               Deferred.unit))

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
                   let%bind.Deferred readiness =
                     Application.host_readiness ~working_directory ~target
                   in
                   (match readiness with
                   | Ok readiness ->
                       List.iter (Nixploy.Host_readiness.warnings readiness)
                         ~f:(fun warning ->
                           eprintf "Warning: reboot readiness %s\n%!" warning)
                   | Error error ->
                       eprintf
                         "Warning: could not check reboot readiness: %s\n%!"
                         (Error.to_string_hum error));
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
       ("resources", resources_command);
     ]
    @ Nixploy_runbook_cli.Runbook_commands.commands ~list:Application.runbook
        ~run:Application.run)

let () = Command_unix.run ~version:"0.1.0-ocaml" command
