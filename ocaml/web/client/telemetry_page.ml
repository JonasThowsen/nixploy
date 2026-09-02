open Core
open! Bonsai_web.Cont

let capacity_percent used total =
  match (used, total) with
  | Some used, Some total when Int64.(total > 0L) ->
      let percent = Int64.to_float used /. Int64.to_float total *. 100. in
      Some (Float.max 0. (Float.min 100. percent))
  | _ -> None

let capacity_row ~label ~value ~percent =
  Vdom.Node.div
    ~attrs:[ Vdom.Attr.class_ "capacity-row" ]
    [
      Vdom.Node.div
        [
          Vdom.Node.span [ Vdom.Node.text label ];
          Vdom.Node.strong [ Vdom.Node.text value ];
        ];
      Vdom.Node.div
        ~attrs:
          ([
             Vdom.Attr.class_ "capacity-track";
             Vdom.Attr.create "role" "progressbar";
             Vdom.Attr.create "aria-label" label;
             Vdom.Attr.create "aria-valuemin" "0";
             Vdom.Attr.create "aria-valuemax" "100";
             Vdom.Attr.create "aria-valuetext" value;
           ]
          @ Option.value_map percent ~default:[] ~f:(fun value ->
              [ Vdom.Attr.create "aria-valuenow" (sprintf "%.1f" value) ]))
        [
          Vdom.Node.span
            ~attrs:
              ([ Vdom.Attr.class_ "capacity-fill" ]
              @ Option.value_map percent ~default:[] ~f:(fun value ->
                  [ Vdom.Attr.create "style" (sprintf "width: %.1f%%" value) ])
              )
            [];
        ];
    ]

let pair_bytes used total =
  match (used, total) with
  | Some used, Some total ->
      Ui_helpers.format_bytes used ^ " / " ^ Ui_helpers.format_bytes total
  | _ -> "Unavailable"

let health = function
  | Protocol.Health.Healthy -> ("Healthy", "status-ok")
  | Unhealthy -> ("Unhealthy", "status-danger")
  | Unavailable _ -> ("Unavailable", "status-muted")

let metric label value =
  Vdom.Node.div
    [
      Vdom.Node.dt [ Vdom.Node.text label ];
      Vdom.Node.dd [ Vdom.Node.text value ];
    ]

let application_row ~navigate app =
  let health_label, health_class =
    health app.Protocol.Application_metrics.health
  in
  let name =
    match Route.Application_key.of_string app.application with
    | Ok key ->
        Ui_helpers.route_link ~route:(Route.Application key) ~navigate
          [ Vdom.Node.strong [ Vdom.Node.text app.application ] ]
    | Error _ -> Vdom.Node.strong [ Vdom.Node.text app.application ]
  in
  Vdom.Node.li ~key:app.application
    [
      Vdom.Node.div
        ~attrs:[ Vdom.Attr.class_ "telemetry-app-name" ]
        [
          name;
          Ui_helpers.state_badge ~class_name:health_class ~label:health_label;
        ];
      Vdom.Node.dl
        [
          metric "CPU" (Ui_helpers.format_percent app.cpu_percent);
          metric "Memory"
            (Option.value_map app.memory_used_bytes ~default:"Unavailable"
               ~f:Ui_helpers.format_bytes);
          metric "Host memory"
            (Ui_helpers.format_percent app.memory_host_percent);
          metric "Uptime" (Ui_helpers.format_uptime app.uptime_seconds);
        ];
      (match app.error with
      | None -> Vdom.Node.none
      | Some error ->
          Vdom.Node.p
            ~attrs:[ Vdom.Attr.class_ "inline-error" ]
            [ Vdom.Node.text error ]);
    ]

let target_card ~navigate target =
  let memory_percent =
    capacity_percent target.Protocol.Target_metrics.memory_used_bytes
      target.memory_total_bytes
  in
  let filesystem_percent =
    capacity_percent target.filesystem_used_bytes target.filesystem_total_bytes
  in
  let cpu_percent =
    Option.map target.cpu_percent ~f:(fun value ->
        Float.max 0. (Float.min 100. value))
  in
  Vdom.Node.create "article"
    ~attrs:[ Vdom.Attr.class_ "telemetry-target surface" ]
    [
      Vdom.Node.header
        ~attrs:[ Vdom.Attr.class_ "surface-header" ]
        [
          Vdom.Node.div
            [
              Vdom.Node.p
                ~attrs:[ Vdom.Attr.class_ "eyebrow" ]
                [ Vdom.Node.text "Target" ];
              Vdom.Node.h3 [ Vdom.Node.text target.target ];
              Vdom.Node.code [ Vdom.Node.text target.host ];
            ];
          (match target.error with
          | None ->
              Ui_helpers.state_badge ~class_name:"status-ok" ~label:"Observed"
          | Some _ ->
              Ui_helpers.state_badge ~class_name:"status-danger"
                ~label:"Observation error");
        ];
      (match target.error with
      | None -> Vdom.Node.none
      | Some error -> Ui_helpers.text_panel ~kind:"error" error);
      Vdom.Node.div
        ~attrs:[ Vdom.Attr.class_ "capacity-list numeric" ]
        [
          capacity_row ~label:"CPU"
            ~value:(Ui_helpers.format_percent target.cpu_percent)
            ~percent:cpu_percent;
          capacity_row ~label:"Memory"
            ~value:
              (pair_bytes target.memory_used_bytes target.memory_total_bytes)
            ~percent:memory_percent;
          capacity_row ~label:"Filesystem"
            ~value:
              (pair_bytes target.filesystem_used_bytes
                 target.filesystem_total_bytes)
            ~percent:filesystem_percent;
        ];
      Vdom.Node.dl
        ~attrs:[ Vdom.Attr.class_ "host-facts numeric" ]
        [
          metric "Load averages"
            (match (target.load_1, target.load_5, target.load_15) with
            | Some one, Some five, Some fifteen ->
                sprintf "%.2f / %.2f / %.2f" one five fifteen
            | _ -> "Unavailable");
          metric "Host uptime" (Ui_helpers.format_uptime target.uptime_seconds);
          metric "Observed" (Ui_helpers.format_time target.observed_at_ms);
          metric "Applications"
            (Int.to_string (List.length target.applications));
        ];
      Vdom.Node.section
        ~attrs:[ Vdom.Attr.class_ "host-applications" ]
        [
          Vdom.Node.h4 [ Vdom.Node.text "Applications on this host" ];
          (match target.applications with
          | [] ->
              Ui_helpers.text_panel ~kind:"empty"
                "No recognized application runtime was observed on this host."
          | applications ->
              Vdom.Node.ul
                (List.map applications ~f:(application_row ~navigate)));
        ];
    ]

let render ~metrics ~stale ~navigate =
  Vdom.Node.div
    ~attrs:[ Vdom.Attr.class_ "page telemetry-page" ]
    [
      Vdom.Node.header
        ~attrs:[ Vdom.Attr.class_ "page-intro" ]
        [
          Vdom.Node.div
            [
              Vdom.Node.p
                ~attrs:[ Vdom.Attr.class_ "eyebrow" ]
                [ Vdom.Node.text "Remote Linux hosts" ];
              Vdom.Node.h2 [ Vdom.Node.text "Host health" ];
              Vdom.Node.p
                [
                  Vdom.Node.text
                    "Current CPU, memory, filesystem, and runtime health for \
                     each remote Linux host.";
                ];
            ];
          Ui_helpers.route_link ~class_name:"button button-secondary"
            ~route:Route.Apps ~navigate
            [ Vdom.Node.text "Open applications" ];
        ];
      Ui_helpers.polling_warning ~has_last_good:(Option.is_some metrics) stale;
      (match metrics with
      | None ->
          Ui_helpers.text_panel ~kind:"loading" "Reading target telemetry…"
      | Some (Error error) ->
          Ui_helpers.text_panel ~kind:"error" (Error.to_string_hum error)
      | Some (Ok []) ->
          Ui_helpers.text_panel ~kind:"empty"
            "No target telemetry is available."
      | Some (Ok targets) ->
          Vdom.Node.div
            ~attrs:[ Vdom.Attr.class_ "telemetry-grid" ]
            (List.map targets ~f:(target_card ~navigate)));
    ]
