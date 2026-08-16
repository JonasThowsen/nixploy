open Core
open! Bonsai_web.Cont
module Deploy_state = Nixploy_web_client_state.Deploy_state
module Prune_state = Nixploy_web_client_state.Prune_state

type application_state =
  | Loading
  | Failed of Error.t
  | Missing
  | Ready of Protocol.Application.t

val render :
  key:string ->
  application_state:application_state ->
  deployments:Protocol.Recent_deployment.t list Or_error.t option ->
  logs:Protocol.Log_snapshot.t option Or_error.t option ->
  metrics:Protocol.Target_metrics.t list Or_error.t option ->
  deployments_stale:Error.t option ->
  logs_stale:Error.t option ->
  metrics_stale:Error.t option ->
  preview:(string * Protocol.Commit.t) option ->
  deploy_state:Deploy_state.t ->
  cancel_confirmation:string option ->
  prune_state:Prune_state.t ->
  search:string ->
  current_match:int ->
  follow:bool ->
  paused_snapshot:Protocol.Log_snapshot.t option ->
  dispatch_preview:
    (Protocol.Preview_deployment.Query.t ->
    Protocol.Commit.t Or_error.t Or_error.t Effect.t) ->
  dispatch_deploy:
    (Protocol.Deploy.Query.t -> string Or_error.t Or_error.t Effect.t) ->
  dispatch_cancel:
    (Protocol.Cancel_deployment_v1.Query.t ->
    unit Or_error.t Or_error.t Effect.t) ->
  dispatch_prune:
    (Protocol.Prune.Query.t ->
    Protocol.Prune_result.t Or_error.t Or_error.t Effect.t) ->
  set_preview:((string * Protocol.Commit.t) option -> unit Effect.t) ->
  set_deploy_state:(Deploy_state.t -> unit Effect.t) ->
  set_cancel_confirmation:(string option -> unit Effect.t) ->
  set_prune_state:(Prune_state.t -> unit Effect.t) ->
  set_search:(string -> unit Effect.t) ->
  set_current_match:(int -> unit Effect.t) ->
  set_follow:(bool -> unit Effect.t) ->
  set_paused_snapshot:(Protocol.Log_snapshot.t option -> unit Effect.t) ->
  set_notice:(string -> unit Effect.t) ->
  refresh_logs:unit Effect.t ->
  navigate:Ui_helpers.navigate ->
  Vdom.Node.t
