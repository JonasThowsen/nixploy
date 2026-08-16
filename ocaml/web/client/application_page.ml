open Core
open! Bonsai_web.Cont
module Deploy_state = Nixploy_web_client_state.Deploy_state
module Prune_state = Nixploy_web_client_state.Prune_state

type application_state =
  | Loading
  | Failed of Error.t
  | Missing
  | Ready of Protocol.Application.t

let primary_action_id = "application-primary-action"
let prune_action_id = "prune-resources-button"
let focus_primary_action = Browser_navigation.focus primary_action_id
let focus_prune_action = Browser_navigation.focus prune_action_id

let id_component value =
  String.concat_map value ~f:(fun character ->
      sprintf "%02x" (Char.to_int character))

let fact label value =
  Vdom.Node.div
    [
      Vdom.Node.dt [ Vdom.Node.text label ];
      Vdom.Node.dd [ Vdom.Node.text value ];
    ]

let commit_confirmation ~application ~commit ~deploy_state ~dispatch_deploy
    ~set_preview ~set_deploy_state ~set_cancel_confirmation ~set_prune_state
    ~set_notice =
  let pending = Deploy_state.is_pending deploy_state in
  let confirm =
    let%bind.Effect owner = Browser_navigation.application_owner application in
    let%bind.Effect () =
      Effect.Many
        [
          set_deploy_state
            (Deploy_state.start_submission deploy_state ~key:application);
          set_cancel_confirmation None;
          set_prune_state Prune_state.Idle;
        ]
    in
    let%bind.Effect response =
      dispatch_deploy
        {
          Protocol.Deploy.Query.application;
          revision = commit.Protocol.Commit.revision;
        }
    in
    if not (Browser_navigation.is_current_owner owner) then Effect.Ignore
    else
      let submitting = Deploy_state.Submitting application in
      let finished =
        set_deploy_state
          (Deploy_state.finish_submission submitting ~key:application)
      in
      match response with
      | Error error ->
          Effect.Many
            [
              finished;
              set_notice ("Deploy RPC failed: " ^ Error.to_string_hum error);
            ]
      | Ok (Error error) ->
          Effect.Many
            [
              finished;
              set_notice ("Deployment rejected: " ^ Error.to_string_hum error);
            ]
      | Ok (Ok id) ->
          Effect.Many
            [
              set_deploy_state
                (Deploy_state.accept_submission submitting ~key:application
                   ~operation_id:id);
              set_preview None;
              set_notice ("Deployment started: " ^ id);
              focus_primary_action;
            ]
  in
  Vdom.Node.section
    ~attrs:
      [
        Vdom.Attr.class_ "confirmation deploy-confirmation";
        Vdom.Attr.create "aria-label" "Confirm deployment commit";
      ]
    [
      Vdom.Node.div
        [
          Vdom.Node.p
            ~attrs:[ Vdom.Attr.class_ "eyebrow" ]
            [ Vdom.Node.text "Exact immutable commit" ];
          Vdom.Node.strong [ Vdom.Node.text commit.subject ];
          Vdom.Node.code [ Vdom.Node.text commit.revision ];
          Vdom.Node.small
            [ Vdom.Node.text (Ui_helpers.format_time commit.timestamp_ms) ];
        ];
      Vdom.Node.div
        ~attrs:[ Vdom.Attr.class_ "button-row" ]
        [
          Ui_helpers.button ~kind:"primary" ~disabled:pending
            ~label:
              (if pending then "Submitting deployment…"
               else "Deploy this commit")
            ~on_click:confirm ();
          Ui_helpers.button ~disabled:pending ~label:"Cancel"
            ~on_click:(Effect.Many [ set_preview None; focus_primary_action ])
            ();
        ];
    ]

let prune_route_notice = function
  | Protocol.Prune_result.Route.Not_configured -> "not configured"
  | Missing -> "already absent"
  | Removed -> "removed"

let prune_confirmation ~application ~dispatch_prune ~prune_state
    ~set_prune_state ~set_notice ~deployment_active =
  let key = application.Protocol.Application.key in
  let suffix = id_component key in
  let title_id = "prune-dialog-title-" ^ suffix in
  let description_id = "prune-dialog-description-" ^ suffix in
  let pending =
    match prune_state with
    | Prune_state.Pending pending -> String.equal pending key
    | Prune_state.Idle | Prune_state.Confirming _ -> false
  in
  let error =
    match Prune_state.confirmation prune_state with
    | Some (confirmation_key, error) when String.equal confirmation_key key ->
        error
    | _ -> None
  in
  let confirm =
    let%bind.Effect owner = Browser_navigation.application_owner key in
    let%bind.Effect () = set_prune_state (Prune_state.start prune_state ~key) in
    let%bind.Effect response =
      dispatch_prune { Protocol.Prune.Query.application = key }
    in
    if not (Browser_navigation.is_current_owner owner) then Effect.Ignore
    else
      match response with
      | Error rpc_error ->
          let error = "Prune RPC failed: " ^ Error.to_string_hum rpc_error in
          Effect.Many
            [
              set_prune_state
                (Prune_state.fail (Prune_state.Pending key) ~key ~error);
              set_notice error;
            ]
      | Ok (Error application_error) ->
          let error =
            "Prune rejected: " ^ Error.to_string_hum application_error
          in
          Effect.Many
            [
              set_prune_state
                (Prune_state.fail (Prune_state.Pending key) ~key ~error);
              set_notice error;
            ]
      | Ok (Ok result) ->
          let notice =
            sprintf
              "Prune completed for %s/%s: %d containers removed; %d scoped \
               secrets removed; Caddy route %s."
              result.Protocol.Prune_result.project result.target
              result.containers_removed result.secrets_removed
              (prune_route_notice result.route)
          in
          Effect.Many
            [
              set_prune_state
                (Prune_state.succeed (Prune_state.Pending key) ~key);
              set_notice notice;
              focus_prune_action;
            ]
  in
  Vdom.Node.section
    ~attrs:
      [
        Vdom.Attr.class_ "confirmation prune-confirmation";
        Vdom.Attr.create "role" "alertdialog";
        Vdom.Attr.create "aria-modal" "false";
        Vdom.Attr.create "aria-labelledby" title_id;
        Vdom.Attr.create "aria-describedby" description_id;
      ]
    [
      Vdom.Node.div
        [
          Vdom.Node.p
            ~attrs:[ Vdom.Attr.class_ "eyebrow danger-copy" ]
            [ Vdom.Node.text "Destructive resource prune" ];
          Vdom.Node.strong
            ~attrs:[ Vdom.Attr.id title_id ]
            [ Vdom.Node.text ("Application " ^ key) ];
          Vdom.Node.p
            ~attrs:[ Vdom.Attr.id description_id ]
            [
              Vdom.Node.text
                ("Project " ^ application.project ^ " / target "
               ^ application.target
               ^ ". This removes owned containers, scoped secrets, and the \
                  Caddy route. It causes downtime until resources are deployed \
                  again.");
            ];
          (match error with
          | None -> Vdom.Node.none
          | Some error ->
              Vdom.Node.p
                ~attrs:
                  [
                    Vdom.Attr.class_ "inline-error";
                    Vdom.Attr.create "role" "alert";
                  ]
                [ Vdom.Node.text error ]);
        ];
      Vdom.Node.div
        ~attrs:[ Vdom.Attr.class_ "button-row" ]
        [
          Ui_helpers.button ~autofocus:(not pending) ~disabled:pending
            ~label:"Keep resources"
            ~on_click:
              (Effect.Many
                 [
                   set_prune_state (Prune_state.keep prune_state ~key);
                   focus_prune_action;
                 ])
            ();
          Ui_helpers.button ~kind:"danger"
            ~disabled:(deployment_active || pending)
            ~label:(if pending then "Pruning resources…" else "Confirm prune")
            ~on_click:confirm ();
        ];
    ]

let deployment_action ~application ~deployment ~deploy_state ~prune_state
    ~cancel_confirmation ~dispatch_preview ~dispatch_cancel ~set_preview
    ~set_deploy_state ~set_cancel_confirmation ~set_prune_state ~set_notice =
  let prune_busy = Prune_state.is_busy prune_state in
  let deploy_busy = Deploy_state.is_busy deploy_state in
  match deployment with
  | Some deployment
    when Option.is_some deployment.Protocol.Deployment.cancel_requested_at_ms
         &&
         match deployment.state with
         | Requested | Running -> true
         | _ -> false ->
      Ui_helpers.button ~id:primary_action_id ~disabled:true
        ~label:"Cancelling; cleanup in progress…" ~on_click:Effect.Ignore ()
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
                Protocol.Cancel_deployment_v1.Query.application =
                  application.Protocol.Application.key;
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
                Ui_helpers.button ~autofocus:true
                  ~disabled:(prune_busy || deploy_busy)
                  ~label:"Keep running"
                  ~on_click:
                    (Effect.Many
                       [ set_cancel_confirmation None; focus_primary_action ])
                  ();
                Ui_helpers.button ~kind:"danger"
                  ~disabled:(prune_busy || deploy_busy)
                  ~label:"Confirm cancellation" ~on_click:confirm_cancel ();
              ];
          ]
      else
        Ui_helpers.button ~id:primary_action_id ~kind:"danger-outline"
          ~disabled:(prune_busy || deploy_busy)
          ~label:"Cancel deployment"
          ~on_click:
            (Effect.Many
               [
                 set_preview None;
                 set_prune_state Prune_state.Idle;
                 set_cancel_confirmation (Some deployment.id);
               ])
          ()
  | _ ->
      let key = application.Protocol.Application.key in
      let previewing = Deploy_state.is_previewing deploy_state ~key in
      let request_preview =
        let%bind.Effect owner = Browser_navigation.application_owner key in
        let%bind.Effect () =
          Effect.Many
            [
              set_deploy_state (Deploy_state.start_preview deploy_state ~key);
              set_preview None;
              set_cancel_confirmation None;
              set_prune_state Prune_state.Idle;
              set_notice ("Reading main for " ^ key ^ "…");
            ]
        in
        let%bind.Effect response =
          dispatch_preview
            { Protocol.Preview_deployment.Query.application = key }
        in
        let finished =
          set_deploy_state
            (Deploy_state.finish_preview (Deploy_state.Previewing key) ~key)
        in
        if not (Browser_navigation.is_current_owner owner) then Effect.Ignore
        else
          match response with
          | Error error ->
              Effect.Many
                [
                  finished;
                  set_notice ("Preview RPC failed: " ^ Error.to_string_hum error);
                ]
          | Ok (Error error) ->
              Effect.Many
                [
                  finished;
                  set_notice
                    ("Commit preview failed: " ^ Error.to_string_hum error);
                ]
          | Ok (Ok commit) ->
              Effect.Many
                [ finished; set_preview (Some (key, commit)); set_notice "" ]
      in
      Ui_helpers.button ~id:primary_action_id ~kind:"primary"
        ~disabled:(prune_busy || deploy_busy)
        ~label:(if previewing then "Reading main…" else "Preview main")
        ~on_click:request_preview ()

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
          let global_index = match_index in
          let mark =
            Vdom.Node.create "mark"
              ~attrs:
                ([
                   Vdom.Attr.class_
                     (if Int.equal global_index current then "active-match"
                      else "");
                 ]
                @
                if Int.equal global_index current then
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
            "No positively identified active container is available for logs."
      | None | Some (Ok (Some _)) ->
          Ui_helpers.text_panel ~kind:"loading"
            "Reading bounded application logs…")
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
      let pause =
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
                        Vdom.Attr.placeholder "Literal text";
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
                    ~on_click:pause ();
                  Ui_helpers.button ~label:"Refresh" ~on_click:refresh ();
                ];
            ];
          Vdom.Node.div
            ~attrs:
              [
                Vdom.Attr.class_ "log-meta numeric";
                Vdom.Attr.create "aria-live" "polite";
              ]
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
                [ Vdom.Node.text "Inspect full target telemetry" ];
            ])

let ready_page ~key ~application ~deployments ~logs ~metrics ~deployments_stale
    ~logs_stale ~metrics_stale ~preview ~deploy_state ~cancel_confirmation
    ~prune_state ~search ~current_match ~follow ~paused_snapshot
    ~dispatch_preview ~dispatch_deploy ~dispatch_cancel ~dispatch_prune
    ~set_preview ~set_deploy_state ~set_cancel_confirmation ~set_prune_state
    ~set_search ~set_current_match ~set_follow ~set_paused_snapshot ~set_notice
    ~refresh_logs ~navigate =
  let deployment = application.Protocol.Application.deployment in
  let resource_label, resource_class =
    Ui_helpers.resource_state application.resource_state
  in
  let revision, subject, stage, message =
    match deployment with
    | None ->
        ( "No revision",
          "Commit details unavailable",
          "Awaiting first deployment",
          "No deployment has been recorded for this application." )
    | Some deployment ->
        let revision, subject = Ui_helpers.commit_summary deployment.commit in
        ( revision,
          subject,
          deployment.stage,
          Option.value deployment.error ~default:deployment.message )
  in
  let action =
    deployment_action ~application ~deployment ~deploy_state ~prune_state
      ~cancel_confirmation ~dispatch_preview ~dispatch_cancel ~set_preview
      ~set_deploy_state ~set_cancel_confirmation ~set_prune_state ~set_notice
  in
  let deploy_confirmation =
    match preview with
    | Some (preview_key, commit)
      when String.equal preview_key key && not (Prune_state.is_busy prune_state)
      ->
        commit_confirmation ~application:key ~commit ~deploy_state
          ~dispatch_deploy ~set_preview ~set_deploy_state
          ~set_cancel_confirmation ~set_prune_state ~set_notice
    | _ -> Vdom.Node.none
  in
  let prune_open =
    match Prune_state.confirmation prune_state with
    | Some (prune_key, _) -> String.equal prune_key key
    | None -> (
        match prune_state with
        | Prune_state.Pending prune_key -> String.equal prune_key key
        | Idle | Confirming _ -> false)
  in
  let deployment_active = Ui_helpers.deployment_is_active deployment in
  let prune =
    if prune_open then
      prune_confirmation ~application ~dispatch_prune ~prune_state
        ~set_prune_state ~set_notice
        ~deployment_active:
          (deployment_active || Deploy_state.is_busy deploy_state)
    else Vdom.Node.none
  in
  let open_prune =
    Effect.Many
      [
        set_preview None;
        set_cancel_confirmation None;
        set_prune_state (Prune_state.confirm prune_state ~key);
      ]
  in
  Vdom.Node.div
    ~attrs:[ Vdom.Attr.class_ "page application-page" ]
    [
      Vdom.Node.header
        ~attrs:[ Vdom.Attr.class_ "application-hero surface" ]
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
          Vdom.Node.dl
            ~attrs:[ Vdom.Attr.class_ "application-summary numeric" ]
            [
              fact "Target" application.target;
              fact "Revision" revision;
              fact "Stage" stage;
            ];
          Vdom.Node.div
            ~attrs:[ Vdom.Attr.class_ "deployment-copy" ]
            [
              Vdom.Node.strong [ Vdom.Node.text subject ];
              Vdom.Node.p [ Vdom.Node.text message ];
            ];
          Vdom.Node.div
            ~attrs:[ Vdom.Attr.class_ "primary-operation" ]
            [ action ];
          deploy_confirmation;
        ];
      Vdom.Node.div
        ~attrs:[ Vdom.Attr.class_ "application-columns" ]
        [
          Vdom.Node.section
            ~attrs:
              [
                Vdom.Attr.class_ "surface";
                Vdom.Attr.create "aria-labelledby" "runtime-title";
              ]
            [
              Vdom.Node.header
                ~attrs:[ Vdom.Attr.class_ "surface-header" ]
                [
                  Vdom.Node.div
                    [
                      Vdom.Node.p
                        ~attrs:[ Vdom.Attr.class_ "eyebrow" ]
                        [ Vdom.Node.text "Current observation" ];
                      Vdom.Node.h3
                        ~attrs:[ Vdom.Attr.id "runtime-title" ]
                        [ Vdom.Node.text "Runtime metrics" ];
                    ];
                ];
              Ui_helpers.polling_warning ~has_last_good:(Option.is_some metrics)
                metrics_stale;
              application_metrics ~key ~navigate metrics;
            ];
          Vdom.Node.section
            ~attrs:
              [
                Vdom.Attr.class_ "surface";
                Vdom.Attr.create "aria-labelledby" "history-title";
              ]
            [
              Vdom.Node.header
                ~attrs:[ Vdom.Attr.class_ "surface-header" ]
                [
                  Vdom.Node.div
                    [
                      Vdom.Node.p
                        ~attrs:[ Vdom.Attr.class_ "eyebrow" ]
                        [ Vdom.Node.text "Application scope" ];
                      Vdom.Node.h3
                        ~attrs:[ Vdom.Attr.id "history-title" ]
                        [ Vdom.Node.text "Deployment history" ];
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
                  Ui_helpers.text_panel ~kind:"error"
                    (Error.to_string_hum error)
              | Some (Ok []) ->
                  Ui_helpers.text_panel ~kind:"empty"
                    "No deployments have been recorded for this application."
              | Some (Ok entries) ->
                  Vdom.Node.ol
                    ~attrs:[ Vdom.Attr.class_ "deployment-list" ]
                    (List.map entries
                       ~f:
                         (Ui_helpers.deployment_row ~link_application:false
                            ~navigate)));
            ];
        ];
      Vdom.Node.section
        ~attrs:
          [
            Vdom.Attr.class_ "surface logs-surface";
            Vdom.Attr.create "aria-labelledby" "logs-title";
          ]
        [
          Vdom.Node.header
            ~attrs:[ Vdom.Attr.class_ "surface-header" ]
            [
              Vdom.Node.div
                [
                  Vdom.Node.p
                    ~attrs:[ Vdom.Attr.class_ "eyebrow" ]
                    [ Vdom.Node.text "Bounded runtime output" ];
                  Vdom.Node.h3
                    ~attrs:[ Vdom.Attr.id "logs-title" ]
                    [ Vdom.Node.text "Application logs" ];
                ];
            ];
          Ui_helpers.polling_warning ~has_last_good:(Option.is_some logs)
            logs_stale;
          log_viewer ~key ~search ~current_match ~follow ~paused_snapshot
            ~set_search ~set_current_match ~set_follow ~set_paused_snapshot
            ~refresh:refresh_logs logs;
        ];
      Vdom.Node.section
        ~attrs:
          [
            Vdom.Attr.class_ "surface danger-zone";
            Vdom.Attr.create "aria-labelledby" "danger-title";
          ]
        [
          Vdom.Node.header
            ~attrs:[ Vdom.Attr.class_ "surface-header" ]
            [
              Vdom.Node.div
                [
                  Vdom.Node.p
                    ~attrs:[ Vdom.Attr.class_ "eyebrow danger-copy" ]
                    [ Vdom.Node.text "Destructive maintenance" ];
                  Vdom.Node.h3
                    ~attrs:[ Vdom.Attr.id "danger-title" ]
                    [ Vdom.Node.text "Prune managed resources" ];
                  Vdom.Node.p
                    [
                      Vdom.Node.text
                        "Prune is separate from deployment history and remains \
                         unavailable during an active deployment.";
                    ];
                ];
              Ui_helpers.button ~id:prune_action_id ~kind:"danger-outline"
                ~disabled:
                  (deployment_active
                  || Prune_state.is_busy prune_state
                  || Deploy_state.is_busy deploy_state)
                ~label:"Prune resources" ~on_click:open_prune ();
            ];
          prune;
        ];
    ]

let render ~key ~application_state ~deployments ~logs ~metrics
    ~deployments_stale ~logs_stale ~metrics_stale ~preview ~deploy_state
    ~cancel_confirmation ~prune_state ~search ~current_match ~follow
    ~paused_snapshot ~dispatch_preview ~dispatch_deploy ~dispatch_cancel
    ~dispatch_prune ~set_preview ~set_deploy_state ~set_cancel_confirmation
    ~set_prune_state ~set_search ~set_current_match ~set_follow
    ~set_paused_snapshot ~set_notice ~refresh_logs ~navigate =
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
                "This key is not present in the server-managed application \
                 allowlist. The requested URL has not been changed.";
            ];
          Ui_helpers.route_link ~class_name:"button button-primary"
            ~route:Route.Apps ~navigate
            [ Vdom.Node.text "View recognized applications" ];
        ]
  | Ready application ->
      ready_page ~key ~application ~deployments ~logs ~metrics
        ~deployments_stale ~logs_stale ~metrics_stale ~preview ~deploy_state
        ~cancel_confirmation ~prune_state ~search ~current_match ~follow
        ~paused_snapshot ~dispatch_preview ~dispatch_deploy ~dispatch_cancel
        ~dispatch_prune ~set_preview ~set_deploy_state ~set_cancel_confirmation
        ~set_prune_state ~set_search ~set_current_match ~set_follow
        ~set_paused_snapshot ~set_notice ~refresh_logs ~navigate
