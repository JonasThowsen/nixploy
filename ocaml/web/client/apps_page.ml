open Core
open! Bonsai_web.Cont

let health_for_application metrics key =
  List.find_map metrics ~f:(fun target ->
      List.find target.Protocol.Target_metrics.applications ~f:(fun app ->
          String.equal app.Protocol.Application_metrics.application key))

let health_label = function
  | Protocol.Health.Healthy -> ("Healthy", "status-ok")
  | Unhealthy -> ("Unhealthy", "status-danger")
  | Unavailable _ -> ("Unavailable", "status-muted")

let fact label value =
  Vdom.Node.div
    [
      Vdom.Node.dt [ Vdom.Node.text label ];
      Vdom.Node.dd [ Vdom.Node.text value ];
    ]

let render_card ~metrics ~navigate application =
  let resource_label, resource_class =
    Ui_helpers.resource_state application.Protocol.Application.resource_state
  in
  let deployment_label, deployment_class, revision =
    match application.deployment with
    | None -> ("No deployments", "status-muted", "No revision")
    | Some deployment ->
        ( Ui_helpers.deployment_state_name deployment,
          Ui_helpers.deployment_state_class deployment,
          Option.value_map deployment.commit ~default:"No revision"
            ~f:(fun commit -> Ui_helpers.short_revision commit.revision) )
  in
  let runtime = health_for_application metrics application.key in
  let runtime_label, runtime_class =
    Option.value_map runtime ~default:("Unavailable", "status-muted")
      ~f:(fun runtime ->
        health_label runtime.Protocol.Application_metrics.health)
  in
  match Route.Application_key.of_string application.key with
  | Error _ -> Vdom.Node.none
  | Ok key ->
      Ui_helpers.route_link ~class_name:"application-item"
        ~route:(Route.Application key) ~navigate
        [
          Vdom.Node.create "article"
            [
              Vdom.Node.header
                [
                  Vdom.Node.div
                    [
                      Vdom.Node.p
                        ~attrs:[ Vdom.Attr.class_ "eyebrow" ]
                        [ Vdom.Node.text application.project ];
                      Vdom.Node.h3 [ Vdom.Node.text application.key ];
                      Vdom.Node.p
                        ~attrs:[ Vdom.Attr.class_ "repository" ]
                        [ Vdom.Node.text application.repository ];
                    ];
                  Vdom.Node.span
                    ~attrs:
                      [
                        Vdom.Attr.class_ "application-arrow";
                        Vdom.Attr.create "aria-hidden" "true";
                      ]
                    [ Vdom.Node.text "→" ];
                ];
              Vdom.Node.dl
                ~attrs:[ Vdom.Attr.class_ "application-facts" ]
                [
                  fact "Target" application.target;
                  fact "Revision" revision;
                  Vdom.Node.div
                    [
                      Vdom.Node.dt [ Vdom.Node.text "Resources" ];
                      Vdom.Node.dd
                        [
                          Ui_helpers.state_badge ~class_name:resource_class
                            ~label:resource_label;
                        ];
                    ];
                  Vdom.Node.div
                    [
                      Vdom.Node.dt [ Vdom.Node.text "Latest deployment" ];
                      Vdom.Node.dd
                        [
                          Ui_helpers.state_badge ~class_name:deployment_class
                            ~label:deployment_label;
                        ];
                    ];
                  Vdom.Node.div
                    [
                      Vdom.Node.dt [ Vdom.Node.text "Runtime health" ];
                      Vdom.Node.dd
                        [
                          Ui_helpers.state_badge ~class_name:runtime_class
                            ~label:runtime_label;
                        ];
                    ];
                ];
            ];
        ]

let render ~applications ~metrics ~applications_stale ~metrics_stale ~navigate =
  let metric_values =
    match metrics with Some (Ok values) -> values | _ -> []
  in
  Vdom.Node.div
    ~attrs:[ Vdom.Attr.class_ "page apps-page" ]
    [
      Vdom.Node.header
        ~attrs:[ Vdom.Attr.class_ "page-intro" ]
        [
          Vdom.Node.div
            [
              Vdom.Node.p
                ~attrs:[ Vdom.Attr.class_ "eyebrow" ]
                [ Vdom.Node.text "Managed allowlist" ];
              Vdom.Node.h2 [ Vdom.Node.text "Recognized applications" ];
              Vdom.Node.p
                [
                  Vdom.Node.text
                    "Open an application to deploy an immutable revision, \
                     inspect logs, or manage its resources.";
                ];
            ];
          Ui_helpers.route_link ~class_name:"button button-secondary"
            ~route:Route.Telemetry ~navigate
            [ Vdom.Node.text "View telemetry" ];
        ];
      Ui_helpers.polling_warning
        ~has_last_good:(Option.is_some applications)
        applications_stale;
      Ui_helpers.polling_warning ~has_last_good:(Option.is_some metrics)
        metrics_stale;
      (match applications with
      | None ->
          Ui_helpers.text_panel ~kind:"loading"
            "Reading recognized applications…"
      | Some (Error error) ->
          Ui_helpers.text_panel ~kind:"error" (Error.to_string_hum error)
      | Some (Ok []) ->
          Ui_helpers.text_panel ~kind:"empty"
            "No applications are configured in the server-managed allowlist."
      | Some (Ok values) ->
          Vdom.Node.div
            ~attrs:[ Vdom.Attr.class_ "application-grid" ]
            (List.map values ~f:(render_card ~metrics:metric_values ~navigate)));
    ]
