open Async
open Core

type t = {
  application : Managed_application.t;
  target : Configuration.Target.t;
  connection : string;
  container : Podman.runtime_container;
  caddy : Caddy.t option;
  active_port : int option;
}

let application t = t.application
let target t = t.target
let connection t = t.connection
let container t = t.container
let caddy t = t.caddy
let active_port t = t.active_port

let resolve ?commit ?operation_id application =
  let open Deferred.Or_error.Let_syntax in
  let working_directory = Managed_application.working_directory application in
  let%bind commit =
    match commit with
    | Some commit -> Deferred.Or_error.return commit
    | None -> Source.preview_main ~working_directory
  in
  let%bind source =
    Source.prepare ~working_directory
      ~selection:
        (Source.immutable
           ~repository_identity:
             (Managed_application.repository_identity application)
           commit)
  in
  Monitor.protect
    ~finally:(fun () -> Source.cleanup source)
    (fun () ->
      let open Deferred.Or_error.Let_syntax in
      let%bind configuration =
        Nix_configuration.load ~working_directory:(Source.path source)
      in
      let project = Configuration.project configuration in
      let%bind () =
        if Project_name.equal project (Managed_application.project application)
        then Deferred.Or_error.return ()
        else
          Deferred.Or_error.error_string
            "allowlisted project does not match the flake configuration"
      in
      let%bind target =
        Deferred.return
          (Configuration.find_target configuration
             (Managed_application.target application))
      in
      let repository_identity = Source.repository source in
      let%bind candidates =
        Deferred.return
          (Resource_key.candidates ~project
             ~target:(Managed_application.target application)
             ~repository_identity)
      in
      let%bind resource_key =
        Podman.select_resource_key ~project ~target ~repository_identity
          ~candidates
      in
      let%bind connection = Podman.ensure_connection ~target ~resource_key in
      let%bind container, caddy, active_port =
        match Configuration.Target.kind target with
        | Non_web ->
            let%bind plan =
              Deferred.return
                (Deployment_plan.create ~target_kind:Non_web ~active_port:None)
            in
            let%map container =
              Podman.find_running_placement ~connection ~project ~target
                ~resource_key ~repository_identity
                ~placement:(Deployment_plan.placement plan)
            in
            (container, None, None)
        | Web web ->
            let caddy = Caddy.create ~target ~resource_key ~web in
            let%bind route = Caddy.inspect caddy in
            let%bind active_port =
              match route with
              | Caddy.Missing ->
                  Deferred.Or_error.error_string
                    "application has no positively identified active Caddy \
                     route"
              | Existing { active_port; _ } ->
                  Deferred.Or_error.return active_port
            in
            let%bind plan =
              Deferred.return
                (Deployment_plan.create ~target_kind:(Web web)
                   ~active_port:(Some active_port))
            in
            let%bind active_slot =
              match Deployment_plan.active_slot plan with
              | Some slot -> Deferred.Or_error.return slot
              | None ->
                  Deferred.Or_error.error_string
                    "application has no active slot"
            in
            let%map container =
              Podman.find_running_slot ~connection ~project ~target
                ~resource_key ~repository_identity ~slot:active_slot
            in
            (container, Some caddy, Some active_port)
      in
      if
        Option.equal String.equal
          (Podman.runtime_container_revision container)
          (Some (Source.commit_revision commit))
        && Option.value_map operation_id ~default:true ~f:(fun operation_id ->
            Option.equal String.equal
              (Podman.runtime_container_operation_id container)
              (Some operation_id))
      then
        Deferred.Or_error.return
          { application; target; connection; container; caddy; active_port }
      else
        Deferred.Or_error.error_string
          "active container operation or revision does not match deployment \
           history")
