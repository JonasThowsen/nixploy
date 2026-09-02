open Core
open! Bonsai_web.Cont

let deployment_is_active deployment =
  deployment.Protocol.Deployment.can_cancel
  &&
  match deployment.state with
  | Requested | Running -> true
  | Succeeded | Failed | Cancelled -> false

let stat_card ~label ~value ~detail ~tone =
  Vdom.Node.div
    ~attrs:[ Vdom.Attr.classes [ "summary-card"; tone ] ]
    [
      Vdom.Node.span [ Vdom.Node.text label ];
      Vdom.Node.strong [ Vdom.Node.text value ];
      Vdom.Node.p [ Vdom.Node.text detail ];
    ]

let pair_bytes used total =
  match (used, total) with
  | Some used, Some total ->
      Ui_helpers.format_bytes used ^ " / " ^ Ui_helpers.format_bytes total
  | _ -> "Unavailable"

let target_health target =
  match target.Protocol.Target_metrics.error with
  | Some _ -> ("Unavailable", "status-danger")
  | None ->
      let unhealthy =
        List.exists target.applications ~f:(fun application ->
            match application.Protocol.Application_metrics.health with
            | Protocol.Health.Unhealthy | Unavailable _ -> true
            | Healthy -> false)
      in
      if unhealthy then ("Needs attention", "status-warning")
      else ("Healthy", "status-ok")

let fact label value =
  Vdom.Node.div
    [
      Vdom.Node.dt [ Vdom.Node.text label ];
      Vdom.Node.dd [ Vdom.Node.text value ];
    ]

let host_row ~navigate target =
  let health_label, health_class = target_health target in
  Vdom.Node.create "article"
    ~attrs:[ Vdom.Attr.class_ "host-health-row" ]
    [
      Vdom.Node.div
        [
          Vdom.Node.p
            ~attrs:[ Vdom.Attr.class_ "eyebrow" ]
            [ Vdom.Node.text "Host" ];
          Vdom.Node.h3 [ Vdom.Node.text target.target ];
          Vdom.Node.code [ Vdom.Node.text target.host ];
        ];
      Vdom.Node.div
        ~attrs:[ Vdom.Attr.class_ "host-health-status" ]
        [
          Ui_helpers.state_badge ~class_name:health_class ~label:health_label;
          Vdom.Node.span
            [ Vdom.Node.text (Ui_helpers.format_time target.observed_at_ms) ];
        ];
      Vdom.Node.dl
        ~attrs:[ Vdom.Attr.class_ "host-health-facts numeric" ]
        [
          fact "CPU" (Ui_helpers.format_percent target.cpu_percent);
          fact "Memory"
            (pair_bytes target.memory_used_bytes target.memory_total_bytes);
          fact "Disk"
            (pair_bytes target.filesystem_used_bytes
               target.filesystem_total_bytes);
          fact "Load"
            (match (target.load_1, target.load_5, target.load_15) with
            | Some one, Some five, Some fifteen ->
                sprintf "%.2f / %.2f / %.2f" one five fifteen
            | _ -> "Unavailable");
        ];
      Ui_helpers.route_link ~class_name:"text-link" ~route:Route.Telemetry
        ~navigate
        [ Vdom.Node.text "Details" ];
      (match target.error with
      | None -> Vdom.Node.none
      | Some error ->
          Vdom.Node.p
            ~attrs:[ Vdom.Attr.class_ "inline-error" ]
            [ Vdom.Node.text error ]);
    ]

let deployment_section ~title ~empty ~entries ~navigate =
  Vdom.Node.section
    ~attrs:[ Vdom.Attr.class_ "surface home-deployments" ]
    [
      Vdom.Node.header
        ~attrs:[ Vdom.Attr.class_ "surface-header" ]
        [ Vdom.Node.h3 [ Vdom.Node.text title ] ];
      (if List.is_empty entries then Ui_helpers.text_panel ~kind:"empty" empty
       else
         Vdom.Node.ol
           ~attrs:[ Vdom.Attr.class_ "deployment-list" ]
           (List.map entries ~f:(Ui_helpers.deployment_row ~navigate)));
    ]

let render ~applications ~deployments ~metrics ~applications_stale
    ~deployments_stale ~metrics_stale ~connection_label:_ ~navigate =
  let application_values =
    match applications with
    | Some (Ok values) -> values
    | None | Some (Error _) -> []
  in
  let deployment_values =
    match deployments with
    | Some (Ok values) -> values
    | None | Some (Error _) -> []
  in
  let metric_values =
    match metrics with
    | Some (Ok values) -> values
    | None | Some (Error _) -> []
  in
  let active =
    List.filter deployment_values ~f:(fun recent ->
        deployment_is_active recent.Protocol.Recent_deployment.deployment)
  in
  let previous =
    List.filter deployment_values ~f:(fun recent ->
        not (deployment_is_active recent.Protocol.Recent_deployment.deployment))
  in
  let healthy_hosts =
    List.count metric_values ~f:(fun target ->
        String.equal (fst (target_health target)) "Healthy")
  in
  let host_summary =
    match metrics with
    | None -> ("—", "Checking host health", "tone-working")
    | Some (Error _) -> ("—", "Host health unavailable", "tone-danger")
    | Some (Ok []) -> ("0", "no hosts configured", "tone-neutral")
    | Some (Ok targets) ->
        ( Int.to_string healthy_hosts
          ^ " / "
          ^ Int.to_string (List.length targets),
          "healthy hosts",
          if healthy_hosts = List.length targets then "tone-ok"
          else "tone-working" )
  in
  Vdom.Node.div
    ~attrs:[ Vdom.Attr.classes [ "page"; "home-page" ] ]
    [
      Vdom.Node.header
        ~attrs:[ Vdom.Attr.class_ "page-intro" ]
        [
          Vdom.Node.div
            [
              Vdom.Node.p
                ~attrs:[ Vdom.Attr.class_ "eyebrow" ]
                [ Vdom.Node.text "Nixploy" ];
              Vdom.Node.h2 [ Vdom.Node.text "Operations overview" ];
              Vdom.Node.p
                [
                  Vdom.Node.text
                    "Check host health, open an application to deploy, and \
                     follow deployment activity.";
                ];
            ];
          Ui_helpers.route_link ~class_name:"button button-primary"
            ~route:Route.Apps ~navigate
            [ Vdom.Node.text "Open applications" ];
        ];
      Vdom.Node.section
        ~attrs:[ Vdom.Attr.class_ "summary-grid" ]
        [
          (let value, detail, tone = host_summary in
           stat_card ~label:"Hosts" ~value ~detail ~tone);
          stat_card ~label:"Applications"
            ~value:(Int.to_string (List.length application_values))
            ~detail:"managed applications" ~tone:"tone-neutral";
          stat_card ~label:"Deploying"
            ~value:(Int.to_string (List.length active))
            ~detail:"currently running"
            ~tone:
              (if List.is_empty active then "tone-neutral" else "tone-working");
        ];
      Ui_helpers.polling_warning
        ~has_last_good:(Option.is_some applications)
        applications_stale;
      Ui_helpers.polling_warning ~has_last_good:(Option.is_some metrics)
        metrics_stale;
      Vdom.Node.section
        ~attrs:[ Vdom.Attr.classes [ "surface"; "host-health" ] ]
        [
          Vdom.Node.header
            ~attrs:[ Vdom.Attr.class_ "surface-header" ]
            [
              Vdom.Node.div
                [
                  Vdom.Node.p
                    ~attrs:[ Vdom.Attr.class_ "eyebrow" ]
                    [ Vdom.Node.text "Linux hosts" ];
                  Vdom.Node.h3 [ Vdom.Node.text "Host health" ];
                ];
              Ui_helpers.route_link ~class_name:"text-link"
                ~route:Route.Telemetry ~navigate
                [ Vdom.Node.text "All host details" ];
            ];
          (match metrics with
          | None -> Ui_helpers.text_panel ~kind:"loading" "Reading host health…"
          | Some (Error error) ->
              Ui_helpers.text_panel ~kind:"error" (Error.to_string_hum error)
          | Some (Ok []) ->
              Ui_helpers.text_panel ~kind:"empty" "No hosts are configured."
          | Some (Ok targets) ->
              Vdom.Node.div
                ~attrs:[ Vdom.Attr.class_ "host-health-list" ]
                (List.map targets ~f:(host_row ~navigate)));
        ];
      Ui_helpers.polling_warning
        ~has_last_good:(Option.is_some deployments)
        deployments_stale;
      (match deployments with
      | None ->
          deployment_section ~title:"Current deployments"
            ~empty:"Reading deployments…" ~entries:[] ~navigate
      | Some (Error error) ->
          Ui_helpers.text_panel ~kind:"error" (Error.to_string_hum error)
      | Some (Ok _) ->
          deployment_section ~title:"Current deployments"
            ~empty:"No deployment is currently running." ~entries:active
            ~navigate);
      (match deployments with
      | Some (Ok _) ->
          deployment_section ~title:"Previous deployments"
            ~empty:"No previous deployments have been recorded."
            ~entries:previous ~navigate
      | None | Some (Error _) -> Vdom.Node.none);
    ]
