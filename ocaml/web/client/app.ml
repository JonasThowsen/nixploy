open! Core
open! Bonsai_web.Cont
open Bonsai.Let_syntax

let text_with_class class_name text =
  Vdom.Node.div ~attrs:[ Vdom.Attr.class_ class_name ] [ Vdom.Node.text text ]

let state_name = function
  | Protocol.Deployment.State.Requested -> "QUEUED"
  | Running -> "IN FLIGHT"
  | Succeeded -> "VERIFIED"
  | Failed -> "FAILED"
  | Cancelled -> "CANCELLED"

let state_class = function
  | Protocol.Deployment.State.Requested -> "queued"
  | Running -> "running"
  | Succeeded -> "succeeded"
  | Failed -> "failed"
  | Cancelled -> "cancelled"

let deployment_state_name deployment =
  match deployment.Protocol.Deployment.state with
  | (Requested | Running) when not deployment.can_cancel -> "INTERRUPTED"
  | state -> state_name state

let deployment_state_class deployment =
  match deployment.Protocol.Deployment.state with
  | (Requested | Running) when not deployment.can_cancel -> "interrupted"
  | state -> state_class state

let short_revision revision =
  String.prefix revision (Int.min 12 (String.length revision))

let format_time timestamp_ms =
  timestamp_ms |> Int64.to_float |> Time_ns.Span.of_ms
  |> Time_ns.of_span_since_epoch |> Time_ns.to_string_utc

let format_duration deployment =
  let open Protocol.Deployment in
  match deployment.elapsed_ms with
  | None -> "NOT STARTED"
  | Some elapsed ->
      let seconds = Int64.to_float elapsed /. 1000. in
      if Float.(seconds < 60.) then sprintf "%.1fs" seconds
      else sprintf "%.1fm" (seconds /. 60.)

let format_bytes bytes =
  let value = Int64.to_float bytes in
  if Float.(value >= 1_073_741_824.) then
    sprintf "%.1f GiB" (value /. 1_073_741_824.)
  else if Float.(value >= 1_048_576.) then
    sprintf "%.1f MiB" (value /. 1_048_576.)
  else if Float.(value >= 1024.) then sprintf "%.1f KiB" (value /. 1024.)
  else sprintf "%Ld B" bytes

let format_percent = function
  | None -> "UNAVAILABLE"
  | Some value -> sprintf "%.1f%%" value

let format_uptime = function
  | None -> "UNAVAILABLE"
  | Some seconds ->
      let seconds = Int64.to_int_exn seconds in
      let days = seconds / 86_400 in
      let hours = seconds mod 86_400 / 3_600 in
      if days > 0 then sprintf "%dd %dh" days hours
      else sprintf "%dh %dm" hours (seconds mod 3_600 / 60)

let polling_warning last_ok_response last_error =
  match (last_ok_response, last_error) with
  | Some _, Some (_, error) ->
      text_with_class "stale-panel"
        ("REFRESH FAILED; SHOWING LAST OBSERVATION: "
       ^ Error.to_string_hum error)
  | None, Some (_, error) ->
      text_with_class "error-panel" (Error.to_string_hum error)
  | _ -> Vdom.Node.none

let commit_summary = function
  | None -> ("NO REVISION", "Commit details unavailable")
  | Some commit ->
      (short_revision commit.Protocol.Commit.revision, commit.subject)

let button ?(kind = "secondary") ?(disabled = false) ~label ~on_click () =
  Vdom.Node.button
    ~attrs:
      ([
         Vdom.Attr.classes [ "button"; "button-" ^ kind ];
         Vdom.Attr.create "type" "button";
       ]
      @
      if disabled then [ Vdom.Attr.disabled ]
      else [ Vdom.Attr.on_click (fun _ -> on_click) ])
    [ Vdom.Node.text label ]

let commit_confirmation ~application ~commit ~dispatch_deploy ~set_preview
    ~set_notice =
  let confirm =
    let%bind.Effect response =
      dispatch_deploy
        {
          Protocol.Deploy.Query.application;
          revision = commit.Protocol.Commit.revision;
        }
    in
    let notice =
      match response with
      | Error error -> "DEPLOY RPC FAILED: " ^ Error.to_string_hum error
      | Ok (Error error) -> "DEPLOYMENT REJECTED: " ^ Error.to_string_hum error
      | Ok (Ok id) -> "DEPLOYMENT STARTED: " ^ id
    in
    Effect.Many [ set_preview None; set_notice notice ]
  in
  Vdom.Node.section
    ~attrs:
      [
        Vdom.Attr.class_ "confirmation";
        Vdom.Attr.create "aria-label" "Confirm deployment commit";
      ]
    [
      Vdom.Node.div
        [
          Vdom.Node.span
            ~attrs:[ Vdom.Attr.class_ "eyebrow" ]
            [ Vdom.Node.text "EXACT COMMIT" ];
          Vdom.Node.strong [ Vdom.Node.text commit.subject ];
          Vdom.Node.code [ Vdom.Node.text commit.revision ];
          Vdom.Node.small [ Vdom.Node.text (format_time commit.timestamp_ms) ];
        ];
      Vdom.Node.div
        ~attrs:[ Vdom.Attr.class_ "button-row" ]
        [
          button ~kind:"primary" ~label:"DEPLOY THIS COMMIT" ~on_click:confirm
            ();
          button ~label:"CANCEL" ~on_click:(set_preview None) ();
        ];
    ]

let application_card ~preview ~cancel_confirmation ~dispatch_preview
    ~dispatch_deploy ~dispatch_cancel ~set_preview ~set_cancel_confirmation
    ~set_deployment_filter ~set_selected_logs ~set_search ~set_current_match
    ~set_follow ~set_paused_snapshot ~set_notice application =
  let deployment = application.Protocol.Application.deployment in
  let state, stage, message, revision, subject =
    match deployment with
    | None ->
        ( "NOT DEPLOYED",
          "awaiting first deployment",
          "No deployment has been recorded for this application.",
          "NO REVISION",
          "Commit details unavailable" )
    | Some deployment ->
        let revision, subject = commit_summary deployment.commit in
        ( deployment_state_name deployment,
          deployment.stage,
          Option.value deployment.error ~default:deployment.message,
          revision,
          subject )
  in
  let request_preview =
    let%bind.Effect () = set_notice ("READING MAIN: " ^ application.key) in
    let%bind.Effect response =
      dispatch_preview
        { Protocol.Preview_deployment.Query.application = application.key }
    in
    match response with
    | Error error ->
        set_notice ("PREVIEW RPC FAILED: " ^ Error.to_string_hum error)
    | Ok (Error error) ->
        set_notice ("COMMIT PREVIEW FAILED: " ^ Error.to_string_hum error)
    | Ok (Ok commit) ->
        Effect.Many
          [ set_preview (Some (application.key, commit)); set_notice "" ]
  in
  let open_logs =
    Effect.Many
      [
        set_selected_logs (Some application.key);
        set_search "";
        set_current_match 0;
        set_follow true;
        set_paused_snapshot None;
      ]
  in
  let deployment_actions =
    match deployment with
    | Some deployment
      when Option.is_some deployment.cancel_requested_at_ms
           && ([%equal: Protocol.Deployment.State.t] deployment.state Requested
              || [%equal: Protocol.Deployment.State.t] deployment.state Running
              ) ->
        button ~disabled:true ~label:"CANCELLING; CLEANUP IN PROGRESS"
          ~on_click:Effect.Ignore ()
    | Some deployment when deployment.can_cancel ->
        if Option.equal String.equal cancel_confirmation (Some deployment.id)
        then
          let confirm_cancel =
            let%bind.Effect response =
              dispatch_cancel
                {
                  Protocol.Cancel_deployment.Query.operation_id = deployment.id;
                }
            in
            let notice =
              match response with
              | Error error -> "CANCEL RPC FAILED: " ^ Error.to_string_hum error
              | Ok (Error error) ->
                  "CANCELLATION REJECTED: " ^ Error.to_string_hum error
              | Ok (Ok ()) -> "CANCELLATION REQUESTED; CLEANUP MAY CONTINUE"
            in
            Effect.Many [ set_cancel_confirmation None; set_notice notice ]
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
                  button ~kind:"danger" ~label:"CONFIRM CANCELLATION"
                    ~on_click:confirm_cancel ();
                  button ~label:"KEEP RUNNING"
                    ~on_click:(set_cancel_confirmation None)
                    ();
                ];
            ]
        else
          button ~kind:"danger" ~label:"CANCEL DEPLOYMENT"
            ~on_click:(set_cancel_confirmation (Some deployment.id))
            ()
    | Some deployment
      when ([%equal: Protocol.Deployment.State.t] deployment.state Requested
           || [%equal: Protocol.Deployment.State.t] deployment.state Running)
           && deployment.can_cancel ->
        button ~disabled:true ~label:"DEPLOYMENT ACTIVE" ~on_click:Effect.Ignore
          ()
    | _ ->
        button ~kind:"primary" ~label:"PREVIEW MAIN" ~on_click:request_preview
          ()
  in
  let confirmation =
    match preview with
    | Some (key, commit) when String.equal key application.key ->
        commit_confirmation ~application:key ~commit ~dispatch_deploy
          ~set_preview ~set_notice
    | _ -> Vdom.Node.none
  in
  Vdom.Node.create "article"
    ~attrs:[ Vdom.Attr.class_ "application-card" ]
    [
      Vdom.Node.header
        ~attrs:[ Vdom.Attr.class_ "card-heading" ]
        [
          Vdom.Node.div
            [
              Vdom.Node.span
                ~attrs:[ Vdom.Attr.class_ "eyebrow" ]
                [ Vdom.Node.text application.key ];
              Vdom.Node.h3 [ Vdom.Node.text application.project ];
              Vdom.Node.p
                ~attrs:[ Vdom.Attr.class_ "repository" ]
                [ Vdom.Node.text application.repository ];
            ];
          Vdom.Node.div
            ~attrs:
              [
                Vdom.Attr.classes
                  [
                    "state";
                    Option.value_map deployment ~default:"empty"
                      ~f:deployment_state_class;
                  ];
              ]
            [
              Vdom.Node.span ~attrs:[ Vdom.Attr.class_ "state-light" ] [];
              Vdom.Node.text state;
            ];
        ];
      Vdom.Node.dl
        ~attrs:[ Vdom.Attr.class_ "facts" ]
        [
          Vdom.Node.div
            [
              Vdom.Node.dt [ Vdom.Node.text "TARGET" ];
              Vdom.Node.dd [ Vdom.Node.text application.target ];
            ];
          Vdom.Node.div
            [
              Vdom.Node.dt [ Vdom.Node.text "COMMIT" ];
              Vdom.Node.dd [ Vdom.Node.text revision ];
            ];
          Vdom.Node.div
            [
              Vdom.Node.dt [ Vdom.Node.text "STAGE" ];
              Vdom.Node.dd [ Vdom.Node.text stage ];
            ];
        ];
      Vdom.Node.p
        ~attrs:[ Vdom.Attr.class_ "commit-subject" ]
        [ Vdom.Node.text subject ];
      Vdom.Node.p
        ~attrs:[ Vdom.Attr.class_ "operation-message" ]
        [ Vdom.Node.text message ];
      confirmation;
      Vdom.Node.div
        ~attrs:[ Vdom.Attr.class_ "card-actions" ]
        [
          deployment_actions;
          button ~label:"VIEW LOGS" ~on_click:open_logs ();
          button ~label:"VIEW HISTORY"
            ~on_click:
              (Effect.Many
                 [
                   set_deployment_filter (Some application.key);
                   set_notice ("SHOWING HISTORY: " ^ application.key);
                 ])
            ();
        ];
    ]

let deployment_row recent =
  let deployment = recent.Protocol.Recent_deployment.deployment in
  let revision, subject = commit_summary deployment.commit in
  Vdom.Node.li
    ~attrs:[ Vdom.Attr.class_ "deployment-row" ]
    [
      Vdom.Node.div
        [
          Vdom.Node.strong [ Vdom.Node.text recent.application ];
          Vdom.Node.span
            ~attrs:
              [
                Vdom.Attr.classes
                  [ "state-text"; deployment_state_class deployment ];
              ]
            [ Vdom.Node.text (deployment_state_name deployment) ];
        ];
      Vdom.Node.div
        [
          Vdom.Node.code
            ~attrs:
              (Option.value_map deployment.commit ~default:[] ~f:(fun commit ->
                   [ Vdom.Attr.title commit.revision ]))
            [ Vdom.Node.text revision ];
          Vdom.Node.span [ Vdom.Node.text subject ];
        ];
      Vdom.Node.div
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
      | Some error -> text_with_class "deployment-error" error);
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

let log_viewer ~selected ~search ~current_match ~follow ~paused_snapshot
    ~set_search ~set_current_match ~set_follow ~set_paused_snapshot ~refresh
    response =
  match selected with
  | None ->
      text_with_class "empty-panel" "SELECT AN APPLICATION TO INSPECT LOGS"
  | Some application ->
      let for_application snapshot =
        String.equal snapshot.Protocol.Log_snapshot.application application
      in
      let live_snapshot =
        match response with
        | Some
            ((query : Protocol.Get_application_logs.Query.t), Ok (Some snapshot))
          when Option.equal String.equal query.application (Some application)
               && for_application snapshot ->
            Some snapshot
        | _ -> None
      in
      let paused_snapshot = Option.filter paused_snapshot ~f:for_application in
      let snapshot : Protocol.Log_snapshot.t option =
        if follow then live_snapshot
        else Option.first_some paused_snapshot live_snapshot
      in
      let content =
        match snapshot with
        | None -> (
            match response with
            | Some (_, Error error) ->
                text_with_class "error-panel" (Error.to_string_hum error)
            | _ ->
                text_with_class "loading-panel"
                  "READING BOUNDED APPLICATION LOGS")
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
                    highlighted_line ~query:search ~current:current_match
                      ~first_index line.Protocol.Log_line.text
                  in
                  let node =
                    Vdom.Node.div
                      ~attrs:[ Vdom.Attr.class_ "log-line" ]
                      ((match line.timestamp with
                         | None -> []
                         | Some timestamp ->
                             [
                               Vdom.Node.create "time"
                                 [ Vdom.Node.text timestamp ];
                             ])
                      @ [ Vdom.Node.code highlighted ])
                  in
                  (first_index + count, node :: nodes))
            in
            let pause =
              if follow then
                Effect.Many
                  [ set_paused_snapshot (Some snapshot); set_follow false ]
              else Effect.Many [ set_paused_snapshot None; set_follow true ]
            in
            Vdom.Node.div
              [
                Vdom.Node.div
                  ~attrs:[ Vdom.Attr.class_ "log-toolbar" ]
                  [
                    Vdom.Node.label
                      [
                        Vdom.Node.span [ Vdom.Node.text "SEARCH LOGS" ];
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
                        Vdom.Node.span
                          [ Vdom.Node.text (sprintf "%d MATCHES" total) ];
                        button ~label:"PREVIOUS" ~disabled:(total = 0)
                          ~on_click:
                            (set_current_match
                               (if total = 0 then 0
                                else (current_match - 1 + total) mod total))
                          ();
                        button ~label:"NEXT" ~disabled:(total = 0)
                          ~on_click:
                            (set_current_match
                               (if total = 0 then 0
                                else (current_match + 1) mod total))
                          ();
                        button
                          ~label:(if follow then "PAUSE" else "RESUME")
                          ~on_click:pause ();
                        button ~label:"REFRESH" ~on_click:refresh ();
                      ];
                  ];
                Vdom.Node.div
                  ~attrs:
                    [
                      Vdom.Attr.class_ "log-meta";
                      Vdom.Attr.create "aria-live" "polite";
                    ]
                  [
                    Vdom.Node.span [ Vdom.Node.text snapshot.container_name ];
                    Vdom.Node.span
                      [ Vdom.Node.text (format_time snapshot.observed_at_ms) ];
                    Vdom.Node.span
                      [
                        Vdom.Node.text
                          (if follow then "FOLLOWING" else "PAUSED");
                      ];
                    (if snapshot.truncated then
                       Vdom.Node.span [ Vdom.Node.text "TRUNCATED" ]
                     else Vdom.Node.none);
                  ];
                Vdom.Node.div
                  ~attrs:
                    [
                      Vdom.Attr.class_ "log-output";
                      Vdom.Attr.create "role" "log";
                      Vdom.Attr.create "aria-label"
                        (application ^ " recent logs");
                    ]
                  (List.rev line_nodes);
              ]
      in
      Vdom.Node.div [ content ]

let metric_value label value =
  Vdom.Node.div
    [
      Vdom.Node.dt [ Vdom.Node.text label ];
      Vdom.Node.dd [ Vdom.Node.text value ];
    ]

let metrics_panel response =
  match response with
  | None -> text_with_class "loading-panel" "READING TARGET HEALTH"
  | Some (_, Error error) ->
      text_with_class "error-panel" (Error.to_string_hum error)
  | Some (_, Ok []) ->
      text_with_class "empty-panel" "NO TARGET METRICS AVAILABLE"
  | Some (_, Ok targets) ->
      Vdom.Node.div
        ~attrs:[ Vdom.Attr.class_ "target-metrics-grid" ]
        (List.map targets ~f:(fun target ->
             Vdom.Node.create "article"
               ~attrs:[ Vdom.Attr.class_ "target-metrics" ]
               [
                 Vdom.Node.header
                   [
                     Vdom.Node.h3
                       [ Vdom.Node.text target.Protocol.Target_metrics.target ];
                     Vdom.Node.code [ Vdom.Node.text target.host ];
                   ];
                 (match target.error with
                 | None -> Vdom.Node.none
                 | Some error -> text_with_class "deployment-error" error);
                 Vdom.Node.dl
                   ~attrs:[ Vdom.Attr.class_ "metric-list" ]
                   [
                     metric_value "HOST CPU" (format_percent target.cpu_percent);
                     metric_value "MEMORY"
                       (match
                          (target.memory_used_bytes, target.memory_total_bytes)
                        with
                       | Some used, Some total ->
                           format_bytes used ^ " / " ^ format_bytes total
                       | _ -> "UNAVAILABLE");
                     metric_value "FILESYSTEM"
                       (match
                          ( target.filesystem_used_bytes,
                            target.filesystem_total_bytes )
                        with
                       | Some used, Some total ->
                           format_bytes used ^ " / " ^ format_bytes total
                       | _ -> "UNAVAILABLE");
                     metric_value "LOAD"
                       (match
                          (target.load_1, target.load_5, target.load_15)
                        with
                       | Some one, Some five, Some fifteen ->
                           sprintf "%.2f / %.2f / %.2f" one five fifteen
                       | _ -> "UNAVAILABLE");
                     metric_value "UPTIME" (format_uptime target.uptime_seconds);
                   ];
                 Vdom.Node.div
                   ~attrs:[ Vdom.Attr.class_ "application-metrics" ]
                   (List.map target.applications ~f:(fun application ->
                        let health =
                          match
                            application.Protocol.Application_metrics.health
                          with
                          | Healthy -> "HEALTHY"
                          | Unhealthy -> "UNHEALTHY"
                          | Unavailable _ -> "UNAVAILABLE"
                        in
                        Vdom.Node.div
                          [
                            Vdom.Node.strong
                              [ Vdom.Node.text application.application ];
                            Vdom.Node.span [ Vdom.Node.text health ];
                            Vdom.Node.span
                              [
                                Vdom.Node.text
                                  ("CPU "
                                  ^ format_percent application.cpu_percent);
                              ];
                            Vdom.Node.span
                              [
                                Vdom.Node.text
                                  ("RAM "
                                  ^ Option.value_map
                                      application.memory_used_bytes
                                      ~default:"UNAVAILABLE" ~f:format_bytes);
                              ];
                            Vdom.Node.span
                              [
                                Vdom.Node.text
                                  ("HOST "
                                  ^ format_percent
                                      application.memory_host_percent);
                              ];
                            Vdom.Node.span
                              [
                                Vdom.Node.text
                                  ("UP "
                                  ^ format_uptime application.uptime_seconds);
                              ];
                            (match application.error with
                            | None -> Vdom.Node.none
                            | Some error ->
                                text_with_class "deployment-error" error);
                          ]));
                 Vdom.Node.small
                   [
                     Vdom.Node.text
                       ("OBSERVED " ^ format_time target.observed_at_ms);
                   ];
               ]))

let component graph =
  let preview, set_preview = Bonsai.state None graph in
  let cancel_confirmation, set_cancel_confirmation = Bonsai.state None graph in
  let deployment_filter, set_deployment_filter = Bonsai.state None graph in
  let selected_logs, set_selected_logs = Bonsai.state None graph in
  let search, set_search = Bonsai.state "" graph in
  let current_match, set_current_match = Bonsai.state 0 graph in
  let follow, set_follow = Bonsai.state true graph in
  let paused_snapshot, set_paused_snapshot = Bonsai.state None graph in
  let notice, set_notice = Bonsai.state "" graph in
  let applications =
    Rpc_effect.Rpc.poll Protocol.List_applications.t ~where_to_connect:Self
      ~equal_query:[%equal: unit]
      ~equal_response:[%equal: Protocol.Application.t list Or_error.t]
      ~every:(Time_ns.Span.of_sec 1.) (Bonsai.return ()) graph
  in
  let deployments_query =
    let%arr deployment_filter = deployment_filter in
    { Protocol.List_deployments.Query.application = deployment_filter }
  in
  let deployments =
    Rpc_effect.Rpc.poll Protocol.List_deployments.t ~where_to_connect:Self
      ~equal_query:[%equal: Protocol.List_deployments.Query.t]
      ~equal_response:[%equal: Protocol.Recent_deployment.t list Or_error.t]
      ~every:(Time_ns.Span.of_sec 1.) deployments_query graph
  in
  let logs_query =
    let%arr selected_logs = selected_logs in
    { Protocol.Get_application_logs.Query.application = selected_logs }
  in
  let logs =
    Rpc_effect.Rpc.poll Protocol.Get_application_logs.t ~where_to_connect:Self
      ~equal_query:[%equal: Protocol.Get_application_logs.Query.t]
      ~equal_response:[%equal: Protocol.Log_snapshot.t option Or_error.t]
      ~every:(Time_ns.Span.of_sec 2.) logs_query graph
  in
  let metrics =
    Rpc_effect.Rpc.poll Protocol.Get_metrics.t ~where_to_connect:Self
      ~equal_query:[%equal: unit]
      ~equal_response:[%equal: Protocol.Target_metrics.t list Or_error.t]
      ~every:(Time_ns.Span.of_sec 10.) (Bonsai.return ()) graph
  in
  let dispatch_preview =
    Rpc_effect.Rpc.dispatcher Protocol.Preview_deployment.t
      ~where_to_connect:Self graph
  in
  let dispatch_deploy =
    Rpc_effect.Rpc.dispatcher Protocol.Deploy.t ~where_to_connect:Self graph
  in
  let dispatch_cancel =
    Rpc_effect.Rpc.dispatcher Protocol.Cancel_deployment.t
      ~where_to_connect:Self graph
  in
  let%arr applications = applications
  and deployments = deployments
  and logs = logs
  and metrics = metrics
  and preview = preview
  and set_preview = set_preview
  and cancel_confirmation = cancel_confirmation
  and set_cancel_confirmation = set_cancel_confirmation
  and deployment_filter = deployment_filter
  and set_deployment_filter = set_deployment_filter
  and selected_logs = selected_logs
  and set_selected_logs = set_selected_logs
  and search = search
  and set_search = set_search
  and current_match = current_match
  and set_current_match = set_current_match
  and follow = follow
  and set_follow = set_follow
  and paused_snapshot = paused_snapshot
  and set_paused_snapshot = set_paused_snapshot
  and notice = notice
  and set_notice = set_notice
  and dispatch_preview = dispatch_preview
  and dispatch_deploy = dispatch_deploy
  and dispatch_cancel = dispatch_cancel in
  let application_content =
    match applications.last_ok_response with
    | Some (_, Ok (_ :: _ as application_list)) ->
        List.map application_list
          ~f:
            (application_card ~preview ~cancel_confirmation ~dispatch_preview
               ~dispatch_deploy ~dispatch_cancel ~set_preview
               ~set_cancel_confirmation ~set_deployment_filter
               ~set_selected_logs ~set_search ~set_current_match ~set_follow
               ~set_paused_snapshot ~set_notice)
    | Some (_, Ok []) ->
        [ text_with_class "empty-panel" "NO APPLICATIONS ARE ALLOWLISTED" ]
    | Some (_, Error error) ->
        [ text_with_class "error-panel" (Error.to_string_hum error) ]
    | None -> [ text_with_class "loading-panel" "READING CONTROL PLANE" ]
  in
  let deployment_content =
    match deployments.last_ok_response with
    | Some (_, Ok (_ :: _ as entries)) ->
        Vdom.Node.ol
          ~attrs:[ Vdom.Attr.class_ "deployment-list" ]
          (List.map entries ~f:deployment_row)
    | Some (_, Ok []) -> text_with_class "empty-panel" "NO DEPLOYMENTS RECORDED"
    | Some (_, Error error) ->
        text_with_class "error-panel" (Error.to_string_hum error)
    | None -> text_with_class "loading-panel" "READING DEPLOYMENT HISTORY"
  in
  Vdom.Node.main
    ~attrs:[ Vdom.Attr.class_ "shell" ]
    [
      Vdom.Node.header
        ~attrs:[ Vdom.Attr.class_ "masthead" ]
        [
          Vdom.Node.div
            ~attrs:[ Vdom.Attr.class_ "wordmark" ]
            [
              Vdom.Node.span [ Vdom.Node.text "NIX" ];
              Vdom.Node.span [ Vdom.Node.text "PLOY" ];
            ];
          Vdom.Node.div
            ~attrs:[ Vdom.Attr.class_ "masthead-copy" ]
            [
              Vdom.Node.p [ Vdom.Node.text "HOST RELEASE CONTROL" ];
              Vdom.Node.h1 [ Vdom.Node.text "Operations" ];
            ];
          Vdom.Node.div
            ~attrs:[ Vdom.Attr.class_ "connection" ]
            [
              Vdom.Node.span [ Vdom.Node.text "RPC" ];
              Vdom.Node.strong
                [
                  Vdom.Node.text
                    (if Option.is_some applications.last_ok_response then
                       "CONNECTED"
                     else "CONNECTING");
                ];
            ];
        ];
      (if String.is_empty notice then Vdom.Node.none
       else
         Vdom.Node.div
           ~attrs:
             [
               Vdom.Attr.class_ "notice";
               Vdom.Attr.create "role" "status";
               Vdom.Attr.create "aria-live" "polite";
             ]
           [ Vdom.Node.text notice ]);
      Vdom.Node.section
        ~attrs:
          [
            Vdom.Attr.class_ "section";
            Vdom.Attr.create "aria-labelledby" "health-title";
          ]
        [
          Vdom.Node.header
            ~attrs:[ Vdom.Attr.class_ "section-heading" ]
            [
              Vdom.Node.div
                [
                  Vdom.Node.span
                    ~attrs:[ Vdom.Attr.class_ "eyebrow" ]
                    [ Vdom.Node.text "REMOTE TARGETS" ];
                  Vdom.Node.h2
                    ~attrs:[ Vdom.Attr.id "health-title" ]
                    [ Vdom.Node.text "Health and capacity" ];
                ];
            ];
          polling_warning metrics.last_ok_response metrics.last_error;
          metrics_panel
            (Option.map metrics.last_ok_response ~f:(fun (query, response) ->
                 (query, response)));
        ];
      Vdom.Node.section
        ~attrs:
          [
            Vdom.Attr.class_ "section";
            Vdom.Attr.create "aria-labelledby" "applications-title";
          ]
        [
          Vdom.Node.header
            ~attrs:[ Vdom.Attr.class_ "section-heading" ]
            [
              Vdom.Node.div
                [
                  Vdom.Node.span
                    ~attrs:[ Vdom.Attr.class_ "eyebrow" ]
                    [ Vdom.Node.text "ALLOWLISTED SOURCES" ];
                  Vdom.Node.h2
                    ~attrs:[ Vdom.Attr.id "applications-title" ]
                    [ Vdom.Node.text "Applications" ];
                ];
            ];
          polling_warning applications.last_ok_response applications.last_error;
          Vdom.Node.div
            ~attrs:[ Vdom.Attr.class_ "applications" ]
            application_content;
        ];
      Vdom.Node.section
        ~attrs:
          [
            Vdom.Attr.class_ "section";
            Vdom.Attr.create "aria-labelledby" "deployments-title";
          ]
        [
          Vdom.Node.header
            ~attrs:[ Vdom.Attr.class_ "section-heading" ]
            [
              Vdom.Node.div
                [
                  Vdom.Node.span
                    ~attrs:[ Vdom.Attr.class_ "eyebrow" ]
                    [ Vdom.Node.text "SQLITE LEDGER" ];
                  Vdom.Node.h2
                    ~attrs:[ Vdom.Attr.id "deployments-title" ]
                    [
                      Vdom.Node.text
                        (Option.value_map deployment_filter
                           ~default:"Latest deployments" ~f:(fun application ->
                             application ^ " deployments"));
                    ];
                ];
              (match deployment_filter with
              | None -> Vdom.Node.none
              | Some _ ->
                  button ~label:"SHOW ALL"
                    ~on_click:
                      (Effect.Many [ set_deployment_filter None; set_notice "" ])
                    ());
            ];
          polling_warning deployments.last_ok_response deployments.last_error;
          deployment_content;
        ];
      Vdom.Node.section
        ~attrs:
          [
            Vdom.Attr.class_ "section";
            Vdom.Attr.create "aria-labelledby" "logs-title";
          ]
        [
          Vdom.Node.header
            ~attrs:[ Vdom.Attr.class_ "section-heading" ]
            [
              Vdom.Node.div
                [
                  Vdom.Node.span
                    ~attrs:[ Vdom.Attr.class_ "eyebrow" ]
                    [ Vdom.Node.text "BOUNDED RUNTIME OUTPUT" ];
                  Vdom.Node.h2
                    ~attrs:[ Vdom.Attr.id "logs-title" ]
                    [ Vdom.Node.text "Application logs" ];
                ];
            ];
          polling_warning logs.last_ok_response logs.last_error;
          log_viewer ~selected:selected_logs ~search ~current_match ~follow
            ~paused_snapshot ~set_search ~set_current_match ~set_follow
            ~set_paused_snapshot ~refresh:logs.refresh logs.last_ok_response;
        ];
      Vdom.Node.footer
        [
          Vdom.Node.span [ Vdom.Node.text "STATE: SQLITE" ];
          Vdom.Node.span
            [ Vdom.Node.text "SOURCE: LOCAL GIT / RUNTIME: REMOTE PODMAN" ];
        ];
    ]
