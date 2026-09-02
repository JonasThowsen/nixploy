open Async
open Core
module Control_plane_client = Nixploy_control_plane_client.Control_plane_client
module Control_plane_output = Nixploy_cli_mapping.Control_plane_output
module Deployment_observer = Nixploy_cli_mapping.Deployment_observer
module Inspection_output = Nixploy_cli_mapping.Inspection_output

let print_status status = printf "%s%!" (Inspection_output.status status)

type execution_mode =
  | Managed of Nixploy.Configuration.Control_plane.t
  | Direct

let execution_mode ~working_directory ~target =
  let open Deferred.Or_error.Let_syntax in
  let%bind configuration = Nixploy.Nix_configuration.load ~working_directory in
  let%bind target_configuration =
    Deferred.return (Nixploy.Configuration.find_target configuration target)
  in
  match Nixploy.Configuration.control_plane configuration with
  | Some control_plane -> Deferred.Or_error.return (Managed control_plane)
  | None -> (
      match
        Nixploy.Configuration.Target.non_production target_configuration
      with
      | Some _ -> Deferred.Or_error.return Direct
      | None ->
          Deferred.Or_error.error_string
            "NIXPLOY_DIRECT_MODE_FORBIDDEN: direct mode requires an unmanaged \
             nonProduction target")

let require_execution_mode ~action ~working_directory ~target =
  let open Deferred.Or_error.Let_syntax in
  let%bind mode = execution_mode ~working_directory ~target in
  let result =
    match mode with
    | Managed control_plane ->
        Control_plane_client.require_managed_transport control_plane
    | Direct -> Deferred.Or_error.return ()
  in
  Deferred.map result
    ~f:
      (Result.map_error ~f:(fun error ->
           Error.tag error ~tag:(action ^ " failed")))

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
           let%bind permitted =
             require_execution_mode ~action:"Status" ~working_directory ~target
           in
           match permitted with
           | Error error ->
               eprintf "%s\n" (Error.to_string_hum error);
               Shutdown.exit 1
           | Ok () -> (
               let%bind opened =
                 Nixploy.Application.open_ ~state_path:state_db ()
               in
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
                           eprintf "Status failed: %s\n"
                             (Error.to_string_hum error);
                           Shutdown.exit 1)))))

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
       Nixploy.Process_runner.handle_termination_signals ();
       match Nixploy.Target_name.of_string target with
       | Error error ->
           eprintf "%s\n" (Error.to_string_hum error);
           Shutdown.exit 2
       | Ok target -> (
           eprintf
             "Preparing local source snapshot and evaluating target %s...\n%!"
             (Nixploy.Target_name.to_string target);
           let%bind permitted =
             require_execution_mode ~action:"Deploy" ~working_directory ~target
           in
           match permitted with
           | Error error ->
               eprintf "%s\n" (Error.to_string_hum error);
               Shutdown.exit 1
           | Ok () -> (
               let%bind opened =
                 Nixploy.Application.open_ ~state_path:state_db ()
               in
               match opened with
               | Error error ->
                   eprintf "Could not open deployment state: %s\n"
                     (Error.to_string_hum error);
                   Shutdown.exit 1
               | Ok application -> (
                   let%bind started =
                     Nixploy.Application.start_local_deployment application
                       ~working_directory ~target
                   in
                   match started with
                   | Error error ->
                       eprintf "Deploy failed: %s\n" (Error.to_string_hum error);
                       Shutdown.exit 1
                   | Ok started -> (
                       match
                         Nixploy.Application.local_scope ~working_directory
                           ~target
                       with
                       | Error error ->
                           eprintf "Deploy failed: %s\n"
                             (Error.to_string_hum error);
                           Shutdown.exit 1
                       | Ok scope -> (
                           let%bind observed =
                             Deployment_observer.observe_and_drain application
                               ~scope started
                               ~render_stage:(fun stage message ->
                                 eprintf "%s: %s\n%!" stage message)
                           in
                           match observed with
                           | Error error ->
                               eprintf "Deploy failed: %s\n"
                                 (Error.to_string_hum error);
                               Shutdown.exit 1
                           | Ok (Deployment_observer.Interrupted signal) ->
                               eprintf "Deploy interrupted by %s\n"
                                 (Signal.to_string signal);
                               Shutdown.exit 130
                           | Ok (Deployment_observer.Completed deployment) -> (
                               match
                                 Nixploy.Application.deployment_state deployment
                               with
                               | Nixploy.Application.Succeeded ->
                                   printf "Deployment %s succeeded\n%!"
                                     (Nixploy.Application.deployment_id
                                        deployment);
                                   Deferred.unit
                               | Nixploy.Application.Requested
                               | Nixploy.Application.Running
                               | Nixploy.Application.Failed
                               | Nixploy.Application.Cancelled ->
                                   eprintf "Deploy failed at %s: %s\n"
                                     (Nixploy.Application.deployment_stage
                                        deployment)
                                     (Nixploy.Application.deployment_message
                                        deployment);
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
           let%bind permitted =
             require_execution_mode ~action:"History" ~working_directory ~target
           in
           match permitted with
           | Error error ->
               eprintf "%s\n" (Error.to_string_hum error);
               Shutdown.exit 1
           | Ok () -> (
               let%bind opened =
                 Nixploy.Application.open_ ~state_path:state_db ()
               in
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
                       eprintf "History failed: %s\n"
                         (Error.to_string_hum error);
                       Shutdown.exit 1
                   | Ok scope -> (
                       let%bind result =
                         Nixploy.Application.deployment_history application
                           ~scope ~limit
                       in
                       match result with
                       | Ok deployments ->
                           print_history deployments;
                           Deferred.unit
                       | Error error ->
                           eprintf "History failed: %s\n"
                             (Error.to_string_hum error);
                           Shutdown.exit 1)))))

let control_plane_capabilities_command =
  Async.Command.async_or_error
    ~summary:"Read one control-plane compatibility contract"
    (let%map_open.Command uri =
       flag "--uri" (required string)
         ~doc:"URI control-plane HTTP or HTTPS authority"
     and required_capabilities =
       flag "--require" (listed string)
         ~doc:"CAPABILITY require one named server capability"
     in
     fun () ->
       let open Deferred.Or_error.Let_syntax in
       let%map capabilities =
         Control_plane_client.request_control_plane_capabilities ~uri
           ~required_capabilities
       in
       printf "%s%!" (Control_plane_output.capabilities capabilities))

let control_plane_command =
  Command.group ~summary:"Inspect a remote nixploy control plane"
    [ ("capabilities", control_plane_capabilities_command) ]

let command =
  Command.group ~summary:"Deploy and manage Nix-built applications"
    [
      ("control-plane", control_plane_command);
      ("deploy", deploy_command);
      ("history", history_command);
      ("prune", prune_command);
      ("status", status_command);
    ]

let () = Command_unix.run ~version:"0.1.0-ocaml" command
