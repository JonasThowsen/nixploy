open! Bonsai_web.Cont

val render :
  route:Route.t ->
  applications:Protocol.Application.t list option ->
  connection_label:string ->
  connection_class:string ->
  mobile_open:bool ->
  navigate:Ui_helpers.navigate ->
  on_toggle_mobile:unit Effect.t ->
  on_close_mobile:unit Effect.t ->
  notice:string ->
  content:Vdom.Node.t ->
  Vdom.Node.t
