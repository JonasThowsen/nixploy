open Async
open Core

let value_or_dash = Option.value ~default:"-"

let print_deployment_stage stage message =
  printf "[%s] %s\n%!" (Nixploy.Deployment.stage_name stage) message;
  Deferred.unit

let exit_after_signal ~default =
  match Nixploy.Process_runner.termination_signal () with
  | None -> default ()
  | Some signal ->
      Shutdown.shutdown_with_signal_exn signal;
      Deferred.never ()

let print_status status =
  let module Target = Nixploy.Configuration.Target in
  printf "Project:  %s\n"
    (Nixploy.Project_name.to_string (Nixploy.Status.project status));
  printf "Target:   %s\n"
    (Nixploy.Target_name.to_string (Target.name (Nixploy.Status.target status)));
  printf "Host:     %s@%s:%d\n"
    (Target.user (Nixploy.Status.target status))
    (Target.host (Nixploy.Status.target status))
    (Target.port (Nixploy.Status.target status));
  printf "Resource: %s\n"
    (Nixploy.Resource_key.to_string (Nixploy.Status.resource_key status));
  match Nixploy.Status.workloads status with
  | [] -> printf "\nNo deployed containers found.\n"
  | workloads ->
      printf "\n%-36s %-12s %-18s %s\n" "CONTAINER" "STATE" "REVISION" "IMAGE";
      List.iter workloads ~f:(fun workload ->
          printf "%-36s %-12s %-18s %s\n"
            (Nixploy.Workload.name workload)
            (Nixploy.Workload.state workload |> value_or_dash)
            (Nixploy.Workload.revision workload
            |> Option.map ~f:(fun revision ->
                String.prefix revision (Int.min 16 (String.length revision)))
            |> value_or_dash)
            (Nixploy.Workload.image workload |> value_or_dash))

let status_command =
  Async.Command.async ~summary:"Inspect containers managed for one flake target"
    (let%map_open.Command target =
       flag "--target" (required string) ~aliases:[ "-t" ]
         ~doc:"TARGET target declared by .#nixploy"
     and working_directory =
       flag "--directory"
         (optional_with_default "." string)
         ~aliases:[ "-C" ] ~doc:"DIRECTORY project flake directory"
     in
     fun () ->
       let open Deferred.Let_syntax in
       match Nixploy.Target_name.of_string target with
       | Error error ->
           eprintf "%s\n" (Error.to_string_hum error);
           Shutdown.exit 2
       | Ok target -> (
           let%bind result = Nixploy.Status.load ~working_directory ~target in
           match result with
           | Ok status ->
               print_status status;
               Deferred.unit
           | Error error ->
               eprintf "Status failed: %s\n" (Error.to_string_hum error);
               Shutdown.exit 1))

let deploy_command =
  Async.Command.async
    ~summary:"Deploy the exact head of main to one flake target"
    (let%map_open.Command target =
       flag "--target" (required string) ~aliases:[ "-t" ]
         ~doc:"TARGET target declared by .#nixploy"
     and working_directory =
       flag "--directory"
         (optional_with_default "." string)
         ~aliases:[ "-C" ] ~doc:"DIRECTORY project Git repository"
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
           let%bind opened = Nixploy.Store.open_ ~path:state_db in
           match opened with
           | Error error ->
               eprintf "Could not open control-plane state: %s\n"
                 (Error.to_string_hum error);
               Shutdown.exit 1
           | Ok store -> (
               let%bind preview =
                 Nixploy.Source.preview_main ~working_directory
               in
               match preview with
               | Error error ->
                   eprintf "Could not resolve main: %s\n"
                     (Error.to_string_hum error);
                   Shutdown.exit 1
               | Ok commit -> (
                   printf "Deploying %s  %s\n%!"
                     (Nixploy.Source.commit_revision commit)
                     (Nixploy.Source.commit_subject commit);
                   let%bind result =
                     Nixploy.Tracked_deployment.deploy
                       ~on_stage:print_deployment_stage ~store
                       ~working_directory ~commit ~target ()
                   in
                   match result with
                   | Error error ->
                       eprintf "Deployment tracking failed: %s\n"
                         (Error.to_string_hum error);
                       Shutdown.exit 1
                   | Ok deployment -> (
                       printf "\nDeployment %s: %s\n"
                         (Nixploy.Store.id deployment)
                         (Nixploy.Store.state deployment
                         |> Nixploy.Store.state_name);
                       Option.iter (Nixploy.Store.revision deployment)
                         ~f:(fun revision -> printf "Revision: %s\n" revision);
                       Option.iter (Nixploy.Store.container_name deployment)
                         ~f:(fun container ->
                           printf "Container: %s\n" container);
                       match Nixploy.Store.state deployment with
                       | Succeeded ->
                           exit_after_signal ~default:(fun () -> Deferred.unit)
                       | Failed ->
                           Option.iter (Nixploy.Store.error deployment)
                             ~f:(fun error -> eprintf "%s\n" error);
                           exit_after_signal ~default:(fun () ->
                               Shutdown.exit 1)
                       | Cancelled ->
                           exit_after_signal ~default:(fun () ->
                               Shutdown.exit 130)
                       | Requested | Running ->
                           eprintf
                             "Deployment ended without a terminal state.\n";
                           Shutdown.exit 1)))))

let command =
  Command.group ~summary:"Deploy and inspect Nix-built applications"
    [ ("deploy", deploy_command); ("status", status_command) ]

let () = Command_unix.run ~version:"0.1.0-ocaml" command
