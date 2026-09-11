open Async
open Core

type prepared = {
  project : Project_name.t;
  target : Configuration.Target.t;
  repository_identity : string;
  resource_key : Resource_key.t;
  candidates : Resource_key.t list;
  command : Configuration.Runbook_command.t;
}

type selection = {
  container_id : string;
  container_name : string;
  revision : string option;
}

type outcome = {
  selection : selection;
  exit_code : int;
  uncertainty : string option;
}

let target t = t.target
let project t = t.project
let repository_identity t = t.repository_identity
let resource_key t = t.resource_key

let load_target ~working_directory ~target =
  let open Deferred.Or_error.Let_syntax in
  let%bind configuration = Nix_configuration.load ~working_directory in
  let%bind () =
    Deferred.return (Configuration.require_daemonless configuration)
  in
  let%map selected =
    Deferred.return (Configuration.find_target configuration target)
  in
  (configuration, selected)

let list ~working_directory ~target =
  let open Deferred.Or_error.Let_syntax in
  let%map _, target = load_target ~working_directory ~target in
  Configuration.Target.runbook target

let prepare ~working_directory ~target ~name =
  let open Deferred.Or_error.Let_syntax in
  let%bind configuration, target = load_target ~working_directory ~target in
  let%bind command =
    match
      List.find (Configuration.Target.runbook target) ~f:(fun command ->
          String.equal (Configuration.Runbook_command.name command) name)
    with
    | Some command -> Deferred.Or_error.return command
    | None ->
        Deferred.Or_error.errorf
          "runbook command %s is not declared by the selected target" name
  in
  let project = Configuration.project configuration in
  let%bind repository_identity =
    Source.repository_identity ~working_directory
  in
  let%bind resource_key =
    Deferred.return
      (Resource_key.derive ~project
         ~target:(Configuration.Target.name target)
         ~repository_identity)
  in
  let%map candidates =
    Deferred.return
      (Resource_key.candidates ~project
         ~target:(Configuration.Target.name target)
         ~repository_identity)
  in
  { project; target; repository_identity; resource_key; candidates; command }

let execute ~with_guard ~on_selection prepared =
  let open Deferred.Or_error.Let_syntax in
  Process_runner.handle_termination_signals ();
  let%bind attached = Process_runner.terminal_attached () |> Deferred.ok in
  if Configuration.Runbook_command.interactive prepared.command && not attached
  then
    Deferred.Or_error.error_string
      "runbook interactive command requires attached stdin and stdout terminals"
  else
    with_guard prepared (fun () ->
        let%bind resource_key =
          Podman.select_resource_key ~project:prepared.project
            ~target:prepared.target
            ~repository_identity:prepared.repository_identity
            ~candidates:prepared.candidates
        in
        let%bind runtime =
          Runbook_runtime.resolve_running ~project:prepared.project
            ~target:prepared.target ~resource_key
            ~repository_identity:prepared.repository_identity
        in
        let container = Runbook_runtime.container runtime in
        let selection =
          {
            container_id = Podman.runtime_container_id container;
            container_name = Podman.runtime_container_name container;
            revision = Podman.runtime_container_revision container;
          }
        in
        let%bind () = on_selection selection |> Deferred.ok in
        let%map status =
          Podman.exec_runbook
            ~connection:(Runbook_runtime.connection runtime)
            ~container ~command:prepared.command
        in
        let exit_code, uncertainty =
          match status with
          | Ok () -> (0, None)
          | Error (`Exit_non_zero code) ->
              ( code,
                if code = 125 || code = 255 then
                  Some
                    "runbook exec client failed: remote outcome may be \
                     unknown; do not retry automatically"
                else None )
          | Error (`Signal signal) ->
              ( 128 + Signal_unix.to_system_int signal,
                Some
                  "runbook exec client was interrupted: remote command may \
                   still be running; do not retry automatically" )
        in
        { selection; exit_code; uncertainty })

let run ~with_guard ~on_selection ~working_directory ~target ~name =
  let open Deferred.Or_error.Let_syntax in
  let%bind prepared = prepare ~working_directory ~target ~name in
  execute ~with_guard ~on_selection prepared
