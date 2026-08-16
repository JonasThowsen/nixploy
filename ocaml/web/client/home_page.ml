open Core
open! Bonsai_web.Cont

let deployment_interrupted deployment =
  (match deployment.Protocol.Deployment.state with
    | Requested | Running -> true
    | _ -> false)
  && not deployment.can_cancel

let deployment_active deployment =
  deployment.Protocol.Deployment.can_cancel
  &&
  match deployment.state with
  | Requested | Running -> true
  | Succeeded | Failed | Cancelled -> false

let deployment_failed deployment =
  deployment_interrupted deployment
  ||
  match deployment.Protocol.Deployment.state with
  | Failed -> true
  | Requested | Running | Succeeded | Cancelled -> false

let health_counts targets =
  List.concat_map targets ~f:(fun target ->
      target.Protocol.Target_metrics.applications)
  |> List.fold ~init:(0, 0, 0) ~f:(fun (healthy, unhealthy, unavailable) app ->
      match app.Protocol.Application_metrics.health with
      | Healthy -> (healthy + 1, unhealthy, unavailable)
      | Unhealthy -> (healthy, unhealthy + 1, unavailable)
      | Unavailable _ -> (healthy, unhealthy, unavailable + 1))

let stat_card ~label ~value ~detail ~tone =
  Vdom.Node.div
    ~attrs:[ Vdom.Attr.classes [ "summary-card"; tone ] ]
    [
      Vdom.Node.span [ Vdom.Node.text label ];
      Vdom.Node.strong [ Vdom.Node.text value ];
      Vdom.Node.p [ Vdom.Node.text detail ];
    ]

let concise_summary response ~value ~detail ~tone =
  match response with
  | None -> ("—", "loading", "tone-working")
  | Some (Error _) -> ("—", "unavailable", "tone-danger")
  | Some (Ok values) -> (value values, detail values, tone values)

let render ~applications ~deployments ~metrics ~applications_stale
    ~deployments_stale ~metrics_stale ~connection_label:_ ~navigate =
  let values = function
    | Some (Ok values) -> values
    | None | Some (Error _) -> []
  in
  let deployment_values = values deployments in
  let metric_values = values metrics in
  let active =
    List.count deployment_values ~f:(fun recent ->
        deployment_active recent.Protocol.Recent_deployment.deployment)
  in
  let failures =
    List.count deployment_values ~f:(fun recent ->
        deployment_failed recent.Protocol.Recent_deployment.deployment)
  in
  let healthy, unhealthy, unavailable = health_counts metric_values in
  let observed = healthy + unhealthy + unavailable in
  let applications_summary =
    concise_summary applications
      ~value:(fun applications -> Int.to_string (List.length applications))
      ~detail:(Fn.const "managed") ~tone:(Fn.const "tone-neutral")
  in
  let runtime_summary =
    concise_summary metrics
      ~value:(fun _ -> sprintf "%d / %d" healthy observed)
      ~detail:(Fn.const "runtime")
      ~tone:(fun _ ->
        if Int.equal observed 0 then "tone-neutral"
        else if unhealthy > 0 then "tone-danger"
        else if unavailable > 0 then "tone-working"
        else "tone-ok")
  in
  let deployment_summary =
    concise_summary deployments
      ~value:(fun _ -> Int.to_string active)
      ~detail:(Fn.const "active")
      ~tone:(fun _ -> if active > 0 then "tone-working" else "tone-neutral")
  in
  let failure_summary =
    concise_summary deployments
      ~value:(fun _ -> Int.to_string failures)
      ~detail:(Fn.const "recent")
      ~tone:(fun _ -> if failures > 0 then "tone-danger" else "tone-neutral")
  in
  let target_errors =
    List.count metric_values ~f:(fun target ->
        Option.is_some target.Protocol.Target_metrics.error)
  in
  let application_errors =
    List.sum
      (module Int)
      metric_values
      ~f:(fun target ->
        List.count target.Protocol.Target_metrics.applications
          ~f:(fun application ->
            Option.is_some application.Protocol.Application_metrics.error))
  in
  let telemetry_class, telemetry_label, telemetry_detail =
    match metrics with
    | None -> ("status-warning", "Checking", "Loading live data")
    | Some (Error _) -> ("status-danger", "Unavailable", "Live data unavailable")
    | Some (Ok []) -> ("status-muted", "No data", "No machines configured")
    | Some (Ok targets) ->
        let target_count = List.length targets in
        let detail =
          sprintf "%d / %d healthy · %d machine%s" healthy observed target_count
            (if target_count = 1 then "" else "s")
        in
        if target_errors + application_errors > 0 then
          ("status-danger", "Incomplete", detail)
        else if unhealthy + unavailable > 0 then
          ("status-warning", "Attention", detail)
        else ("status-ok", "Available", detail)
  in
  let activity = List.take deployment_values 4 in
  Vdom.Node.div
    ~attrs:[ Vdom.Attr.class_ "page home-page" ]
    [
      Vdom.Node.header
        ~attrs:[ Vdom.Attr.class_ "home-heading" ]
        [ Vdom.Node.h2 [ Vdom.Node.text "Overview" ] ];
      Vdom.Node.section
        ~attrs:[ Vdom.Attr.create "aria-label" "Control-plane summary" ]
        [
          Vdom.Node.div
            ~attrs:[ Vdom.Attr.class_ "summary-grid home-summary-grid" ]
            [
              (let value, detail, tone = applications_summary in
               stat_card ~label:"Applications" ~value ~detail ~tone);
              (let value, detail, tone = runtime_summary in
               stat_card ~label:"Healthy" ~value ~detail ~tone);
              (let value, detail, tone = deployment_summary in
               stat_card ~label:"Deploying" ~value ~detail ~tone);
              (let value, detail, tone = failure_summary in
               stat_card ~label:"Failures" ~value ~detail ~tone);
            ];
          Ui_helpers.polling_warning
            ~has_last_good:(Option.is_some applications)
            applications_stale;
        ];
      Vdom.Node.section
        ~attrs:
          [
            Vdom.Attr.classes [ "surface"; "telemetry-summary" ];
            Vdom.Attr.create "aria-labelledby" "telemetry-summary";
            Vdom.Attr.create "aria-live" "polite";
          ]
        [
          Vdom.Node.header
            ~attrs:[ Vdom.Attr.class_ "surface-header telemetry-strip-header" ]
            [
              Vdom.Node.h3
                ~attrs:[ Vdom.Attr.id "telemetry-summary" ]
                [ Vdom.Node.text "Telemetry" ];
              Ui_helpers.route_link ~class_name:"text-link"
                ~route:Route.Telemetry ~navigate
                [ Vdom.Node.text "Details" ];
            ];
          Ui_helpers.polling_warning ~has_last_good:(Option.is_some metrics)
            metrics_stale;
          Vdom.Node.div
            ~attrs:[ Vdom.Attr.class_ "telemetry-strip-status" ]
            [
              Ui_helpers.state_badge ~class_name:telemetry_class
                ~label:telemetry_label;
              Vdom.Node.p
                ~attrs:[ Vdom.Attr.class_ "telemetry-summary-copy" ]
                [ Vdom.Node.text telemetry_detail ];
            ];
        ];
      Vdom.Node.section
        ~attrs:
          [
            Vdom.Attr.classes [ "surface"; "home-activity" ];
            Vdom.Attr.create "aria-labelledby" "recent-activity";
          ]
        [
          Vdom.Node.header
            ~attrs:[ Vdom.Attr.class_ "surface-header" ]
            [
              Vdom.Node.h3
                ~attrs:[ Vdom.Attr.id "recent-activity" ]
                [ Vdom.Node.text "Recent deployments" ];
            ];
          Ui_helpers.polling_warning
            ~has_last_good:(Option.is_some deployments)
            deployments_stale;
          (match deployments with
          | None ->
              Vdom.Node.p
                ~attrs:[ Vdom.Attr.class_ "home-inline-state" ]
                [ Vdom.Node.text "Loading…" ]
          | Some (Error _) ->
              Vdom.Node.p
                ~attrs:
                  [ Vdom.Attr.classes [ "home-inline-state"; "danger-copy" ] ]
                [ Vdom.Node.text "Deployment history unavailable." ]
          | Some (Ok []) ->
              Vdom.Node.p
                ~attrs:[ Vdom.Attr.class_ "home-inline-state" ]
                [ Vdom.Node.text "No deployments recorded." ]
          | Some (Ok _) ->
              Vdom.Node.ol
                ~attrs:[ Vdom.Attr.class_ "deployment-list" ]
                (List.map activity ~f:(Ui_helpers.deployment_row ~navigate)));
        ];
    ]
