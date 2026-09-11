open Async
open Core

type t = { connection : string; container : Podman.runtime_container }

let connection t = t.connection
let container t = t.container

let resolve_running ~project ~target ~resource_key ~repository_identity =
  let open Deferred.Or_error.Let_syntax in
  let%bind connection = Podman.ensure_connection ~target ~resource_key in
  let%map container =
    match Configuration.Target.kind target with
    | Non_web ->
        let%bind plan =
          Deferred.return
            (Deployment_plan.create ~target_kind:Non_web ~active_port:None)
        in
        Podman.find_running_placement ~connection ~project ~target ~resource_key
          ~repository_identity
          ~placement:(Deployment_plan.placement plan)
    | Web web ->
        let caddy = Caddy.create ~target ~resource_key ~web in
        let%bind route = Caddy.inspect caddy in
        let%bind active_port =
          match route with
          | Missing ->
              Deferred.Or_error.error_string
                "runbook has no positively identified active Caddy route"
          | Existing { active_port; domain } ->
              if String.equal domain (Configuration.Web.domain web) then
                Deferred.Or_error.return active_port
              else
                Deferred.Or_error.error_string
                  "runbook active Caddy domain does not match target"
        in
        let%bind plan =
          Deferred.return
            (Deployment_plan.create ~target_kind:(Web web)
               ~active_port:(Some active_port))
        in
        let%bind slot =
          match Deployment_plan.active_slot plan with
          | Some slot -> Deferred.Or_error.return slot
          | None -> Deferred.Or_error.error_string "runbook has no active slot"
        in
        Podman.find_running_slot ~connection ~project ~target ~resource_key
          ~repository_identity ~slot
  in
  { connection; container }
