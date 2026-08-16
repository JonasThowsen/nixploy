open Core
open! Bonsai_web.Cont

type navigate = Route.t -> unit Effect.t

let text_panel ~kind text =
  Vdom.Node.div
    ~attrs:[ Vdom.Attr.classes [ "message-panel"; kind ^ "-panel" ] ]
    [ Vdom.Node.text text ]

let polling_warning ~has_last_good error =
  match (has_last_good, error) with
  | true, Some error ->
      text_panel ~kind:"stale"
        ("Refresh failed; showing the last observation. "
       ^ Error.to_string_hum error)
  | false, Some error -> text_panel ~kind:"error" (Error.to_string_hum error)
  | _, None -> Vdom.Node.none

let button ?(kind = "secondary") ?(disabled = false) ?(autofocus = false) ?id
    ~label ~on_click () =
  Vdom.Node.button
    ~attrs:
      ([
         Vdom.Attr.classes [ "button"; "button-" ^ kind ];
         Vdom.Attr.create "type" "button";
       ]
      @ Option.value_map id ~default:[] ~f:(fun id -> [ Vdom.Attr.id id ])
      @ (if autofocus then [ Vdom.Attr.create "autofocus" "true" ] else [])
      @
      if disabled then [ Vdom.Attr.disabled ]
      else [ Vdom.Attr.on_click (fun _ -> on_click) ])
    [ Vdom.Node.text label ]

let route_link ?class_name ~route ~navigate children =
  Vdom.Node.a
    ~attrs:
      (Browser_navigation.link_attrs route ~on_navigate:navigate
      @ Option.value_map class_name ~default:[] ~f:(fun name ->
          [ Vdom.Attr.class_ name ]))
    children

let state_badge ~class_name ~label =
  Vdom.Node.span
    ~attrs:[ Vdom.Attr.classes [ "status-badge"; class_name ] ]
    [
      Vdom.Node.span
        ~attrs:
          [
            Vdom.Attr.class_ "status-dot"; Vdom.Attr.create "aria-hidden" "true";
          ]
        [];
      Vdom.Node.text label;
    ]

let resource_state = function
  | Protocol.Resource_state.Unknown -> ("Unknown", "status-warning")
  | Protocol.Resource_state.Present -> ("Present", "status-ok")
  | Protocol.Resource_state.Absent -> ("Absent", "status-muted")

let raw_deployment_state_name = function
  | Protocol.Deployment.State.Requested -> "Requested"
  | Running -> "Running"
  | Succeeded -> "Succeeded"
  | Failed -> "Failed"
  | Cancelled -> "Cancelled"

let raw_deployment_state_class = function
  | Protocol.Deployment.State.Requested -> "status-working"
  | Running -> "status-working"
  | Succeeded -> "status-ok"
  | Failed -> "status-danger"
  | Cancelled -> "status-info"

let deployment_state_name deployment =
  match deployment.Protocol.Deployment.state with
  | (Requested | Running) when not deployment.can_cancel -> "Interrupted"
  | state -> raw_deployment_state_name state

let deployment_state_class deployment =
  match deployment.Protocol.Deployment.state with
  | (Requested | Running) when not deployment.can_cancel -> "status-danger"
  | state -> raw_deployment_state_class state

let deployment_is_active = function
  | None -> false
  | Some deployment -> (
      deployment.Protocol.Deployment.can_cancel
      &&
      match deployment.state with
      | Requested | Running -> true
      | Succeeded | Failed | Cancelled -> false)

let short_revision revision =
  String.prefix revision (Int.min 12 (String.length revision))

let commit_summary = function
  | None -> ("No revision", "Commit details unavailable")
  | Some commit ->
      (short_revision commit.Protocol.Commit.revision, commit.subject)

let format_time timestamp_ms =
  timestamp_ms |> Int64.to_float |> Time_ns.Span.of_ms
  |> Time_ns.of_span_since_epoch |> Time_ns.to_string_utc

let format_duration deployment =
  match deployment.Protocol.Deployment.elapsed_ms with
  | None -> "Not started"
  | Some elapsed ->
      let seconds = Int64.to_float elapsed /. 1000. in
      if Float.(seconds < 60.) then sprintf "%.1fs" seconds
      else if Float.(seconds < 3_600.) then sprintf "%.1fm" (seconds /. 60.)
      else sprintf "%.1fh" (seconds /. 3_600.)

let format_bytes bytes =
  let value = Int64.to_float bytes in
  if Float.(value >= 1_073_741_824.) then
    sprintf "%.1f GiB" (value /. 1_073_741_824.)
  else if Float.(value >= 1_048_576.) then
    sprintf "%.1f MiB" (value /. 1_048_576.)
  else if Float.(value >= 1024.) then sprintf "%.1f KiB" (value /. 1024.)
  else sprintf "%Ld B" bytes

let format_percent = function
  | None -> "Unavailable"
  | Some value -> sprintf "%.1f%%" value

let format_uptime = function
  | None -> "Unavailable"
  | Some seconds ->
      let seconds = Int64.to_int_exn seconds in
      let days = seconds / 86_400 in
      let hours = seconds mod 86_400 / 3_600 in
      let minutes = seconds mod 3_600 / 60 in
      if days > 0 then sprintf "%dd %dh" days hours
      else if hours > 0 then sprintf "%dh %dm" hours minutes
      else sprintf "%dm" minutes

let deployment_row ?(link_application = true) ~navigate recent =
  let deployment = recent.Protocol.Recent_deployment.deployment in
  let revision, subject = commit_summary deployment.commit in
  let application =
    match Route.Application_key.of_string recent.application with
    | Ok key when link_application ->
        route_link ~class_name:"deployment-app-link"
          ~route:(Route.Application key) ~navigate
          [ Vdom.Node.text recent.application ]
    | Error _ | Ok _ -> Vdom.Node.strong [ Vdom.Node.text recent.application ]
  in
  Vdom.Node.li
    ~attrs:[ Vdom.Attr.class_ "deployment-row" ]
    [
      Vdom.Node.div
        ~attrs:[ Vdom.Attr.class_ "deployment-primary" ]
        [
          application;
          state_badge
            ~class_name:(deployment_state_class deployment)
            ~label:(deployment_state_name deployment);
        ];
      Vdom.Node.div
        ~attrs:[ Vdom.Attr.class_ "deployment-commit" ]
        [
          Vdom.Node.code
            ~attrs:
              (Option.value_map deployment.commit ~default:[] ~f:(fun commit ->
                   [ Vdom.Attr.title commit.revision ]))
            [ Vdom.Node.text revision ];
          Vdom.Node.span [ Vdom.Node.text subject ];
        ];
      Vdom.Node.div
        ~attrs:[ Vdom.Attr.class_ "deployment-meta" ]
        [
          Vdom.Node.span [ Vdom.Node.text deployment.stage ];
          Vdom.Node.create "time"
            [
              Vdom.Node.text
                (format_time
                   (Option.value deployment.started_at_ms
                      ~default:deployment.requested_at_ms));
            ];
          Vdom.Node.span [ Vdom.Node.text (format_duration deployment) ];
        ];
      (match deployment.error with
      | None -> Vdom.Node.none
      | Some error ->
          Vdom.Node.p
            ~attrs:[ Vdom.Attr.class_ "inline-error" ]
            [ Vdom.Node.text error ]);
    ]
