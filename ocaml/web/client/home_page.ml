open Core
open! Bonsai_web.Cont

let count_resource applications state =
  List.count applications ~f:(fun application ->
      [%equal: Protocol.Resource_state.t]
        application.Protocol.Application.resource_state state)

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
  | Failed | Cancelled -> true
  | Requested | Running | Succeeded -> false

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

let route_for_key key =
  Route.Application_key.of_string key
  |> Or_error.ok
  |> Option.map ~f:(fun key -> Route.Application key)

let target_identity target =
  let applications =
    List.map target.Protocol.Target_metrics.applications ~f:(fun application ->
        application.Protocol.Application_metrics.application)
    |> List.dedup_and_sort ~compare:String.compare
  in
  match applications with
  | [] -> target.target
  | applications ->
      sprintf "%s · %s" (String.concat applications ~sep:", ") target.target

let target_host_label target =
  if String.equal target.Protocol.Target_metrics.host "unavailable" then
    "Target configuration unavailable"
  else target.host

let attention_list ~navigate applications =
  let needing_attention =
    List.filter applications ~f:(fun application ->
        match application.Protocol.Application.resource_state with
        | Unknown | Absent -> true
        | Present -> false)
  in
  match needing_attention with
  | [] ->
      Ui_helpers.text_panel ~kind:"empty"
        "No resources are currently reported as Unknown or Absent."
  | values ->
      Vdom.Node.ul
        ~attrs:[ Vdom.Attr.class_ "attention-list" ]
        (List.map values ~f:(fun application ->
             let label, class_name =
               Ui_helpers.resource_state
                 application.Protocol.Application.resource_state
             in
             Vdom.Node.li ~key:application.key
               [
                 (match route_for_key application.key with
                 | None -> Vdom.Node.strong [ Vdom.Node.text application.key ]
                 | Some route ->
                     Ui_helpers.route_link ~route ~navigate
                       [ Vdom.Node.strong [ Vdom.Node.text application.key ] ]);
                 Vdom.Node.span
                   [
                     Vdom.Node.text
                       (application.project ^ " · " ^ application.target);
                   ];
                 Ui_helpers.state_badge ~class_name ~label;
               ]))

let render ~applications ~deployments ~metrics ~applications_stale
    ~deployments_stale ~metrics_stale ~connection_label ~navigate =
  let values = function
    | Some (Ok values) -> values
    | None | Some (Error _) -> []
  in
  let application_values = values applications in
  let deployment_values = values deployments in
  let metric_values = values metrics in
  let app_count = List.length application_values in
  let unknown = count_resource application_values Unknown in
  let absent = count_resource application_values Absent in
  let active =
    List.count deployment_values ~f:(fun recent ->
        deployment_active recent.Protocol.Recent_deployment.deployment)
  in
  let failures =
    List.count deployment_values ~f:(fun recent ->
        deployment_failed recent.Protocol.Recent_deployment.deployment)
  in
  let healthy, unhealthy, unavailable = health_counts metric_values in
  let applications_summary =
    match applications with
    | None -> ("Awaiting data", "Reading the managed allowlist", "tone-neutral")
    | Some (Error _) ->
        ("Unavailable", "Could not read recognized applications", "tone-danger")
    | Some (Ok _) ->
        ( Int.to_string app_count,
          sprintf "%d unknown · %d absent" unknown absent,
          if unknown + absent = 0 then "tone-neutral" else "tone-working" )
  in
  let runtime_summary =
    match metrics with
    | None -> ("Awaiting data", "Checking application runtimes", "tone-neutral")
    | Some (Error _) ->
        ("Unavailable", "Runtime health check failed", "tone-danger")
    | Some (Ok _) ->
        ( sprintf "%d healthy" healthy,
          sprintf "%d unhealthy · %d unavailable" unhealthy unavailable,
          if unhealthy = 0 && unavailable = 0 then "tone-ok"
          else if unhealthy > 0 then "tone-danger"
          else "tone-working" )
  in
  let deployment_summary =
    match deployments with
    | None ->
        ("Awaiting data", "Reading recent deployment history", "tone-neutral")
    | Some (Error _) ->
        ("Unavailable", "Could not read deployment history", "tone-danger")
    | Some (Ok _) ->
        ( Int.to_string active,
          sprintf "%d recent failed, cancelled, or interrupted" failures,
          if failures > 0 then "tone-danger"
          else if active > 0 then "tone-working"
          else "tone-neutral" )
  in
  let target_errors =
    List.count metric_values ~f:(fun target ->
        Option.is_some target.Protocol.Target_metrics.error)
  in
  let target_check_class, target_check_label =
    match metrics with
    | None -> ("status-warning", "Checks pending")
    | Some (Error _) -> ("status-danger", "Checks unavailable")
    | Some (Ok []) -> ("status-muted", "No checks configured")
    | Some (Ok _) when target_errors = 0 -> ("status-ok", "All checks passed")
    | Some (Ok _) ->
        ( "status-danger",
          sprintf "%d check%s failed" target_errors
            (if target_errors = 1 then "" else "s") )
  in
  let activity = List.take deployment_values 8 in
  let body_state =
    match applications with
    | None ->
        Ui_helpers.text_panel ~kind:"loading" "Reading control-plane state…"
    | Some (Error error) ->
        Ui_helpers.text_panel ~kind:"error" (Error.to_string_hum error)
    | Some (Ok _) -> Vdom.Node.none
  in
  Vdom.Node.div
    ~attrs:[ Vdom.Attr.class_ "page home-page" ]
    [
      Vdom.Node.header
        ~attrs:[ Vdom.Attr.class_ "page-intro" ]
        [
          Vdom.Node.div
            [
              Vdom.Node.p
                ~attrs:[ Vdom.Attr.class_ "eyebrow" ]
                [ Vdom.Node.text "Operational overview" ];
              Vdom.Node.h2 [ Vdom.Node.text "What needs attention now" ];
              Vdom.Node.p
                [
                  Vdom.Node.text
                    "Connection, runtime health, resource presence, and \
                     deployment history are shown as separate signals.";
                ];
            ];
          Vdom.Node.div
            ~attrs:[ Vdom.Attr.class_ "intro-actions" ]
            [
              Ui_helpers.route_link ~class_name:"button button-primary"
                ~route:Route.Apps ~navigate
                [ Vdom.Node.text "View applications" ];
              Ui_helpers.route_link ~class_name:"button button-secondary"
                ~route:Route.Telemetry ~navigate
                [ Vdom.Node.text "Open telemetry" ];
            ];
        ];
      body_state;
      Ui_helpers.polling_warning
        ~has_last_good:(Option.is_some applications)
        applications_stale;
      Vdom.Node.section
        ~attrs:[ Vdom.Attr.create "aria-labelledby" "overview-signals" ]
        [
          Vdom.Node.h3
            ~attrs:
              [
                Vdom.Attr.id "overview-signals";
                Vdom.Attr.class_ "section-title";
              ]
            [ Vdom.Node.text "Current signals" ];
          Vdom.Node.div
            ~attrs:[ Vdom.Attr.class_ "summary-grid" ]
            [
              stat_card ~label:"RPC connection" ~value:connection_label
                ~detail:"Browser connection to the control plane"
                ~tone:
                  (if String.equal connection_label "Connected" then "tone-ok"
                   else if String.equal connection_label "Connection issue" then
                     "tone-danger"
                   else "tone-working");
              (let value, detail, tone = applications_summary in
               stat_card ~label:"Recognized applications" ~value ~detail ~tone);
              (let value, detail, tone = runtime_summary in
               stat_card ~label:"Live application health" ~value ~detail ~tone);
              (let value, detail, tone = deployment_summary in
               stat_card ~label:"Active deployments" ~value ~detail ~tone);
            ];
        ];
      Vdom.Node.div
        ~attrs:[ Vdom.Attr.class_ "home-columns" ]
        [
          Vdom.Node.section
            ~attrs:
              [
                Vdom.Attr.class_ "surface";
                Vdom.Attr.create "aria-labelledby" "resource-attention";
              ]
            [
              Vdom.Node.header
                ~attrs:[ Vdom.Attr.class_ "surface-header" ]
                [
                  Vdom.Node.div
                    [
                      Vdom.Node.p
                        ~attrs:[ Vdom.Attr.class_ "eyebrow" ]
                        [ Vdom.Node.text "Resource presence" ];
                      Vdom.Node.h3
                        ~attrs:[ Vdom.Attr.id "resource-attention" ]
                        [ Vdom.Node.text "Needs attention" ];
                    ];
                  Ui_helpers.state_badge
                    ~class_name:
                      (if unknown + absent = 0 then "status-ok"
                       else "status-warning")
                    ~label:(sprintf "%d items" (unknown + absent));
                ];
              (match applications with
              | None ->
                  Ui_helpers.text_panel ~kind:"loading"
                    "Reading resource presence…"
              | Some (Error error) ->
                  Ui_helpers.text_panel ~kind:"error"
                    (Error.to_string_hum error)
              | Some (Ok _) -> attention_list ~navigate application_values);
            ];
          Vdom.Node.section
            ~attrs:
              [
                Vdom.Attr.class_ "surface";
                Vdom.Attr.create "aria-labelledby" "observation-state";
                Vdom.Attr.create "aria-live" "polite";
                Vdom.Attr.create "aria-atomic" "false";
              ]
            [
              Vdom.Node.header
                ~attrs:[ Vdom.Attr.class_ "surface-header" ]
                [
                  Vdom.Node.div
                    [
                      Vdom.Node.p
                        ~attrs:[ Vdom.Attr.class_ "eyebrow" ]
                        [ Vdom.Node.text "Live infrastructure checks" ];
                      Vdom.Node.h3
                        ~attrs:[ Vdom.Attr.id "observation-state" ]
                        [ Vdom.Node.text "Deployment machines" ];
                      Vdom.Node.p
                        [
                          Vdom.Node.text
                            "Nixploy checks each configured target over SSH \
                             for host capacity, container state, and health.";
                        ];
                    ];
                  Ui_helpers.state_badge ~class_name:target_check_class
                    ~label:target_check_label;
                ];
              Ui_helpers.polling_warning ~has_last_good:(Option.is_some metrics)
                metrics_stale;
              (match metrics with
              | None ->
                  Ui_helpers.text_panel ~kind:"loading"
                    "Checking deployment machines…"
              | Some (Error error) ->
                  Ui_helpers.text_panel ~kind:"error"
                    (Error.to_string_hum error)
              | Some (Ok []) ->
                  Ui_helpers.text_panel ~kind:"empty"
                    "No deployment machine checks are available."
              | Some (Ok targets) ->
                  Vdom.Node.ul
                    ~attrs:[ Vdom.Attr.class_ "target-summary-list" ]
                    (List.map targets ~f:(fun target ->
                         Vdom.Node.li
                           [
                             Vdom.Node.div
                               [
                                 Vdom.Node.strong
                                   [ Vdom.Node.text (target_identity target) ];
                                 Vdom.Node.code
                                   [ Vdom.Node.text (target_host_label target) ];
                               ];
                             (match target.error with
                             | None ->
                                 Ui_helpers.state_badge ~class_name:"status-ok"
                                   ~label:"Check passed"
                             | Some _ ->
                                 Ui_helpers.state_badge
                                   ~class_name:"status-danger"
                                   ~label:"Check failed");
                             (match target.error with
                             | None -> Vdom.Node.none
                             | Some error ->
                                 Vdom.Node.p
                                   ~attrs:
                                     [ Vdom.Attr.class_ "target-summary-error" ]
                                   [
                                     Vdom.Node.text ("Why it failed: " ^ error);
                                   ]);
                           ])));
              Ui_helpers.route_link ~class_name:"text-link"
                ~route:Route.Telemetry ~navigate
                [ Vdom.Node.text "View detailed telemetry" ];
            ];
        ];
      Vdom.Node.section
        ~attrs:
          [
            Vdom.Attr.class_ "surface";
            Vdom.Attr.create "aria-labelledby" "recent-activity";
          ]
        [
          Vdom.Node.header
            ~attrs:[ Vdom.Attr.class_ "surface-header" ]
            [
              Vdom.Node.div
                [
                  Vdom.Node.p
                    ~attrs:[ Vdom.Attr.class_ "eyebrow" ]
                    [ Vdom.Node.text "Deployment history" ];
                  Vdom.Node.h3
                    ~attrs:[ Vdom.Attr.id "recent-activity" ]
                    [ Vdom.Node.text "Recent activity" ];
                ];
            ];
          Ui_helpers.polling_warning
            ~has_last_good:(Option.is_some deployments)
            deployments_stale;
          (match deployments with
          | None ->
              Ui_helpers.text_panel ~kind:"loading"
                "Reading deployment history…"
          | Some (Error error) ->
              Ui_helpers.text_panel ~kind:"error" (Error.to_string_hum error)
          | Some (Ok []) ->
              Ui_helpers.text_panel ~kind:"empty"
                "No deployments have been recorded."
          | Some (Ok _) ->
              Vdom.Node.ol
                ~attrs:[ Vdom.Attr.class_ "deployment-list" ]
                (List.map activity ~f:(Ui_helpers.deployment_row ~navigate)));
        ];
    ]
