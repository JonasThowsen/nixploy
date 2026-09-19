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

let build_heartbeat_interval = Time_ns.Span.of_sec 30.
let max_build_heartbeats = 119

let combine_failure primary secondary =
  Error.create_s [%message (primary : Error.t) (secondary : Error.t)]

let run_build_with_durable_heartbeats ~store ~operation_id build =
  let stopped = Ivar.create () in
  let request_build_cancellation () =
    Option.iter (Cancellation.current ()) ~f:(fun cancellation ->
        ignore (Cancellation.request cancellation : Cancellation.request))
  in
  let rec heartbeat number =
    if number > max_build_heartbeats then Deferred.Or_error.return ()
    else
      let open Deferred.Let_syntax in
      let%bind next =
        Deferred.choose
          [
            Deferred.choice (Ivar.read stopped) (fun () -> `Stopped);
            Deferred.choice (Clock_ns.after build_heartbeat_interval) (fun () ->
                `Heartbeat);
          ]
      in
      match next with
      | `Stopped -> Deferred.Or_error.return ()
      | `Heartbeat -> (
          let message =
            sprintf
              "Nix image build still running (elapsed %ds; build output \
               remains buffered)"
              (number * 30)
          in
          let%bind wrote =
            Store.record_stage store ~id:operation_id ~stage:"building" ~message
          in
          match wrote with
          | Ok () -> heartbeat (number + 1)
          | Error error -> Deferred.return (Error error))
  in
  let heartbeat_owner = heartbeat 1 in
  let open Deferred.Let_syntax in
  let%bind winner =
    Deferred.choose
      [
        Deferred.choice build (fun result -> `Build result);
        Deferred.choice heartbeat_owner (fun result -> `Heartbeat result);
      ]
  in
  match winner with
  | `Build result ->
      Ivar.fill_if_empty stopped ();
      let%map heartbeat_result = heartbeat_owner in
      Result.bind heartbeat_result ~f:(fun () -> result)
  | `Heartbeat (Ok ()) ->
      let%map result = build in
      result
  | `Heartbeat (Error heartbeat_error) -> (
      (* The heartbeat owns build liveness: a failed durable write requests the
         exact cancellation token that Process_runner observes and then waits
         for that process group to finish before execution can terminalize. *)
      request_build_cancellation ();
      let%bind build_result = build in
      Ivar.fill_if_empty stopped ();
      let%map () = heartbeat_owner >>| ignore in
      match build_result with
      | Ok _ -> Error heartbeat_error
      | Error build_error -> Error (combine_failure heartbeat_error build_error)
      )

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

type prepared = {
  request : Deployment_request.t;
  source : Source.t;
  project : Project_name.t;
  target_name : Target_name.t;
  target : Configuration.Target.t;
  repository_identity : string;
  configuration_digest : string;
  candidates : Resource_key.t list;
}

let cleanup_prepared prepared = Source.cleanup prepared.source

let prepare ~request =
  let open Deferred.Or_error.Let_syntax in
  let%bind () = Deferred.return (Deployment_request.claim request) in
  let expected_project = Deployment_request.expected_project request in
  let working_directory = Deployment_request.working_directory request in
  let target_name = Deployment_request.target request in
  let%bind source =
    Source.prepare ~working_directory
      ~selection:(Deployment_request.source request)
  in
  let validate () =
    let open Deferred.Or_error.Let_syntax in
    let%bind evaluated =
      Nix_configuration.load_evaluated ~offline:false
        ~working_directory:(Source.nix_root source)
        ~flake:(Source.nix_flake source)
    in
    let configuration = Nix_configuration.configuration evaluated in
    let%bind () =
      Deferred.return
        (Direct_mode.validate_configuration configuration ~target:target_name)
    in
    let project = Configuration.project configuration in
    let%bind () =
      match expected_project with
      | None -> Deferred.Or_error.return ()
      | Some expected when Project_name.equal expected project ->
          Deferred.Or_error.return ()
      | Some _ ->
          Deferred.Or_error.error_string
            "deployment project mismatch: evaluated project differs from the \
             requested project"
    in
    let%bind target =
      Deferred.return (Configuration.find_target configuration target_name)
    in
    let repository_identity = Source.repository source in
    let%bind candidates =
      Deferred.return
        (Resource_key.candidates ~project ~target:target_name
           ~repository_identity)
    in
    let configuration_digest =
      Nix_configuration.json evaluated
      |> Digestif.SHA256.digest_string |> Digestif.SHA256.to_hex
    in
    Deferred.Or_error.return
      {
        request;
        source;
        project;
        target_name;
        target;
        repository_identity;
        configuration_digest;
        candidates;
      }
  in
  let%bind.Deferred result = Monitor.try_with_or_error validate in
  match Or_error.join result with
  | Ok prepared -> Deferred.Or_error.return prepared
  | Error error ->
      let%map.Deferred () = Source.cleanup source in
      Error error

let execute_guarded ~store ~request ~operation_id prepared =
  let record_stage stage message =
    Store.record_stage store ~id:operation_id ~stage:(stage_name stage) ~message
  in
  let open Deferred.Or_error.Let_syntax in
  let%bind () =
    if phys_equal request prepared.request then
      Deferred.return
        (Deployment_request.validate_operation request ~operation_id)
    else
      Deferred.Or_error.error_string
        "prepared deployment belongs to a different request"
  in
  let source = prepared.source in
  let project = prepared.project in
  let target_name = prepared.target_name in
  let target = prepared.target in
  let repository_identity = prepared.repository_identity in
  let configuration_digest = prepared.configuration_digest in
  let%bind resource_key =
    Podman.select_resource_key ~project ~target ~repository_identity
      ~candidates:prepared.candidates
  in
  let%bind () =
    record_stage Connecting "Verifying the canonical Podman connection"
  in
  let%bind connection = Podman.ensure_connection ~target ~resource_key in
  let%bind () = Podman.preflight_read_only_bind_sources ~target in
  let load_artifacts () =
    let open Deferred.Or_error.Let_syntax in
    let%bind () = record_stage Building "Building and loading the image" in
    let build =
      Podman.build_and_load ~connection ~source
        ~image_output:(Configuration.Target.image target)
        ()
    in
    let%bind image =
      run_build_with_durable_heartbeats ~store ~operation_id build
    in
    let%bind secrets = Secrets.load ~source_root:(Source.path source) ~target in
    let%map secret_mounts =
      Podman.install_secrets ~connection ~project ~target ~repository_identity
        ~resource_key ~secrets
    in
    (image, secrets, secret_mounts)
  in
  let target_kind = Configuration.Target.kind target in
  let deployment_result ~image ~placement ~candidate ~warning =
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
  match target_kind with
  | Configuration.Target.Non_web -> (
      let%bind image, secrets, secret_mounts = load_artifacts () in
      let verify candidate =
        Podman.verify_candidate ~connection ~project ~target ~resource_key
          ~repository_identity ~source ~configuration_digest ~operation_id
          ~image ~candidate
      in
      let%bind plan =
        Deferred.return (Deployment_plan.create ~target_kind ~active_port:None)
      in
      let placement = Deployment_plan.placement plan in
      let%bind () =
        record_stage Planning "Planning single-container replacement"
      in
      let%bind () =
        record_stage Running_pre_start
          "Running flake-declared pre-start commands"
      in
      let%bind () =
        Podman.run_pre_start ~connection ~target ~placement ~source ~image
          ~secrets ~secret_mounts
      in
      let%bind () =
        record_stage Preparing_candidate
          "Replacing only the owned application container"
      in
      let%bind () =
        Podman.prepare_candidate ~connection ~project ~target ~resource_key
          ~repository_identity ~placement
      in
      let%bind () =
        record_stage Starting "Starting the application container"
      in
      let%bind candidate =
        Podman.start_candidate ~connection ~project ~target ~resource_key
          ~repository_identity ~placement ~source ~configuration_digest
          ~operation_id ~deployed_at:(timestamp ()) ~image ~secrets
          ~secret_mounts
      in
      let after_candidate =
        let open Deferred.Or_error.Let_syntax in
        let%bind () =
          record_stage Verifying
            "Reading back application image, state, name, and labels"
        in
        let%bind () = verify candidate in
        let%bind () =
          match Cancellation.commit_current () with
          | Cancellation.Cancel ->
              Deferred.Or_error.error_string
                "deployment cancelled before finalization"
          | Continue -> Deferred.Or_error.return ()
        in
        let%map () =
          record_stage Succeeded "Deployment independently verified"
        in
        deployment_result ~image ~placement ~candidate ~warning:None
      in
      let%bind.Deferred result = after_candidate in
      match result with
      | Ok deployment -> Deferred.Or_error.return deployment
      | Error error -> cleanup_candidate ~connection candidate error)
  | Web web -> (
      let caddy = Caddy.create ~target ~resource_key ~web in
      let%bind () =
        record_stage Planning "Reading the exact current Caddy route"
      in
      let%bind previous = Caddy.inspect caddy in
      let active_port =
        match previous with
        | Caddy.Missing -> None
        | Existing { active_port; _ } -> Some active_port
      in
      let%bind plan =
        Deferred.return (Deployment_plan.create ~target_kind ~active_port)
      in
      let placement = Deployment_plan.placement plan in
      let%bind _candidate_slot, candidate_port =
        Deferred.return (Deployment_plan.web_placement plan)
      in
      let active_slot = Deployment_plan.active_slot plan in
      let%bind previous_candidate =
        match active_slot with
        | None ->
            (* Without a route (for example after Caddy lost its API
               configuration), an owned container in the other slot is no
               longer served and is retired after a verified switch. *)
            let%bind candidate_slot, _ =
              Deferred.return (Deployment_plan.web_placement plan)
            in
            Podman.find_owned_slot ~connection ~project ~target ~resource_key
              ~repository_identity
              ~slot:(Deployment_plan.other_slot candidate_slot)
        | Some slot -> (
            let%bind candidate =
              Podman.find_owned_slot ~connection ~project ~target ~resource_key
                ~repository_identity ~slot
            in
            match candidate with
            | Some candidate -> Deferred.Or_error.return (Some candidate)
            | None ->
                Deferred.Or_error.error_string
                  "Caddy active slot has no owned container")
      in
      let%bind legacy_single =
        Podman.find_owned_placement ~connection ~project ~target ~resource_key
          ~repository_identity ~placement:Deployment_plan.Single_container
      in
      let%bind image, secrets, secret_mounts = load_artifacts () in
      let verify candidate =
        Podman.verify_candidate ~connection ~project ~target ~resource_key
          ~repository_identity ~source ~configuration_digest ~operation_id
          ~image ~candidate
      in
      let%bind () =
        record_stage Preparing_candidate "Removing only the owned inactive slot"
      in
      let%bind () =
        Podman.prepare_candidate ~connection ~project ~target ~resource_key
          ~repository_identity ~placement
      in
      let%bind () =
        record_stage Running_pre_start
          "Running flake-declared pre-start commands"
      in
      let%bind () =
        Podman.run_pre_start ~connection ~target ~placement ~source ~image
          ~secrets ~secret_mounts
      in
      let%bind () =
        record_stage Starting "Starting the inactive candidate slot"
      in
      let%bind candidate =
        Podman.start_candidate ~connection ~project ~target ~resource_key
          ~repository_identity ~placement ~source ~configuration_digest
          ~operation_id ~deployed_at:(timestamp ()) ~image ~secrets
          ~secret_mounts
      in
      let switched = ref false in
      let after_candidate =
        let open Deferred.Or_error.Let_syntax in
        let%bind () =
          record_stage Verifying "Reading back candidate image and labels"
        in
        let%bind () = verify candidate in
        let%bind () =
          record_stage Health_checking "Waiting for target-local health"
        in
        let%bind () = Caddy.health_check caddy ~port:candidate_port in
        let%bind () =
          record_stage Switching "Switching the exact Caddy proxy"
        in
        switched := true;
        let%bind () = Caddy.switch caddy ~previous ~candidate_port in
        let%bind () =
          record_stage Verifying "Verifying ingress and candidate identity"
        in
        let%bind observed = Caddy.inspect caddy in
        let%bind () =
          match observed with
          | Caddy.Existing { active_port; domain }
            when Int.equal active_port candidate_port
                 && String.Caseless.equal domain (Configuration.Web.domain web)
            ->
              Deferred.Or_error.return ()
          | _ ->
              Deferred.Or_error.error_string
                "Caddy readback did not select candidate"
        in
        let%bind () = verify candidate in
        let%bind () =
          match Cancellation.commit_current () with
          | Continue -> Deferred.Or_error.return ()
          | Cancel ->
              Deferred.Or_error.error_string
                "deployment cancelled before finalization"
        in
        let retirements =
          List.filter_opt [ previous_candidate; legacy_single ]
          |> List.dedup_and_sort ~compare:(fun left right ->
              String.compare (Podman.candidate_id left)
                (Podman.candidate_id right))
        in
        let%bind () =
          if List.is_empty retirements then Deferred.Or_error.return ()
          else
            record_stage Retiring_previous
              "Retiring previous owned application containers"
        in
        let%bind () =
          record_stage Succeeded "Deployment independently verified"
        in
        let%bind.Deferred retirement_results =
          let open Deferred.Let_syntax in
          let%bind observed = Caddy.inspect ~ignore_termination:true caddy in
          match observed with
          | Ok (Caddy.Existing { active_port; domain })
            when Int.equal active_port candidate_port
                 && String.Caseless.equal domain (Configuration.Web.domain web)
            ->
              Deferred.List.map retirements ~how:`Sequential
                ~f:(fun retirement ->
                  let%map result =
                    Podman.remove_candidate ~connection ~candidate:retirement
                  in
                  (retirement, result))
          | Error error ->
              Deferred.return
                (List.map retirements ~f:(fun retirement ->
                     (retirement, Error error)))
          | _ ->
              let error =
                Error.of_string
                  "Caddy route changed before container retirement"
              in
              Deferred.return
                (List.map retirements ~f:(fun retirement ->
                     (retirement, Error error)))
        in
        let warning =
          List.filter_map retirement_results ~f:(fun (retirement, result) ->
              Result.error result
              |> Option.map ~f:(fun error ->
                  sprintf "%s: %s"
                    (Podman.candidate_name retirement)
                    (Error.to_string_hum error)))
          |> function
          | [] -> None
          | failures ->
              Some
                (String.prefix
                   ("Deployment verified, but container retirement failed: "
                   ^ String.concat failures ~sep:"; ")
                   4096)
        in
        Deferred.Or_error.return
          (deployment_result ~image ~placement ~candidate ~warning)
      in
      let%bind.Deferred result = after_candidate in
      match result with
      | Ok deployment -> Deferred.Or_error.return deployment
      | Error error when !switched ->
          restore_and_cleanup ~caddy ~previous ~connection ~candidate error
      | Error error -> cleanup_candidate ~connection candidate error)

let execute ~store ~request ~operation_id prepared =
  Mutation_guard.with_mutation ~project:prepared.project ~target:prepared.target
    (fun () ->
      let open Deferred.Or_error.Let_syntax in
      let%bind deployment =
        execute_guarded ~store ~request ~operation_id prepared
      in
      match deployment.warning with
      | None -> Deferred.Or_error.return deployment
      | Some warning ->
          Deferred.Or_error.errorf
            "NIXPLOY_DEPLOYMENT_PARTIAL: application is active but cleanup is \
             not confirmed: %s"
            warning)

let deploy ~store ~request ~operation_id () =
  let open Deferred.Or_error.Let_syntax in
  let%bind prepared = prepare ~request in
  let%bind () =
    Deferred.return (Deployment_request.bind_operation request ~operation_id)
  in
  Monitor.protect
    ~finally:(fun () -> cleanup_prepared prepared)
    (fun () -> execute ~store ~request ~operation_id prepared)
