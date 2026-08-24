open Async
open Core
module Deployment_output = Nixploy_cli_mapping.Deployment_output
module Inspection_output = Nixploy_cli_mapping.Inspection_output
module Deployment_observer = Nixploy_cli_mapping.Deployment_observer

let cancel_and_drain application started =
  let cancellation =
    Nixploy.Application.cancel_started_deployment application started
  in
  let completion = Nixploy.Application.await_started_deployment started in
  let%map _ = cancellation and completion = completion in
  completion

let exit_after_signal ~default =
  match Nixploy.Process_runner.termination_signal () with
  | None -> default ()
  | Some signal ->
      Shutdown.shutdown_with_signal_exn signal;
      Deferred.never ()

let print_status status = printf "%s%!" (Inspection_output.status status)

let status_command =
  Async.Command.async ~summary:"Inspect containers managed for one flake target"
    (let%map_open.Command target =
       flag "--target" (required string) ~aliases:[ "-t" ]
         ~doc:"TARGET target declared by .#nixploy"
     and working_directory =
       flag "--directory"
         (optional_with_default "." string)
         ~aliases:[ "-C" ] ~doc:"DIRECTORY project flake directory"
     and state_db =
       flag "--state-db"
         (optional_with_default (Nixploy.State_path.default ()) string)
         ~doc:"PATH durable control-plane state database"
     in
     fun () ->
       let open Deferred.Let_syntax in
       match Nixploy.Target_name.of_string target with
       | Error error ->
           eprintf "%s\n" (Error.to_string_hum error);
           Shutdown.exit 2
       | Ok target -> (
           let%bind opened = Nixploy.Application.open_ ~state_path:state_db in
           match opened with
           | Error error ->
               eprintf "Could not open control-plane state: %s\n"
                 (Error.to_string_hum error);
               Shutdown.exit 1
           | Ok application -> (
               match
                 Nixploy.Application.local_scope ~working_directory ~target
               with
               | Error error ->
                   eprintf "Status failed: %s\n" (Error.to_string_hum error);
                   Shutdown.exit 1
               | Ok scope -> (
                   let%bind result =
                     Nixploy.Application.live_status application ~scope
                   in
                   match result with
                   | Ok status ->
                       print_status status;
                       Deferred.unit
                   | Error error ->
                       eprintf "Status failed: %s\n" (Error.to_string_hum error);
                       Shutdown.exit 1))))

let print_prune_result result =
  printf "Project:    %s\n"
    (Nixploy.Application.prune_project result |> Nixploy.Project_name.to_string);
  printf "Target:     %s\n"
    (Nixploy.Application.prune_target result |> Nixploy.Target_name.to_string);
  printf "Resource:   %s\n"
    (Nixploy.Application.prune_resource_key result
    |> Nixploy.Resource_key.to_string);
  printf "Containers: %d removed\n"
    (Nixploy.Application.prune_containers_removed result);
  printf "Secrets:    %d removed\n"
    (Nixploy.Application.prune_secrets_removed result);
  printf "Caddy route: %s\n"
    (match Nixploy.Application.prune_route_state result with
    | Not_configured -> "not configured"
    | Missing -> "already absent"
    | Removed -> "removed")

let prune_command =
  Async.Command.async ~summary:"Remove resources owned by one flake target"
    (let%map_open.Command target =
       flag "--target" (required string) ~aliases:[ "-t" ]
         ~doc:"TARGET target declared by .#nixploy"
     and working_directory =
       flag "--directory"
         (optional_with_default "." string)
         ~aliases:[ "-C" ] ~doc:"DIRECTORY project flake directory"
     and state_db =
       flag "--state-db"
         (optional_with_default (Nixploy.State_path.default ()) string)
         ~doc:"PATH durable control-plane state database"
     in
     fun () ->
       let open Deferred.Let_syntax in
       Nixploy.Process_runner.handle_termination_signals ();
       match Nixploy.Target_name.of_string target with
       | Error error ->
           eprintf "%s\n" (Error.to_string_hum error);
           Shutdown.exit 2
       | Ok target -> (
           let%bind opened = Nixploy.Application.open_ ~state_path:state_db in
           match opened with
           | Error error ->
               eprintf "Could not open control-plane state: %s\n"
                 (Error.to_string_hum error);
               Shutdown.exit 1
           | Ok application -> (
               let%bind result =
                 Nixploy.Application.prune application ~working_directory
                   ~target
               in
               match result with
               | Ok result ->
                   print_prune_result result;
                   exit_after_signal ~default:(fun () -> Deferred.unit)
               | Error error ->
                   eprintf "Prune failed: %s\n" (Error.to_string_hum error);
                   exit_after_signal ~default:(fun () -> Shutdown.exit 1))))

let deploy_command =
  Async.Command.async ~summary:"Deploy the current local flake to one target"
    (let%map_open.Command target =
       flag "--target" (required string) ~aliases:[ "-t" ]
         ~doc:"TARGET target declared by .#nixploy"
     and working_directory =
       flag "--directory"
         (optional_with_default "." string)
         ~aliases:[ "-C" ] ~doc:"DIRECTORY current local project flake"
     and state_db =
       flag "--state-db"
         (optional_with_default (Nixploy.State_path.default ()) string)
         ~doc:"PATH durable control-plane state database"
     in
     fun () ->
       let open Deferred.Let_syntax in
       Nixploy.Process_runner.handle_termination_signals ();
       match Nixploy.Target_name.of_string target with
       | Error error ->
           eprintf "%s\n" (Error.to_string_hum error);
           Shutdown.exit 2
       | Ok target -> (
           let%bind opened = Nixploy.Application.open_ ~state_path:state_db in
           match opened with
           | Error error ->
               eprintf "Could not open control-plane state: %s\n"
                 (Error.to_string_hum error);
               Shutdown.exit 1
           | Ok application -> (
               let%bind selected =
                 Nixploy.Application.local_source application ~working_directory
               in
               match selected with
               | Error error ->
                   eprintf "Could not resolve local source: %s\n"
                     (Error.to_string_hum error);
                   Shutdown.exit 1
               | Ok source -> (
                   printf "Deploying local source at %s  %s\n%!"
                     (Nixploy.Application.source_revision source)
                     (Nixploy.Application.source_subject source);
                   let%bind result =
                     Nixploy.Application.start_deploy application
                       ~working_directory ~source ~target ()
                   in
                   match result with
                   | Error error ->
                       eprintf "Deployment failed to start: %s\n"
                         (Error.to_string_hum error);
                       Shutdown.exit 1
                   | Ok started -> (
                       match
                         Nixploy.Application.local_scope ~working_directory
                           ~target
                       with
                       | Error error ->
                           let%bind _ = cancel_and_drain application started in
                           eprintf "Deployment tracking failed: %s\n"
                             (Error.to_string_hum error);
                           Shutdown.exit 1
                       | Ok scope -> (
                           let%bind observation =
                             Deployment_observer.observe_and_drain
                               ~render_stage:(fun stage message ->
                                 printf "[%s] %s\n%!" stage message)
                               application ~scope started
                           in
                           match observation with
                           | Error error ->
                               eprintf "Deployment tracking failed: %s\n"
                                 (Error.to_string_hum error);
                               Shutdown.exit 1
                           | Ok (Deployment_observer.Interrupted signal) ->
                               Shutdown.shutdown_with_signal_exn signal;
                               Deferred.never ()
                           | Ok (Deployment_observer.Completed deployment) -> (
                               let output =
                                 Deployment_output.of_deployment deployment
                               in
                               printf "\nDeployment %s: %s\n"
                                 (Deployment_output.id output)
                                 (Deployment_output.state_name output);
                               Option.iter (Deployment_output.revision output)
                                 ~f:(fun revision ->
                                   printf "Revision: %s\n" revision);
                               Option.iter
                                 (Deployment_output.container_name output)
                                 ~f:(fun container ->
                                   printf "Container: %s\n" container);
                               match
                                 Deployment_output.terminal_state output
                               with
                               | Succeeded -> Deferred.unit
                               | Failed error ->
                                   Option.iter error ~f:(fun error ->
                                       eprintf "%s\n" error);
                                   Shutdown.exit 1
                               | Cancelled -> Shutdown.exit 130
                               | Incomplete ->
                                   eprintf
                                     "Deployment ended without a terminal state.\n";
                                   Shutdown.exit 1)))))))

let print_history deployments =
  printf "%s%!" (Inspection_output.history deployments)

let history_command =
  Async.Command.async ~summary:"List deployment history for one flake target"
    (let%map_open.Command target =
       flag "--target" (required string) ~aliases:[ "-t" ]
         ~doc:"TARGET target declared by .#nixploy"
     and working_directory =
       flag "--directory"
         (optional_with_default "." string)
         ~aliases:[ "-C" ] ~doc:"DIRECTORY project flake directory"
     and state_db =
       flag "--state-db"
         (optional_with_default (Nixploy.State_path.default ()) string)
         ~doc:"PATH durable control-plane state database"
     and limit =
       flag "--limit"
         (optional_with_default 25 int)
         ~doc:"COUNT number of recent deployments (1-100)"
     in
     fun () ->
       let open Deferred.Let_syntax in
       match Nixploy.Target_name.of_string target with
       | Error error ->
           eprintf "%s\n" (Error.to_string_hum error);
           Shutdown.exit 2
       | Ok target -> (
           let%bind opened = Nixploy.Application.open_ ~state_path:state_db in
           match opened with
           | Error error ->
               eprintf "Could not open control-plane state: %s\n"
                 (Error.to_string_hum error);
               Shutdown.exit 1
           | Ok application -> (
               match
                 Nixploy.Application.local_scope ~working_directory ~target
               with
               | Error error ->
                   eprintf "History failed: %s\n" (Error.to_string_hum error);
                   Shutdown.exit 1
               | Ok scope -> (
                   let%bind result =
                     Nixploy.Application.deployment_history application ~scope
                       ~limit
                   in
                   match result with
                   | Ok deployments ->
                       print_history deployments;
                       Deferred.unit
                   | Error error ->
                       eprintf "History failed: %s\n"
                         (Error.to_string_hum error);
                       Shutdown.exit 1))))

let command =
  Command.group ~summary:"Deploy and manage Nix-built applications"
    [
      ("deploy", deploy_command);
      ("history", history_command);
      ("prune", prune_command);
      ("status", status_command);
    ]

let () = Command_unix.run ~version:"0.1.0-ocaml" command
