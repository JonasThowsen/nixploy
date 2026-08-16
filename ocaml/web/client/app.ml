open! Core
open! Bonsai_web.Cont
open Bonsai.Let_syntax
module Deploy_state = Nixploy_web_client_state.Deploy_state
module Last_good = Nixploy_web_client_state.Last_good
module Prune_state = Nixploy_web_client_state.Prune_state

let empty_poll_result () =
  {
    Rpc_effect.Poll_result.last_ok_response = None;
    last_error = None;
    inflight_query = None;
    refresh = Effect.Ignore;
  }

let empty_page ~path ~navigate =
  Vdom.Node.div
    ~attrs:[ Vdom.Attr.class_ "page not-found-page" ]
    [
      Vdom.Node.p
        ~attrs:[ Vdom.Attr.class_ "eyebrow" ]
        [ Vdom.Node.text "Route not found" ];
      Vdom.Node.h2 [ Vdom.Node.text path ];
      Vdom.Node.p
        [
          Vdom.Node.text
            "This path is not part of the nixploy control plane. The URL has \
             not been changed.";
        ];
      Ui_helpers.route_link ~class_name:"button button-primary"
        ~route:Route.Home ~navigate
        [ Vdom.Node.text "Return home" ];
    ]

let component graph =
  let route, set_route =
    Bonsai.state (Browser_navigation.initial_route ()) graph
  in
  let mobile_open, set_mobile_open = Bonsai.state false graph in
  let preview, set_preview = Bonsai.state None graph in
  let deploy_state, set_deploy_state = Bonsai.state Deploy_state.Idle graph in
  let cancel_confirmation, set_cancel_confirmation = Bonsai.state None graph in
  let prune_state, set_prune_state = Bonsai.state Prune_state.Idle graph in
  let search, set_search = Bonsai.state "" graph in
  let current_match, set_current_match = Bonsai.state 0 graph in
  let follow, set_follow = Bonsai.state true graph in
  let paused_snapshot, set_paused_snapshot = Bonsai.state None graph in
  let notice, set_notice = Bonsai.state "" graph in
  let applications_observations, inject_applications_observation =
    Bonsai.state_machine0 ~default_model:Last_good.empty
      ~apply_action:(fun _ observations (query, response) ->
        Last_good.update ~equal_query:[%equal: unit] observations ~query
          ~response)
      ~sexp_of_model:(fun _ -> Sexp.Atom "application observations")
      ~sexp_of_action:(fun _ -> Sexp.Atom "application observation")
      graph
  in
  let on_applications_response =
    let%arr inject = inject_applications_observation in
    fun query response -> inject (query, response)
  in
  let _applications =
    Rpc_effect.Rpc.poll ~clear_when_deactivated:false
      ~on_response_received:on_applications_response
      Protocol.List_applications.t ~where_to_connect:Self
      ~equal_query:[%equal: unit]
      ~equal_response:[%equal: Protocol.Application.t list Or_error.t]
      ~every:(Time_ns.Span.of_sec 1.) (Bonsai.return ()) graph
  in
  let application_list =
    let%arr observations = applications_observations in
    Last_good.value ~equal_query:[%equal: unit] observations ~query:()
  in
  let deployments_query =
    let%arr route = route in
    {
      Protocol.List_deployments.Query.application =
        Option.map
          (Route.application_key route)
          ~f:Route.Application_key.to_string;
    }
  in
  let deployments_observations, inject_deployments_observation =
    Bonsai.state_machine0 ~default_model:Last_good.empty
      ~apply_action:(fun _ observations (query, response) ->
        Last_good.update
          ~equal_query:[%equal: Protocol.List_deployments.Query.t] observations
          ~query ~response)
      ~sexp_of_model:(fun _ -> Sexp.Atom "deployment observations")
      ~sexp_of_action:(fun _ -> Sexp.Atom "deployment observation")
      graph
  in
  let on_deployments_response =
    let%arr inject = inject_deployments_observation in
    fun query response -> inject (query, response)
  in
  let deployments_page =
    let%arr route = route and applications = application_list in
    match route with
    | Route.Home -> true
    | Application key ->
        Option.value_map applications ~default:true ~f:(fun applications ->
            List.exists applications ~f:(fun application ->
                String.equal application.Protocol.Application.key
                  (Route.Application_key.to_string key)))
    | Apps | Telemetry | Not_found _ -> false
  in
  let _deployments =
    match%sub deployments_page with
    | true ->
        Rpc_effect.Rpc.poll ~clear_when_deactivated:false
          ~on_response_received:on_deployments_response
          Protocol.List_deployments.t ~where_to_connect:Self
          ~equal_query:[%equal: Protocol.List_deployments.Query.t]
          ~equal_response:[%equal: Protocol.Recent_deployment.t list Or_error.t]
          ~every:(Time_ns.Span.of_sec 1.) deployments_query graph
    | false -> Bonsai.return (empty_poll_result ())
  in
  let logs_query =
    let%arr route = route in
    {
      Protocol.Get_application_logs.Query.application =
        Option.map
          (Route.application_key route)
          ~f:Route.Application_key.to_string;
    }
  in
  let logs_observations, inject_logs_observation =
    Bonsai.state_machine0 ~default_model:Last_good.empty
      ~apply_action:(fun _ observations (query, response) ->
        Last_good.update
          ~equal_query:[%equal: Protocol.Get_application_logs.Query.t]
          observations ~query ~response)
      ~sexp_of_model:(fun _ -> Sexp.Atom "log observations")
      ~sexp_of_action:(fun _ -> Sexp.Atom "log observation")
      graph
  in
  let on_logs_response =
    let%arr inject = inject_logs_observation in
    fun query response -> inject (query, response)
  in
  let logs_page =
    let%arr route = route and applications = application_list in
    match route with
    | Route.Application key ->
        Option.value_map applications ~default:true ~f:(fun applications ->
            List.exists applications ~f:(fun application ->
                String.equal application.Protocol.Application.key
                  (Route.Application_key.to_string key)))
    | Home | Apps | Telemetry | Not_found _ -> false
  in
  let logs =
    match%sub logs_page with
    | true ->
        Rpc_effect.Rpc.poll ~clear_when_deactivated:false
          ~on_response_received:on_logs_response Protocol.Get_application_logs.t
          ~where_to_connect:Self
          ~equal_query:[%equal: Protocol.Get_application_logs.Query.t]
          ~equal_response:[%equal: Protocol.Log_snapshot.t option Or_error.t]
          ~every:(Time_ns.Span.of_sec 2.) logs_query graph
    | false -> Bonsai.return (empty_poll_result ())
  in
  let metrics_observations, inject_metrics_observation =
    Bonsai.state_machine0 ~default_model:Last_good.empty
      ~apply_action:(fun _ observations (query, response) ->
        Last_good.update ~equal_query:[%equal: unit] observations ~query
          ~response)
      ~sexp_of_model:(fun _ -> Sexp.Atom "metric observations")
      ~sexp_of_action:(fun _ -> Sexp.Atom "metric observation")
      graph
  in
  let on_metrics_response =
    let%arr inject = inject_metrics_observation in
    fun query response -> inject (query, response)
  in
  let metrics_page =
    let%arr route = route and applications = application_list in
    match route with
    | Route.Home | Apps | Telemetry -> true
    | Application key ->
        Option.value_map applications ~default:true ~f:(fun applications ->
            List.exists applications ~f:(fun application ->
                String.equal application.Protocol.Application.key
                  (Route.Application_key.to_string key)))
    | Not_found _ -> false
  in
  let _metrics =
    match%sub metrics_page with
    | true ->
        Rpc_effect.Rpc.poll ~clear_when_deactivated:false
          ~on_response_received:on_metrics_response Protocol.Get_metrics.t
          ~where_to_connect:Self ~equal_query:[%equal: unit]
          ~equal_response:[%equal: Protocol.Target_metrics.t list Or_error.t]
          ~every:(Time_ns.Span.of_sec 10.) (Bonsai.return ()) graph
    | false -> Bonsai.return (empty_poll_result ())
  in
  let dispatch_preview =
    Rpc_effect.Rpc.dispatcher Protocol.Preview_deployment.t
      ~where_to_connect:Self graph
  in
  let dispatch_deploy =
    Rpc_effect.Rpc.dispatcher Protocol.Deploy.t ~where_to_connect:Self graph
  in
  let dispatch_cancel =
    Rpc_effect.Rpc.dispatcher Protocol.Cancel_deployment_v1.t
      ~where_to_connect:Self graph
  in
  let dispatch_prune =
    Rpc_effect.Rpc.dispatcher Protocol.Prune.t ~where_to_connect:Self graph
  in
  let route_key =
    let%arr route = route in
    Option.map (Route.application_key route) ~f:Route.Application_key.to_string
  in
  let reset_transient =
    let%arr deploy_state = deploy_state
    and set_preview = set_preview
    and set_deploy_state = set_deploy_state
    and set_cancel_confirmation = set_cancel_confirmation
    and set_prune_state = set_prune_state
    and set_search = set_search
    and set_current_match = set_current_match
    and set_follow = set_follow
    and set_paused_snapshot = set_paused_snapshot
    and set_notice = set_notice in
    fun _ ->
      Effect.Many
        [
          set_preview None;
          set_deploy_state (Deploy_state.reset_for_route_change deploy_state);
          set_cancel_confirmation None;
          set_prune_state Prune_state.Idle;
          set_search "";
          set_current_match 0;
          set_follow true;
          set_paused_snapshot None;
          set_notice "";
        ]
  in
  Bonsai.Edge.on_change route_key
    ~equal:(Option.equal String.equal)
    ~callback:reset_transient graph;
  let observed_operation =
    let%arr deploy_state = deploy_state and applications = application_list in
    match (Deploy_state.awaiting_operation deploy_state, applications) with
    | Some (key, operation_id), Some applications ->
        List.find_map applications ~f:(fun application ->
            if String.equal application.Protocol.Application.key key then
              Option.bind application.deployment ~f:(fun deployment ->
                  if String.equal deployment.Protocol.Deployment.id operation_id
                  then Some (key, operation_id)
                  else None)
            else None)
    | None, _ | Some _, None -> None
  in
  let finish_observed_operation =
    let%arr deploy_state = deploy_state
    and set_deploy_state = set_deploy_state in
    function
    | None -> Effect.Ignore
    | Some (key, operation_id) ->
        set_deploy_state
          (Deploy_state.observe_operation deploy_state ~key ~operation_id)
  in
  Bonsai.Edge.on_change observed_operation
    ~equal:
      (Option.equal (fun (left_key, left_id) (right_key, right_id) ->
           String.equal left_key right_key && String.equal left_id right_id))
    ~callback:finish_observed_operation graph;
  let sync_title =
    let%arr () = Bonsai.return () in
    fun route -> Browser_navigation.set_document_title route
  in
  Bonsai.Edge.on_change route ~equal:Route.equal ~callback:sync_title graph;
  let activate =
    let%arr set_route = set_route and set_mobile_open = set_mobile_open in
    Browser_navigation.start ~on_route:set_route ~on_escape:(fun () ->
        Effect.Many
          [
            set_mobile_open false; Browser_navigation.focus "mobile-menu-button";
          ])
  in
  Bonsai.Edge.lifecycle ~on_activate:activate
    ~on_deactivate:(Bonsai.return (Browser_navigation.cleanup ()))
    graph;
  let%arr route = route
  and set_route = set_route
  and mobile_open = mobile_open
  and set_mobile_open = set_mobile_open
  and applications_observations = applications_observations
  and application_list = application_list
  and deployments_observations = deployments_observations
  and deployments_query = deployments_query
  and logs = logs
  and logs_observations = logs_observations
  and logs_query = logs_query
  and metrics_observations = metrics_observations
  and preview = preview
  and set_preview = set_preview
  and deploy_state = deploy_state
  and set_deploy_state = set_deploy_state
  and cancel_confirmation = cancel_confirmation
  and set_cancel_confirmation = set_cancel_confirmation
  and prune_state = prune_state
  and set_prune_state = set_prune_state
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
  and dispatch_cancel = dispatch_cancel
  and dispatch_prune = dispatch_prune in
  let navigate next =
    let close = set_mobile_open false in
    if Route.equal route next then
      if mobile_open then
        Effect.Many [ close; Browser_navigation.focus "main-content" ]
      else close
    else
      let%bind.Effect () = Browser_navigation.push next in
      Effect.Many
        ([ set_route next; close ]
        @
        if mobile_open then [ Browser_navigation.focus "main-content" ] else []
        )
  in
  let close_mobile =
    Effect.Many
      [ set_mobile_open false; Browser_navigation.focus "mobile-menu-button" ]
  in
  let toggle_mobile =
    if mobile_open then close_mobile
    else
      Effect.Many
        [ set_mobile_open true; Browser_navigation.focus "primary-navigation" ]
  in
  let response value error =
    match (value, error) with
    | Some value, _ -> Some (Ok value)
    | None, Some error -> Some (Error error)
    | None, None -> None
  in
  let applications_error =
    Last_good.error ~equal_query:[%equal: unit] applications_observations
      ~query:()
  in
  let applications_response = response application_list applications_error in
  let deployments_value =
    Last_good.value ~equal_query:[%equal: Protocol.List_deployments.Query.t]
      deployments_observations ~query:deployments_query
  in
  let deployments_error =
    Last_good.error ~equal_query:[%equal: Protocol.List_deployments.Query.t]
      deployments_observations ~query:deployments_query
  in
  let deployments_response = response deployments_value deployments_error in
  let logs_value =
    Last_good.value ~equal_query:[%equal: Protocol.Get_application_logs.Query.t]
      logs_observations ~query:logs_query
  in
  let logs_error =
    Last_good.error ~equal_query:[%equal: Protocol.Get_application_logs.Query.t]
      logs_observations ~query:logs_query
  in
  let logs_response = response logs_value logs_error in
  let metrics_value =
    Last_good.value ~equal_query:[%equal: unit] metrics_observations ~query:()
  in
  let metrics_error =
    Last_good.error ~equal_query:[%equal: unit] metrics_observations ~query:()
  in
  let metrics_response = response metrics_value metrics_error in
  let connection_label, connection_class =
    match (application_list, applications_error) with
    | None, None -> ("Connecting", "status-working")
    | None, Some _ -> ("Connection issue", "status-danger")
    | Some _, Some _ -> ("Connection stale", "status-warning")
    | Some _, None -> ("Connected", "status-ok")
  in
  let content =
    match route with
    | Route.Home ->
        Home_page.render ~applications:applications_response
          ~deployments:deployments_response ~metrics:metrics_response
          ~applications_stale:applications_error
          ~deployments_stale:deployments_error ~metrics_stale:metrics_error
          ~connection_label ~navigate
    | Apps ->
        Apps_page.render ~applications:applications_response
          ~metrics:metrics_response ~applications_stale:applications_error
          ~metrics_stale:metrics_error ~navigate
    | Application route_key ->
        let key = Route.Application_key.to_string route_key in
        let application_state =
          match applications_response with
          | None -> Application_page.Loading
          | Some (Error error) -> Failed error
          | Some (Ok applications) -> (
              match
                List.find applications ~f:(fun application ->
                    String.equal application.Protocol.Application.key key)
              with
              | None -> Missing
              | Some application -> Ready application)
        in
        Application_page.render ~key ~application_state
          ~deployments:deployments_response ~logs:logs_response
          ~metrics:metrics_response ~deployments_stale:deployments_error
          ~logs_stale:logs_error ~metrics_stale:metrics_error ~preview
          ~deploy_state ~cancel_confirmation ~prune_state ~search ~current_match
          ~follow ~paused_snapshot ~dispatch_preview ~dispatch_deploy
          ~dispatch_cancel ~dispatch_prune ~set_preview ~set_deploy_state
          ~set_cancel_confirmation ~set_prune_state ~set_search
          ~set_current_match ~set_follow ~set_paused_snapshot ~set_notice
          ~refresh_logs:logs.refresh ~navigate
    | Telemetry ->
        Telemetry_page.render ~metrics:metrics_response ~stale:metrics_error
          ~navigate
    | Not_found path -> empty_page ~path ~navigate
  in
  Shell.render ~route ~applications:application_list ~connection_label
    ~connection_class ~mobile_open ~navigate ~on_toggle_mobile:toggle_mobile
    ~on_close_mobile:close_mobile ~notice ~content
