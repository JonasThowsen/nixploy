open Async
open Core

type stage =
  | Preparing_source
  | Evaluating
  | Connecting
  | Building
  | Planning
  | Preparing_candidate
  | Running_pre_start
  | Starting
  | Health_checking
  | Switching
  | Verifying
  | Retiring_previous
  | Succeeded
[@@deriving compare, equal, sexp]

type t = {
  operation_id : string;
  project : Project_name.t;
  target : Target_name.t;
  revision : string;
  image_id : string;
  container_name : string;
  container_id : string;
  placement : Deployment_plan.placement;
  warning : string option;
}

let operation_id t = t.operation_id
let project t = t.project
let target t = t.target
let revision t = t.revision
let image_id t = t.image_id
let container_name t = t.container_name
let container_id t = t.container_id
let placement t = t.placement
let warning t = t.warning

let stage_name = function
  | Preparing_source -> "preparing-source"
  | Evaluating -> "evaluating"
  | Connecting -> "connecting"
  | Building -> "building"
  | Planning -> "planning"
  | Preparing_candidate -> "preparing-candidate"
  | Running_pre_start -> "running-pre-start"
  | Starting -> "starting"
  | Health_checking -> "health-checking"
  | Switching -> "switching"
  | Verifying -> "verifying"
  | Retiring_previous -> "retiring-previous"
  | Succeeded -> "succeeded"

let timestamp () =
  let tm = Caml_unix.gmtime (Caml_unix.time ()) in
  sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (tm.tm_year + 1900) (tm.tm_mon + 1)
    tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec

let no_stage _ _ = Deferred.unit

let combine_failure primary secondary =
  Error.create_s [%message (primary : Error.t) (secondary : Error.t)]

let cleanup_candidate ~connection candidate primary =
  let%map cleanup = Podman.remove_candidate ~connection ~candidate in
  match cleanup with
  | Ok () -> Error primary
  | Error cleanup_error ->
      Cancellation.mark_cleanup_failed ();
      Error (combine_failure primary cleanup_error)

let restore_and_cleanup ~caddy ~previous ~connection ~candidate primary =
  let open Deferred.Let_syntax in
  let%bind restored = Caddy.restore caddy ~previous in
  match restored with
  | Error restoration ->
      Cancellation.mark_cleanup_failed ();
      Deferred.return (Error (combine_failure primary restoration))
  | Ok () ->
      let%map removed = Podman.remove_candidate ~connection ~candidate in
      let error =
        match removed with
        | Ok () -> primary
        | Error cleanup ->
            Cancellation.mark_cleanup_failed ();
            combine_failure primary cleanup
      in
      Error error

let deploy ?(on_stage = no_stage) ~operation_id ~working_directory ~commit
    ~target:target_name () =
  let open Deferred.Let_syntax in
  let%bind () =
    on_stage Preparing_source "Materializing the confirmed Git commit"
  in
  let%bind prepared = Source.prepare ~working_directory ~commit in
  match prepared with
  | Error _ as error -> Deferred.return error
  | Ok source ->
      Monitor.protect
        ~finally:(fun () -> Source.cleanup source)
        (fun () ->
          let open Deferred.Or_error.Let_syntax in
          let%bind () =
            on_stage Evaluating "Evaluating committed flake configuration"
            |> Deferred.map ~f:Or_error.return
          in
          let%bind evaluated =
            Nix_configuration.load_evaluated
              ~working_directory:(Source.path source)
          in
          let configuration = Nix_configuration.configuration evaluated in
          let%bind target =
            Deferred.return
              (Configuration.find_target configuration target_name)
          in
          let project = Configuration.project configuration in
          let%bind canonical_resource_key =
            Deferred.return (Resource_key.derive ~project ~target:target_name)
          in
          let%bind legacy_resource_key =
            Deferred.return
              (Resource_key.derive_legacy ~project ~target:target_name
                 ~repository:(Source.repository source))
          in
          let%bind resource_key =
            Podman.select_resource_key ~project ~target
              ~canonical:canonical_resource_key ~legacy:legacy_resource_key
          in
          let configuration_digest =
            Nix_configuration.json evaluated
            |> Digestif.SHA256.digest_string |> Digestif.SHA256.to_hex
          in
          let%bind () =
            on_stage Connecting "Verifying the canonical Podman connection"
            |> Deferred.map ~f:Or_error.return
          in
          let%bind connection =
            Podman.ensure_connection ~target ~resource_key
          in
          let%bind () =
            on_stage Building "Building and loading the image"
            |> Deferred.map ~f:Or_error.return
          in
          let%bind image =
            Podman.build_and_load ~connection ~source
              ~image_output:(Configuration.Target.image target)
          in
          let%bind secrets = Secrets.load ~target in
          let%bind secret_mounts =
            Podman.install_secrets ~connection ~resource_key ~secrets
          in
          let target_kind = Configuration.Target.kind target in
          let deployment_result ~placement ~candidate ~warning =
            {
              operation_id;
              project;
              target = target_name;
              revision = Source.revision source;
              image_id = Podman.image_id image;
              container_name = Podman.candidate_name candidate;
              container_id = Podman.candidate_id candidate;
              placement;
              warning;
            }
          in
          let verify candidate =
            Podman.verify_candidate ~connection ~project ~target ~resource_key
              ~source ~configuration_digest ~operation_id ~image ~candidate
          in
          match target_kind with
          | Configuration.Target.Non_web -> (
              let%bind plan =
                Deferred.return
                  (Deployment_plan.create ~target_kind ~active_port:None)
              in
              let placement = Deployment_plan.placement plan in
              let%bind () =
                on_stage Planning "Planning single-container replacement"
                |> Deferred.map ~f:Or_error.return
              in
              let%bind () =
                on_stage Running_pre_start
                  "Running flake-declared pre-start commands"
                |> Deferred.map ~f:Or_error.return
              in
              let%bind () =
                Podman.run_pre_start ~connection ~target ~port:None ~image
                  ~secrets ~secret_mounts
              in
              let%bind () =
                on_stage Preparing_candidate
                  "Replacing only the owned application container"
                |> Deferred.map ~f:Or_error.return
              in
              let%bind () =
                Podman.prepare_candidate ~connection ~project ~target
                  ~resource_key ~placement
              in
              let%bind () =
                on_stage Starting "Starting the application container"
                |> Deferred.map ~f:Or_error.return
              in
              let%bind candidate =
                Podman.start_candidate ~connection ~project ~target
                  ~resource_key ~placement ~port:None ~source
                  ~configuration_digest ~operation_id
                  ~deployed_at:(timestamp ()) ~image ~secrets ~secret_mounts
              in
              let%bind.Deferred () =
                on_stage Verifying
                  "Reading back application image, state, name, and labels"
              in
              let%bind.Deferred verified = verify candidate in
              match verified with
              | Error error -> cleanup_candidate ~connection candidate error
              | Ok () -> (
                  match Cancellation.commit_current () with
                  | Cancellation.Cancel ->
                      cleanup_candidate ~connection candidate
                        (Error.of_string
                           "deployment cancelled before finalization")
                  | Continue ->
                      let%bind.Deferred () =
                        on_stage Succeeded "Deployment independently verified"
                      in
                      Deferred.Or_error.return
                        (deployment_result ~placement ~candidate ~warning:None))
              )
          | Web web ->
              let caddy = Caddy.create ~target ~resource_key ~web in
              let%bind () =
                on_stage Planning "Reading the exact current Caddy route"
                |> Deferred.map ~f:Or_error.return
              in
              let%bind previous = Caddy.inspect caddy in
              let active_port =
                match previous with
                | Caddy.Missing -> None
                | Existing { active_port } -> Some active_port
              in
              let%bind plan =
                Deferred.return
                  (Deployment_plan.create ~target_kind ~active_port)
              in
              let placement = Deployment_plan.placement plan in
              let candidate_port =
                match placement with
                | Deployment_plan.Web_slot { port; _ } -> port
                | Single_container -> assert false
              in
              let active_slot = Deployment_plan.active_slot plan in
              let%bind previous_candidate =
                match active_slot with
                | None -> Deferred.Or_error.return None
                | Some slot -> (
                    let%bind candidate =
                      Podman.find_owned_slot ~connection ~project ~target
                        ~resource_key ~slot
                    in
                    match candidate with
                    | Some candidate ->
                        Deferred.Or_error.return (Some candidate)
                    | None ->
                        Deferred.Or_error.error_string
                          "Caddy active slot has no owned container")
              in
              let%bind () =
                on_stage Preparing_candidate
                  "Removing only the owned inactive slot"
                |> Deferred.map ~f:Or_error.return
              in
              let%bind () =
                Podman.prepare_candidate ~connection ~project ~target
                  ~resource_key ~placement
              in
              let%bind () =
                on_stage Running_pre_start
                  "Running flake-declared pre-start commands"
                |> Deferred.map ~f:Or_error.return
              in
              let%bind () =
                Podman.run_pre_start ~connection ~target
                  ~port:(Some candidate_port) ~image ~secrets ~secret_mounts
              in
              let%bind () =
                on_stage Starting "Starting the inactive candidate slot"
                |> Deferred.map ~f:Or_error.return
              in
              let%bind candidate =
                Podman.start_candidate ~connection ~project ~target
                  ~resource_key ~placement ~port:(Some candidate_port) ~source
                  ~configuration_digest ~operation_id
                  ~deployed_at:(timestamp ()) ~image ~secrets ~secret_mounts
              in
              let after_candidate =
                let open Deferred.Let_syntax in
                let%bind () =
                  on_stage Verifying "Reading back candidate image and labels"
                in
                let%bind verified = verify candidate in
                match verified with
                | Error error -> cleanup_candidate ~connection candidate error
                | Ok () -> (
                    let%bind () =
                      on_stage Health_checking "Waiting for target-local health"
                    in
                    let%bind healthy =
                      Caddy.health_check caddy ~port:candidate_port
                    in
                    match healthy with
                    | Error error ->
                        cleanup_candidate ~connection candidate error
                    | Ok () -> (
                        let%bind () =
                          on_stage Switching "Switching the exact Caddy proxy"
                        in
                        let%bind switched =
                          Caddy.switch caddy ~previous ~candidate_port
                        in
                        match switched with
                        | Error error ->
                            restore_and_cleanup ~caddy ~previous ~connection
                              ~candidate error
                        | Ok () -> (
                            let%bind () =
                              on_stage Verifying
                                "Verifying ingress and candidate identity"
                            in
                            let%bind observed = Caddy.inspect caddy in
                            match observed with
                            | Error error ->
                                restore_and_cleanup ~caddy ~previous ~connection
                                  ~candidate error
                            | Ok observed -> (
                                let ingress_valid =
                                  match observed with
                                  | Caddy.Existing { active_port } ->
                                      Int.equal active_port candidate_port
                                  | Missing -> false
                                in
                                let%bind candidate_valid = verify candidate in
                                match (ingress_valid, candidate_valid) with
                                | true, Ok () -> (
                                    let%bind cancellation =
                                      match Cancellation.commit_current () with
                                      | Continue -> Deferred.Or_error.return ()
                                      | Cancel ->
                                          restore_and_cleanup ~caddy ~previous
                                            ~connection ~candidate
                                            (Error.of_string
                                               "deployment cancelled before \
                                                finalization")
                                    in
                                    match cancellation with
                                    | Error error ->
                                        Deferred.return (Error error)
                                    | Ok () ->
                                        let%bind retired =
                                          match previous_candidate with
                                          | None -> Deferred.Or_error.return ()
                                          | Some previous_candidate -> (
                                              let%bind () =
                                                on_stage Retiring_previous
                                                  "Retiring the previous \
                                                   active slot"
                                              in
                                              let%bind observed =
                                                Caddy.inspect
                                                  ~ignore_termination:true caddy
                                              in
                                              match observed with
                                              | Ok
                                                  (Caddy.Existing
                                                     { active_port })
                                                when Int.equal active_port
                                                       candidate_port ->
                                                  Podman.remove_candidate
                                                    ~connection
                                                    ~candidate:
                                                      previous_candidate
                                              | Error error ->
                                                  Deferred.return (Error error)
                                              | _ ->
                                                  Deferred.Or_error.error_string
                                                    "Caddy route changed \
                                                     before previous slot \
                                                     retirement")
                                        in
                                        let warning =
                                          Result.error retired
                                          |> Option.map ~f:(fun error ->
                                              "Deployment verified, but \
                                               previous slot retirement \
                                               failed: "
                                              ^ Error.to_string_hum error)
                                        in
                                        let message =
                                          Option.value warning
                                            ~default:
                                              "Deployment independently \
                                               verified"
                                        in
                                        let%bind () =
                                          on_stage Succeeded message
                                        in
                                        Deferred.Or_error.return
                                          (deployment_result ~placement
                                             ~candidate ~warning))
                                | _ ->
                                    let failure =
                                      match candidate_valid with
                                      | Error error -> error
                                      | Ok () ->
                                          Error.of_string
                                            "Caddy readback did not select \
                                             candidate"
                                    in
                                    restore_and_cleanup ~caddy ~previous
                                      ~connection ~candidate failure))))
              in
              after_candidate)
