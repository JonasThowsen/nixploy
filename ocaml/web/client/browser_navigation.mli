open! Bonsai_web.Cont

type application_owner

val initial_route : unit -> Route.t
val application_owner : string -> application_owner Effect.t
val is_current_owner : application_owner -> bool

val start :
  on_route:(Route.t -> unit Effect.t) ->
  on_escape:(unit -> unit Effect.t) ->
  unit Effect.t

val cleanup : unit -> unit Effect.t
val push : Route.t -> unit Effect.t
val set_document_title : Route.t -> unit Effect.t

val link_attrs :
  Route.t -> on_navigate:(Route.t -> unit Effect.t) -> Vdom.Attr.t list

val focus : string -> unit Effect.t
