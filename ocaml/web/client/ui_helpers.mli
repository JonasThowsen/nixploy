open Core
open! Bonsai_web.Cont

type navigate = Route.t -> unit Effect.t

val text_panel : kind:string -> string -> Vdom.Node.t
val polling_warning : has_last_good:bool -> Error.t option -> Vdom.Node.t

val button :
  ?kind:string ->
  ?disabled:bool ->
  ?autofocus:bool ->
  ?id:string ->
  label:string ->
  on_click:unit Effect.t ->
  unit ->
  Vdom.Node.t

val route_link :
  ?class_name:string ->
  route:Route.t ->
  navigate:navigate ->
  Vdom.Node.t list ->
  Vdom.Node.t

val state_badge : class_name:string -> label:string -> Vdom.Node.t
val resource_state : Protocol.Resource_state.t -> string * string
val deployment_state_name : Protocol.Deployment.t -> string
val deployment_state_class : Protocol.Deployment.t -> string
val deployment_is_active : Protocol.Deployment.t option -> bool
val short_revision : string -> string
val commit_summary : Protocol.Commit.t option -> string * string
val format_time : int64 -> string
val format_duration : Protocol.Deployment.t -> string
val format_bytes : int64 -> string
val format_percent : float option -> string
val format_uptime : int64 option -> string

val deployment_row :
  ?link_application:bool ->
  navigate:navigate ->
  Protocol.Recent_deployment.t ->
  Vdom.Node.t
