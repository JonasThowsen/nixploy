open Async
open Core
module Control_plane_client = Nixploy_control_plane_client.Control_plane_client
module Control_plane_output = Nixploy_cli_mapping.Control_plane_output
module Deployment_observer = Nixploy_cli_mapping.Deployment_observer
module Inspection_output = Nixploy_cli_mapping.Inspection_output

let print_status status = printf "%s%!" (Inspection_output.status status)
let print_history deployments = printf "%s%!" (Inspection_output.history deployments)

type execution_mode =
  | Managed of { authority_alias : string; managed_application_key : string }
  | Direct

let execution_mode ~direct ~authority_alias ~managed_application_key =
  match (direct, authority_alias, managed_application_key) with
  | true, None, None -> Ok Direct
  | true, (Some _), _ | true, _, Some _ ->
      Or_error.error_string
        "NIXPLOY_EXECUTION_MODE_INVALID: --direct cannot be combined with \
         managed authority selection"
  | false, Some authority_alias, Some managed_application_key ->
      Ok (Managed { authority_alias; managed_application_key })
  | false, None, None -> Ok Direct
  | false, _, _ ->
      Or_error.error_string
        "NIXPLOY_MANAGED_SELECTION_INVALID: supply both --authority-alias and \
         --managed-application-key, or neither for a nonProduction target"

let require_managed_transport ~action ~authority_alias ~managed_application_key =
  Deferred.map
    (Control_plane_client.require_managed_transport ~authority_alias
       ~managed_application_key)
    ~f:(Result.map_error ~f:(fun error -> Error.tag error ~tag:(action ^ " failed")))

let require_direct_configuration ~working_directory ~target =
  let open Deferred.Or_error.Let_syntax in
  let%bind configuration = Nixploy.Nix_configuration.load ~working_directory in
  Deferred.return (Nixploy.Direct_mode.validate_configuration configuration ~target)

let open_direct_application ~state_db =
  Nixploy.Application.open_ ~state_path:state_db ()

let direct_status ~working_directory ~target ~state_db =
  let open Deferred.Let_syntax in
  let%bind permitted = require_direct_configuration ~working_directory ~target in
  match permitted with
  | Error error ->
      eprintf "Status failed: %s\n" (Error.to_string_hum error);
      Shutdown.exit 1
  | Ok () ->
      let%bind opened = open_direct_application ~state_db in
  match opened with
  | Error error ->
      eprintf "Could not open control-plane state: %s\n" (Error.to_string_hum error);
      Shutdown.exit 1
  | Ok application -> (
      match Nixploy.Application.local_scope ~working_directory ~target with
      | Error error ->
          eprintf "Status failed: %s\n" (Error.to_string_hum error);
          Shutdown.exit 1
      | Ok scope ->
          let%bind result = Nixploy.Application.live_status application ~scope in
          match result with
          | Ok status ->
              print_status status;
              Deferred.unit
          | Error error ->
              eprintf "Status failed: %s\n" (Error.to_string_hum error);
              Shutdown.exit 1)

let direct_history ~working_directory ~target ~state_db ~limit =
  let open Deferred.Let_syntax in
  let%bind permitted = require_direct_configuration ~working_directory ~target in
  match permitted with
  | Error error ->
      eprintf "History failed: %s\n" (Error.to_string_hum error);
      Shutdown.exit 1
  | Ok () ->
      let%bind opened = open_direct_application ~state_db in
  match opened with
  | Error error ->
      eprintf "Could not open control-plane state: %s\n" (Error.to_string_hum error);
      Shutdown.exit 1
  | Ok application -> (
      match Nixploy.Application.local_scope ~working_directory ~target with
      | Error error ->
          eprintf "History failed: %s\n" (Error.to_string_hum error);
          Shutdown.exit 1
      | Ok scope ->
          let%bind result =
            Nixploy.Application.deployment_history application ~scope ~limit
          in
          match result with
          | Ok deployments ->
              print_history deployments;
              Deferred.unit
          | Error error ->
              eprintf "History failed: %s\n" (Error.to_string_hum error);
              Shutdown.exit 1)

let direct_deploy ~working_directory ~target ~state_db =
  let open Deferred.Let_syntax in
  eprintf "Preparing local source snapshot and evaluating target %s...\n%!"
    (Nixploy.Target_name.to_string target);
  Nixploy.Process_runner.handle_termination_signals ();
  let%bind permitted = require_direct_configuration ~working_directory ~target in
  match permitted with
  | Error error ->
      eprintf "Deploy failed: %s\n" (Error.to_string_hum error);
      Shutdown.exit 1
  | Ok () ->
      let%bind opened = open_direct_application ~state_db in
  match opened with
  | Error error ->
      eprintf "Could not open deployment state: %s\n" (Error.to_string_hum error);
      Shutdown.exit 1
  | Ok application ->
      let%bind started =
        Nixploy.Application.start_local_deployment application ~working_directory
          ~target
      in
      match started with
      | Error error ->
          eprintf "Deploy failed: %s\n" (Error.to_string_hum error);
          Shutdown.exit 1
      | Ok started -> (
          match Nixploy.Application.local_scope ~working_directory ~target with
          | Error error ->
              eprintf "Deploy failed: %s\n" (Error.to_string_hum error);
              Shutdown.exit 1
          | Ok scope ->
              let%bind observed =
                Deployment_observer.observe_and_drain application ~scope started
                  ~render_stage:(fun stage message ->
                    eprintf "%s: %s\n%!" stage message)
              in
              match observed with
              | Error error ->
                  eprintf "Deploy failed: %s\n" (Error.to_string_hum error);
                  Shutdown.exit 1
              | Ok (Deployment_observer.Interrupted signal) ->
                  eprintf "Deploy interrupted by %s\n" (Signal.to_string signal);
                  Shutdown.exit 130
              | Ok (Deployment_observer.Completed deployment) -> (
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
                      Shutdown.exit 1))

let mode_flags =
  let open Command.Param in
  let open Command.Let_syntax in
  let%map direct =
    flag "--direct" no_arg
      ~doc:" require local execution for an unmanaged nonProduction target"
  and authority_alias =
    flag "--authority-alias" (optional string)
      ~doc:"ALIAS protected control-plane authority alias for a managed command"
  and managed_application_key =
    flag "--managed-application-key" (optional string)
      ~doc:"KEY managed application key for a managed command"
  in
  (direct, authority_alias, managed_application_key)

let status_command =
  Async.Command.async ~summary:"Inspect one target"
    (let%map_open.Command target =
       flag "--target" (required string) ~aliases:[ "-t" ]
         ~doc:"TARGET target declared by .#nixploy"
     and working_directory =
       flag "--directory" (optional_with_default "." string) ~aliases:[ "-C" ]
         ~doc:"DIRECTORY project flake directory for --direct"
     and state_db =
       flag "--state-db" (optional_with_default (Nixploy.State_path.default ()) string)
         ~doc:"PATH durable local state database for --direct"
     and mode = mode_flags in
     fun () ->
       let direct, authority_alias, managed_application_key = mode in
       match Nixploy.Target_name.of_string target with
       | Error error ->
           eprintf "%s\n" (Error.to_string_hum error);
           Shutdown.exit 2
       | Ok target -> (
           match execution_mode ~direct ~authority_alias ~managed_application_key with
           | Error error ->
               eprintf "Status failed: %s\n" (Error.to_string_hum error);
               Shutdown.exit 1
           | Ok (Managed { authority_alias; managed_application_key }) ->
               let open Deferred.Let_syntax in
               let%bind result =
                 require_managed_transport ~action:"Status" ~authority_alias
                   ~managed_application_key
               in
               (match result with
               | Ok () ->
                   eprintf "Status failed: managed status RPC is unavailable\n";
                   Shutdown.exit 1
               | Error error ->
                   eprintf "%s\n" (Error.to_string_hum error);
                   Shutdown.exit 1)
           | Ok Direct -> direct_status ~working_directory ~target ~state_db))

let prune_command =
  Async.Command.async ~summary:"Remove resources owned for one target"
    (let%map_open.Command target =
       flag "--target" (required string) ~aliases:[ "-t" ]
         ~doc:"TARGET target declared by .#nixploy"
     and working_directory =
       flag "--directory" (optional_with_default "." string) ~aliases:[ "-C" ]
         ~doc:"DIRECTORY project flake directory"
     and state_db =
       flag "--state-db" (optional_with_default (Nixploy.State_path.default ()) string)
         ~doc:"PATH durable control-plane state database"
     in
     fun () ->
       ignore (target, working_directory, state_db);
       eprintf
         "Prune refused: the standalone CLI has no protected mutation authority; \
          use the managed control-plane RPC.\n";
       Shutdown.exit 1)

let deploy_command =
  Async.Command.async ~summary:"Deploy one target"
    (let%map_open.Command target =
       flag "--target" (required string) ~aliases:[ "-t" ]
         ~doc:"TARGET target declared by .#nixploy"
     and working_directory =
       flag "--directory" (optional_with_default "." string) ~aliases:[ "-C" ]
         ~doc:"DIRECTORY current local project flake for --direct"
     and state_db =
       flag "--state-db" (optional_with_default (Nixploy.State_path.default ()) string)
         ~doc:"PATH durable local state database for --direct"
     and mode = mode_flags in
     fun () ->
       let direct, authority_alias, managed_application_key = mode in
       match Nixploy.Target_name.of_string target with
       | Error error ->
           eprintf "%s\n" (Error.to_string_hum error);
           Shutdown.exit 2
       | Ok target -> (
           match execution_mode ~direct ~authority_alias ~managed_application_key with
           | Error error ->
               eprintf "Deploy failed: %s\n" (Error.to_string_hum error);
               Shutdown.exit 1
           | Ok (Managed { authority_alias; managed_application_key }) ->
               let open Deferred.Let_syntax in
               let%bind result =
                 require_managed_transport ~action:"Deploy" ~authority_alias
                   ~managed_application_key
               in
               (match result with
               | Ok () ->
                   eprintf "Deploy failed: managed deploy RPC is unavailable\n";
                   Shutdown.exit 1
               | Error error ->
                   eprintf "%s\n" (Error.to_string_hum error);
                   Shutdown.exit 1)
           | Ok Direct -> direct_deploy ~working_directory ~target ~state_db))

let history_command =
  Async.Command.async ~summary:"List deployment history for one target"
    (let%map_open.Command target =
       flag "--target" (required string) ~aliases:[ "-t" ]
         ~doc:"TARGET target declared by .#nixploy"
     and working_directory =
       flag "--directory" (optional_with_default "." string) ~aliases:[ "-C" ]
         ~doc:"DIRECTORY project flake directory for --direct"
     and state_db =
       flag "--state-db" (optional_with_default (Nixploy.State_path.default ()) string)
         ~doc:"PATH durable local state database for --direct"
     and limit =
       flag "--limit" (optional_with_default 25 int)
         ~doc:"COUNT number of recent deployments (1-100)"
     and mode = mode_flags in
     fun () ->
       let direct, authority_alias, managed_application_key = mode in
       match Nixploy.Target_name.of_string target with
       | Error error ->
           eprintf "%s\n" (Error.to_string_hum error);
           Shutdown.exit 2
       | Ok target -> (
           match execution_mode ~direct ~authority_alias ~managed_application_key with
           | Error error ->
               eprintf "History failed: %s\n" (Error.to_string_hum error);
               Shutdown.exit 1
           | Ok (Managed { authority_alias; managed_application_key }) ->
               let open Deferred.Let_syntax in
               let%bind result =
                 require_managed_transport ~action:"History" ~authority_alias
                   ~managed_application_key
               in
               (match result with
               | Ok () ->
                   eprintf "History failed: managed history RPC is unavailable\n";
                   Shutdown.exit 1
               | Error error ->
                   eprintf "%s\n" (Error.to_string_hum error);
                   Shutdown.exit 1)
           | Ok Direct -> direct_history ~working_directory ~target ~state_db ~limit))

let control_plane_capabilities_command =
  Async.Command.async_or_error ~summary:"Read one control-plane compatibility contract"
    (let%map_open.Command uri =
       flag "--uri" (required string) ~doc:"URI control-plane HTTP or HTTPS authority"
     and required_capabilities =
       flag "--require" (listed string) ~doc:"CAPABILITY require one named server capability"
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
