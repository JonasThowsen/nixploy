open Core
open! Bonsai_web.Cont
module Deploy_state = Nixploy_web_client_state.Deploy_state

type application_state =
  | Loading
  | Failed of Error.t
  | Missing
  | Ready of Protocol.Application.t

let primary_action_id = "application-primary-action"
let focus_primary_action = Browser_navigation.focus primary_action_id

let managed_deployment_unavailable =
  "Managed deployment is unavailable until control-plane source custody provides a verified full revision."

let fact label value =
  Vdom.Node.div
    [
      Vdom.Node.dt [ Vdom.Node.text label ];
      Vdom.Node.dd [ Vdom.Node.text value ];
    ]

let deployment_action ~capability_grant ~application ~deployment ~deploy_state
    ~cancel_confirmation ~dispatch_cancel ~set_cancel_confirmation ~set_notice =
  let deploy_busy = Deploy_state.is_busy deploy_state in
  match deployment with
  | Some deployment
    when Option.is_some deployment.Protocol.Deployment.cancel_requested_at_ms
         &&
         match deployment.state with
         | Requested | Running -> true
         | _ -> false ->
      Ui_helpers.button ~id:primary_action_id ~disabled:true
        ~label:"Cancelling deployment…" ~on_click:Effect.Ignore ()
  | Some deployment when deployment.can_cancel ->
      if Option.equal String.equal cancel_confirmation (Some deployment.id) then
        let confirm_cancel =
          let%bind.Effect owner =
            Browser_navigation.application_owner
              application.Protocol.Application.key
          in
          let%bind.Effect response =
            dispatch_cancel
              {
                Protocol.Cancel_deployment_v1.V1.Query.capability_grant;
                application = application.Protocol.Application.key;
                operation_id = deployment.id;
              }
          in
          if not (Browser_navigation.is_current_owner owner) then Effect.Ignore
          else
            let notice =
              match response with
              | Error error -> "Cancel RPC failed: " ^ Error.to_string_hum error
              | Ok (Error error) ->
                  "Cancellation rejected: " ^ Error.to_string_hum error
              | Ok (Ok ()) ->
                  "Cancellation requested; cleanup may continue briefly."
            in
            Effect.Many
              [
                set_cancel_confirmation None;
                set_notice notice;
                focus_primary_action;
              ]
        in
        Vdom.Node.div
          ~attrs:[ Vdom.Attr.class_ "cancel-confirmation" ]
          [
            Vdom.Node.p
              [
                Vdom.Node.text
                  ("Cancel deployment " ^ deployment.id
                 ^ "? Cleanup may continue briefly.");
              ];
            Vdom.Node.div
              ~attrs:[ Vdom.Attr.class_ "button-row" ]
              [
                Ui_helpers.button ~autofocus:true ~disabled:deploy_busy
                  ~label:"Keep running"
                  ~on_click:
                    (Effect.Many
                       [ set_cancel_confirmation None; focus_primary_action ])
                  ();
                Ui_helpers.button ~kind:"danger" ~disabled:deploy_busy
                  ~label:"Confirm cancellation" ~on_click:confirm_cancel ();
              ];
          ]
      else
        Ui_helpers.button ~id:primary_action_id ~kind:"danger-outline"
          ~disabled:deploy_busy ~label:"Cancel deployment"
          ~on_click:(set_cancel_confirmation (Some deployment.id))
          ()
  | _ ->
      Vdom.Node.div
        [
          Vdom.Node.p ~attrs:[ Vdom.Attr.class_ "inline-error" ]
            [ Vdom.Node.text managed_deployment_unavailable ];
          Ui_helpers.button ~id:primary_action_id ~kind:"primary" ~disabled:true
            ~label:"Managed deployment unavailable" ~on_click:Effect.Ignore ();
        ]

let occurrences text pattern =
  if String.is_empty pattern then 0
  else
    let rec count position total =
      match String.substr_index text ~pos:position ~pattern with
      | None -> total
      | Some index -> count (index + String.length pattern) (total + 1)
    in
    count 0 0

let highlighted_line ~query ~current ~first_index line =
  if String.is_empty query then ([ Vdom.Node.text line ], 0)
  else
    let rec build position match_index nodes =
      match String.substr_index line ~pos:position ~pattern:query with
      | None ->
          let suffix = String.drop_prefix line position in
          (List.rev (Vdom.Node.text suffix :: nodes), match_index - first_index)
      | Some index ->
          let before = String.slice line position index in
          let mark =
            Vdom.Node.create "mark"
              ~attrs:
                ([
                   Vdom.Attr.class_
                     (if Int.equal match_index current then "active-match"
                      else "");
                 ]
                @
                if Int.equal match_index current then
                  [ Vdom.Attr.id "active-log-match" ]
                else [])
              [ Vdom.Node.text query ]
          in
          build
            (index + String.length query)
            (match_index + 1)
            (mark :: Vdom.Node.text before :: nodes)
    in
    build 0 first_index []

let log_viewer ~key ~search ~current_match ~follow ~paused_snapshot ~set_search
    ~set_current_match ~set_follow ~set_paused_snapshot ~refresh response =
  let for_application snapshot =
    String.equal snapshot.Protocol.Log_snapshot.application key
  in
  let live_snapshot =
    match response with
    | Some (Ok (Some snapshot)) when for_application snapshot -> Some snapshot
    | _ -> None
  in
  let paused_snapshot = Option.filter paused_snapshot ~f:for_application in
  let snapshot =
    if follow then live_snapshot
    else Option.first_some paused_snapshot live_snapshot
  in
  match snapshot with
  | None -> (
      match response with
      | Some (Error error) ->
          Ui_helpers.text_panel ~kind:"error" (Error.to_string_hum error)
      | Some (Ok None) ->
          Ui_helpers.text_panel ~kind:"empty"
            "No identified running container is available for logs."
      | None | Some (Ok (Some _)) ->
          Ui_helpers.text_panel ~kind:"loading"
            "Reading recent application logs…")
  | Some snapshot ->
      let total =
        List.sum
          (module Int)
          snapshot.lines
          ~f:(fun line -> occurrences line.Protocol.Log_line.text search)
      in
      let current_match =
        if total = 0 then 0 else Int.min current_match (total - 1)
      in
      let _, line_nodes =
        List.fold snapshot.lines ~init:(0, [])
          ~f:(fun (first_index, nodes) line ->
            let highlighted, count =
              highlighted_line ~query:search ~current:current_match ~first_index
                line.Protocol.Log_line.text
            in
            let node =
              Vdom.Node.div
                ~attrs:[ Vdom.Attr.class_ "log-line" ]
                ((match line.timestamp with
                   | None -> []
                   | Some timestamp ->
                       [ Vdom.Node.create "time" [ Vdom.Node.text timestamp ] ])
                @ [ Vdom.Node.code highlighted ])
            in
            (first_index + count, node :: nodes))
      in
      let toggle_follow =
        if follow then
          Effect.Many [ set_paused_snapshot (Some snapshot); set_follow false ]
        else Effect.Many [ set_paused_snapshot None; set_follow true ]
      in
      Vdom.Node.div
        [
          Vdom.Node.div
            ~attrs:[ Vdom.Attr.class_ "log-toolbar" ]
            [
              Vdom.Node.label
                [
                  Vdom.Node.span [ Vdom.Node.text "Search logs" ];
                  Vdom.Node.input
                    ~attrs:
                      [
                        Vdom.Attr.create "type" "search";
                        Vdom.Attr.value search;
                        Vdom.Attr.placeholder "Find text";
                        Vdom.Attr.on_input (fun _ value ->
                            Effect.Many
                              [ set_search value; set_current_match 0 ]);
                      ]
                    ();
                ];
              Vdom.Node.div
                ~attrs:[ Vdom.Attr.class_ "log-controls" ]
                [
                  Vdom.Node.span [ Vdom.Node.text (sprintf "%d matches" total) ];
                  Ui_helpers.button ~label:"Previous" ~disabled:(total = 0)
                    ~on_click:
                      (set_current_match
                         (if total = 0 then 0
                          else (current_match - 1 + total) mod total))
                    ();
                  Ui_helpers.button ~label:"Next" ~disabled:(total = 0)
                    ~on_click:
                      (set_current_match
                         (if total = 0 then 0 else (current_match + 1) mod total))
                    ();
                  Ui_helpers.button
                    ~label:(if follow then "Pause" else "Resume")
                    ~on_click:toggle_follow ();
                  Ui_helpers.button ~label:"Refresh" ~on_click:refresh ();
                ];
            ];
          Vdom.Node.div
            ~attrs:[ Vdom.Attr.class_ "log-meta numeric" ]
            [
              Vdom.Node.span [ Vdom.Node.text snapshot.container_name ];
              Vdom.Node.span
                [
                  Vdom.Node.text
                    (Ui_helpers.format_time snapshot.observed_at_ms);
                ];
              Vdom.Node.span
                [ Vdom.Node.text (if follow then "Following" else "Paused") ];
              (if snapshot.truncated then
                 Vdom.Node.span [ Vdom.Node.text "Truncated" ]
               else Vdom.Node.none);
            ];
          Vdom.Node.div
            ~attrs:
              [
                Vdom.Attr.class_ "log-output";
                Vdom.Attr.create "role" "log";
                Vdom.Attr.create "aria-label" (key ^ " recent logs");
              ]
            (List.rev line_nodes);
        ]

let application_metrics ~key ~navigate metrics =
  match metrics with
  | None -> Ui_helpers.text_panel ~kind:"loading" "Reading runtime metrics…"
  | Some (Error error) ->
      Ui_helpers.text_panel ~kind:"error" (Error.to_string_hum error)
  | Some (Ok targets) -> (
      match
        List.find_map targets ~f:(fun target ->
            List.find target.Protocol.Target_metrics.applications ~f:(fun app ->
                String.equal app.Protocol.Application_metrics.application key)
            |> Option.map ~f:(fun app -> (target, app)))
      with
      | None ->
          Ui_helpers.text_panel ~kind:"empty"
            "No current runtime observation is available for this application."
      | Some (target, app) ->
          let health_label, health_class =
            match app.Protocol.Application_metrics.health with
            | Healthy -> ("Healthy", "status-ok")
            | Unhealthy -> ("Unhealthy", "status-danger")
            | Unavailable _ -> ("Unavailable", "status-muted")
          in
          Vdom.Node.div
            [
              Vdom.Node.div
                ~attrs:[ Vdom.Attr.class_ "runtime-heading" ]
                [
                  Vdom.Node.div
                    [
                      Vdom.Node.strong [ Vdom.Node.text target.target ];
                      Vdom.Node.code [ Vdom.Node.text target.host ];
                    ];
                  Ui_helpers.state_badge ~class_name:health_class
                    ~label:health_label;
                ];
              Vdom.Node.dl
                ~attrs:[ Vdom.Attr.class_ "runtime-facts numeric" ]
                [
                  fact "CPU" (Ui_helpers.format_percent app.cpu_percent);
                  fact "Memory"
                    (Option.value_map app.memory_used_bytes
                       ~default:"Unavailable" ~f:Ui_helpers.format_bytes);
                  fact "Host memory"
                    (Ui_helpers.format_percent app.memory_host_percent);
                  fact "Uptime" (Ui_helpers.format_uptime app.uptime_seconds);
                ];
              (match app.error with
              | None -> Vdom.Node.none
              | Some error ->
                  Vdom.Node.p
                    ~attrs:[ Vdom.Attr.class_ "inline-error" ]
                    [ Vdom.Node.text error ]);
              Ui_helpers.route_link ~class_name:"text-link"
                ~route:Route.Telemetry ~navigate
                [ Vdom.Node.text "View host health" ];
            ])

let deployment_list ~empty entries =
  if List.is_empty entries then Ui_helpers.text_panel ~kind:"empty" empty
  else
    Vdom.Node.ol
      ~attrs:[ Vdom.Attr.class_ "deployment-list" ]
      (List.map entries
         ~f:
           (Ui_helpers.deployment_row ~link_application:false
              ~navigate:(fun _ -> Effect.Ignore)))

let ready_page ~key ~application ~deployments ~logs ~metrics ~deployments_stale
    ~logs_stale ~metrics_stale ~deploy_state ~cancel_confirmation
    ~capability_grant ~dispatch_cancel ~set_deploy_state:_ ~set_cancel_confirmation
    ~set_notice
    ~search ~current_match ~follow ~paused_snapshot ~set_search
    ~set_current_match ~set_follow ~set_paused_snapshot ~refresh_logs ~navigate
    =
  let deployment = application.Protocol.Application.deployment in
  let resource_label, resource_class =
    Ui_helpers.resource_state application.resource_state
  in
  let revision, subject, stage, message =
    match deployment with
    | None ->
        ( "No revision",
          "No deployment recorded",
          "Managed deployment unavailable",
          managed_deployment_unavailable )
    | Some deployment ->
        let revision, subject = Ui_helpers.commit_summary deployment.commit in
        ( revision,
          subject,
          deployment.stage,
          Option.value deployment.error ~default:deployment.message )
  in
  let action =
    deployment_action ~capability_grant ~application ~deployment ~deploy_state
      ~cancel_confirmation ~dispatch_cancel ~set_cancel_confirmation ~set_notice
  in
  let deployment_entries =
    match deployments with
    | Some (Ok entries) -> entries
    | None | Some (Error _) -> []
  in
  let active_entries =
    List.filter deployment_entries ~f:(fun entry ->
        Ui_helpers.deployment_is_active
          (Some entry.Protocol.Recent_deployment.deployment))
  in
  let previous_entries =
    List.filter deployment_entries ~f:(fun entry ->
        not
          (Ui_helpers.deployment_is_active
             (Some entry.Protocol.Recent_deployment.deployment)))
  in
  Vdom.Node.div
    ~attrs:[ Vdom.Attr.class_ "page application-page" ]
    [
      Vdom.Node.header
        ~attrs:[ Vdom.Attr.class_ "page-intro application-intro" ]
        [
          Vdom.Node.div
            [
              Vdom.Node.p
                ~attrs:[ Vdom.Attr.class_ "eyebrow" ]
                [ Vdom.Node.text application.project ];
              Vdom.Node.h2 [ Vdom.Node.text key ];
              Vdom.Node.p
                ~attrs:[ Vdom.Attr.class_ "repository" ]
                [ Vdom.Node.text application.repository ];
            ];
          Vdom.Node.div
            ~attrs:[ Vdom.Attr.class_ "hero-statuses" ]
            [
              Ui_helpers.state_badge ~class_name:resource_class
                ~label:("Resources " ^ resource_label);
              (match deployment with
              | None ->
                  Ui_helpers.state_badge ~class_name:"status-muted"
                    ~label:"No deployment"
              | Some deployment ->
                  Ui_helpers.state_badge
                    ~class_name:(Ui_helpers.deployment_state_class deployment)
                    ~label:(Ui_helpers.deployment_state_name deployment));
            ];
        ];
      Vdom.Node.section
        ~attrs:[ Vdom.Attr.classes [ "surface"; "deployment-control" ] ]
        [
          Vdom.Node.div
            ~attrs:[ Vdom.Attr.class_ "surface-header" ]
            [
              Vdom.Node.div
                [
                  Vdom.Node.p
                    ~attrs:[ Vdom.Attr.class_ "eyebrow" ]
                    [ Vdom.Node.text "Deployment" ];
                  Vdom.Node.h3 [ Vdom.Node.text subject ];
                  Vdom.Node.p [ Vdom.Node.text message ];
                ];
            ];
          Vdom.Node.dl
            ~attrs:[ Vdom.Attr.class_ "application-summary numeric" ]
            [
              fact "Target" application.target;
              fact "Revision" revision;
              fact "Stage" stage;
            ];
          action;
        ];
      Vdom.Node.div
        ~attrs:[ Vdom.Attr.class_ "application-columns" ]
        [
          Vdom.Node.section
            ~attrs:[ Vdom.Attr.class_ "surface" ]
            [
              Vdom.Node.header
                ~attrs:[ Vdom.Attr.class_ "surface-header" ]
                [ Vdom.Node.h3 [ Vdom.Node.text "Runtime health" ] ];
              Ui_helpers.polling_warning ~has_last_good:(Option.is_some metrics)
                metrics_stale;
              application_metrics ~key ~navigate metrics;
            ];
          Vdom.Node.section
            ~attrs:[ Vdom.Attr.class_ "surface" ]
            [
              Vdom.Node.header
                ~attrs:[ Vdom.Attr.class_ "surface-header" ]
                [ Vdom.Node.h3 [ Vdom.Node.text "Current deployments" ] ];
              Ui_helpers.polling_warning
                ~has_last_good:(Option.is_some deployments)
                deployments_stale;
              (match deployments with
              | None ->
                  Ui_helpers.text_panel ~kind:"loading" "Reading deployments…"
              | Some (Error error) ->
                  Ui_helpers.text_panel ~kind:"error"
                    (Error.to_string_hum error)
              | Some (Ok _) ->
                  deployment_list ~empty:"No deployment is currently running."
                    active_entries);
            ];
        ];
      Vdom.Node.section
        ~attrs:[ Vdom.Attr.class_ "surface" ]
        [
          Vdom.Node.header
            ~attrs:[ Vdom.Attr.class_ "surface-header" ]
            [ Vdom.Node.h3 [ Vdom.Node.text "Previous deployments" ] ];
          (match deployments with
          | None ->
              Ui_helpers.text_panel ~kind:"loading"
                "Reading deployment history…"
          | Some (Error error) ->
              Ui_helpers.text_panel ~kind:"error" (Error.to_string_hum error)
          | Some (Ok _) ->
              deployment_list
                ~empty:"No previous deployments have been recorded."
                previous_entries);
        ];
      Vdom.Node.section
        ~attrs:
          [
            Vdom.Attr.classes [ "surface"; "logs-surface" ];
            Vdom.Attr.create "aria-labelledby" "logs-title";
          ]
        [
          Vdom.Node.header
            ~attrs:[ Vdom.Attr.class_ "surface-header" ]
            [
              Vdom.Node.h3
                ~attrs:[ Vdom.Attr.id "logs-title" ]
                [ Vdom.Node.text "Application logs" ];
            ];
          Ui_helpers.polling_warning ~has_last_good:(Option.is_some logs)
            logs_stale;
          log_viewer ~key ~search ~current_match ~follow ~paused_snapshot
            ~set_search ~set_current_match ~set_follow ~set_paused_snapshot
            ~refresh:refresh_logs logs;
        ];
    ]

let render ~key ~application_state ~deployments ~logs ~metrics
    ~deployments_stale ~logs_stale ~metrics_stale ~deploy_state
    ~cancel_confirmation ~search ~current_match ~follow ~paused_snapshot
    ~capability_grant ~dispatch_cancel ~set_deploy_state:_ ~set_cancel_confirmation
    ~set_notice
    ~set_search ~set_current_match ~set_follow ~set_paused_snapshot
    ~refresh_logs ~navigate =
  match application_state with
  | Loading ->
      Vdom.Node.div
        ~attrs:[ Vdom.Attr.class_ "page" ]
        [
          Ui_helpers.text_panel ~kind:"loading"
            ("Loading application " ^ key ^ "…");
        ]
  | Failed error ->
      Vdom.Node.div
        ~attrs:[ Vdom.Attr.class_ "page" ]
        [ Ui_helpers.text_panel ~kind:"error" (Error.to_string_hum error) ]
  | Missing ->
      Vdom.Node.div
        ~attrs:[ Vdom.Attr.class_ "page not-found-page" ]
        [
          Vdom.Node.p
            ~attrs:[ Vdom.Attr.class_ "eyebrow" ]
            [ Vdom.Node.text "Application not found" ];
          Vdom.Node.h2 [ Vdom.Node.text key ];
          Vdom.Node.p
            [
              Vdom.Node.text
                "This application is not in the server-managed allowlist.";
            ];
          Ui_helpers.route_link ~class_name:"button button-primary"
            ~route:Route.Apps ~navigate
            [ Vdom.Node.text "View applications" ];
        ]
  | Ready application ->
      ready_page ~key ~application ~deployments ~logs ~metrics
        ~deployments_stale ~logs_stale ~metrics_stale ~deploy_state
        ~cancel_confirmation ~capability_grant ~dispatch_cancel
        ~set_deploy_state:Effect.Ignore ~set_cancel_confirmation ~set_notice ~search ~current_match ~follow
        ~paused_snapshot ~set_search ~set_current_match ~set_follow
        ~set_paused_snapshot ~refresh_logs ~navigate
