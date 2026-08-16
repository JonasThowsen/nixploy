open Core
open! Bonsai_web.Cont

val render :
  metrics:Protocol.Target_metrics.t list Or_error.t option ->
  stale:Error.t option ->
  navigate:Ui_helpers.navigate ->
  Vdom.Node.t
