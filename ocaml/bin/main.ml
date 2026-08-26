open Async
open Core
module Inspection_output = Nixploy_cli_mapping.Inspection_output

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
           let%bind opened = Nixploy.Application.open_ ~state_path:state_db () in
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
       ignore (target, working_directory, state_db);
       eprintf
         "Prune refused: the standalone CLI has no protected mutation \
          authority; use the managed control-plane RPC.\n";
       Shutdown.exit 1)

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
       match Nixploy.Target_name.of_string target with
       | Error error ->
           eprintf "%s\n" (Error.to_string_hum error);
           Shutdown.exit 2
       | Ok target ->
           let%bind opened = Nixploy.Application.open_ ~state_path:state_db () in
           (match opened with
           | Error error ->
               eprintf "Could not open deployment state: %s\n"
                 (Error.to_string_hum error);
               Shutdown.exit 1
           | Ok application ->
               let%bind deployed =
                 Nixploy.Application.deploy_local_deployment application
                   ~working_directory ~target
               in
               match deployed with
                   | Error error ->
                       eprintf "Deploy failed: %s\n" (Error.to_string_hum error);
                       Shutdown.exit 1
                   | Ok deployment -> (
                       match Nixploy.Application.deployment_state deployment with
                       | Nixploy.Application.Succeeded ->
                           printf "Deployment %s succeeded\n%!"
                             (Nixploy.Application.deployment_id deployment);
                           Deferred.unit
                       | Nixploy.Application.Requested
                       | Nixploy.Application.Running
                       | Nixploy.Application.Failed
                       | Nixploy.Application.Cancelled ->
                           eprintf "Deploy failed at %s: %s\n"
                             (Nixploy.Application.deployment_stage deployment)
                             (Nixploy.Application.deployment_message deployment);
                           Shutdown.exit 1)))

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
           let%bind opened = Nixploy.Application.open_ ~state_path:state_db () in
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
