open Core
open! Bonsai_web.Cont

val render :
  applications:Protocol.Application.t list Or_error.t option ->
  metrics:Protocol.Target_metrics.t list Or_error.t option ->
  applications_stale:Error.t option ->
  metrics_stale:Error.t option ->
  navigate:Ui_helpers.navigate ->
  Vdom.Node.t
