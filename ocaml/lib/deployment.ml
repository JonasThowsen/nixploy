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
  slot : Deployment_plan.slot;
  port : int;
}

let operation_id t = t.operation_id
let project t = t.project
let target t = t.target
let revision t = t.revision
let image_id t = t.image_id
let container_name t = t.container_name
let container_id t = t.container_id
let slot t = t.slot
let port t = t.port

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
  | Succeeded -> "succeeded"

let timestamp () =
  let tm = Caml_unix.gmtime (Caml_unix.time ()) in
  sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (tm.tm_year + 1900) (tm.tm_mon + 1)
    tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec

let new_operation_id () =
  Uuid.create_random (Random.State.make_self_init ()) |> Uuid.to_string

let no_stage _ _ = Deferred.unit

let combine_failure primary secondary =
  Error.create_s [%message (primary : Error.t) (secondary : Error.t)]

let cleanup_candidate ~connection candidate primary =
  let%map cleanup = Podman.remove_candidate ~connection ~candidate in
  match cleanup with
  | Ok () -> Error primary
  | Error cleanup_error -> Error (combine_failure primary cleanup_error)

let restore_and_cleanup ~caddy ~previous ~connection ~candidate primary =
  let open Deferred.Let_syntax in
  let%bind restored = Caddy.restore caddy ~previous in
  let%bind removed = Podman.remove_candidate ~connection ~candidate in
  let error =
    match (restored, removed) with
    | Ok (), Ok () -> primary
    | Error restoration, Ok () -> combine_failure primary restoration
    | Ok (), Error cleanup -> combine_failure primary cleanup
    | Error restoration, Error cleanup ->
        combine_failure (combine_failure primary restoration) cleanup
  in
  Deferred.return (Error error)

let deploy ?(on_stage = no_stage) ~working_directory ~target:target_name () =
  let open Deferred.Let_syntax in
  let%bind () = on_stage Preparing_source "Resolving the exact head of main" in
  let%bind prepared = Source.prepare ~working_directory in
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
          let%bind web =
            Deferred.return (Configuration.Target.require_no_secret_web target)
          in
          let project = Configuration.project configuration in
          let%bind resource_key =
            Deferred.return (Resource_key.derive ~project ~target:target_name)
          in
          let operation_id = new_operation_id () in
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
            Deferred.return (Deployment_plan.create ~web ~active_port)
          in
          let candidate_slot = Deployment_plan.candidate_slot plan in
          let candidate_port = Deployment_plan.candidate_port plan in
          let%bind () =
            on_stage Preparing_candidate "Removing only the owned inactive slot"
            |> Deferred.map ~f:Or_error.return
          in
          let%bind () =
            Podman.prepare_candidate ~connection ~project ~target ~resource_key
              ~slot:candidate_slot
          in
          let%bind () =
            on_stage Running_pre_start
              "Running flake-declared pre-start commands"
            |> Deferred.map ~f:Or_error.return
          in
          let%bind () =
            Podman.run_pre_start ~connection ~target ~port:candidate_port ~image
          in
          let%bind () =
            on_stage Starting "Starting the inactive candidate slot"
            |> Deferred.map ~f:Or_error.return
          in
          let%bind candidate =
            Podman.start_candidate ~connection ~project ~target ~resource_key
              ~slot:candidate_slot ~port:candidate_port ~source
              ~configuration_digest ~operation_id ~deployed_at:(timestamp ())
              ~image
          in
          let after_candidate =
            let open Deferred.Let_syntax in
            let%bind () =
              on_stage Verifying "Reading back candidate image and labels"
            in
            let%bind verified =
              Podman.verify_candidate ~connection ~project ~target ~resource_key
                ~source ~configuration_digest ~operation_id ~image ~candidate
            in
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
                | Error error -> cleanup_candidate ~connection candidate error
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
                            let%bind candidate_valid =
                              Podman.verify_candidate ~connection ~project
                                ~target ~resource_key ~source
                                ~configuration_digest ~operation_id ~image
                                ~candidate
                            in
                            match (ingress_valid, candidate_valid) with
                            | true, Ok () ->
                                let%bind () =
                                  on_stage Succeeded
                                    "Deployment independently verified"
                                in
                                Deferred.Or_error.return
                                  {
                                    operation_id;
                                    project;
                                    target = target_name;
                                    revision = Source.revision source;
                                    image_id = Podman.image_id image;
                                    container_name =
                                      Podman.candidate_name candidate;
                                    container_id = Podman.candidate_id candidate;
                                    slot = candidate_slot;
                                    port = candidate_port;
                                  }
                            | _ ->
                                let failure =
                                  match candidate_valid with
                                  | Error error -> error
                                  | Ok () ->
                                      Error.of_string
                                        "Caddy readback did not select \
                                         candidate"
                                in
                                restore_and_cleanup ~caddy ~previous ~connection
                                  ~candidate failure))))
          in
          after_candidate)
