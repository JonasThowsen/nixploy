open! Core
open! Async
module Managed_application = Nixploy.Managed_application
module Application = Nixploy.Application
module Authorization = Nixploy_rpc_mapping.Authorization
module Cancellation_request = Nixploy_rpc_mapping.Cancellation_request
module Consumer_response = Nixploy_rpc_mapping.Consumer_response
module Deployment_start = Nixploy_rpc_mapping.Deployment_start
module Prune_request = Nixploy_rpc_mapping.Prune_request
module Static_route = Nixploy_rpc_mapping.Static_route

type state = {
  applications : Managed_application.t list;
  application : Application.t;
}

let now_ms () = Caml_unix.gettimeofday () *. 1000. |> Int64.of_float

let protocol_deployment state scope deployment =
  Consumer_response.deployment ~now_ms:(now_ms ())
    ~can_cancel:
      (Application.deployment_can_cancel state.application ~scope deployment)
    deployment

let find_application state key = Managed_application.find state.applications key
let scope application = Application.managed_scope application

let list_applications state _connection_state () =
  Deferred.Or_error.List.map state.applications ~how:`Parallel
    ~f:(fun application ->
      let open Deferred.Or_error.Let_syntax in
      let%bind scope = Deferred.return (scope application) in
      let%bind deployments =
        Application.deployment_history state.application ~scope ~limit:1
      in
      let%map resource_state =
        Application.resource_state_for_scope state.application ~scope
      in
      Consumer_response.application application ~resource_state
        ~deployment:
          (List.hd deployments
          |> Option.map ~f:(protocol_deployment state scope)))

let preview_deployment state _connection_state query =
  match
    find_application state query.Protocol.Preview_deployment.Query.application
  with
  | Error _ as error -> Deferred.return error
  | Ok application ->
      let%map preview =
        Application.preview_managed_deployment state.application application
      in
      Or_error.map preview ~f:(fun preview ->
          let commit = Application.deployment_preview_commit preview in
          {
            Protocol.Deployment_preview.commit =
              {
                Protocol.Commit.revision = Application.commit_revision commit;
                subject = Application.commit_subject commit;
                timestamp_ms = Application.commit_timestamp_ms commit;
              };
            receipt = Application.deployment_preview_receipt preview;
            prune_receipt = Application.deployment_preview_prune_receipt preview;
          })

let deploy state _connection_state query =
  match find_application state query.Protocol.Deploy.Query.application with
  | Error _ as error -> Deferred.return error
  | Ok managed ->
      let%map started =
        Application.start_managed_deployment state.application managed
      in
      Result.map started ~f:Application.started_deployment_id

let prune state _connection_state query =
  Prune_request.handle ~applications:state.applications
    ~prune:(fun ~application ->
      Application.prune_managed_preview state.application application
        ~receipt:query.Protocol.Prune.Query.receipt)
    query

let cancel_deployment_v0 _state _connection_state _query =
  Deferred.Or_error.error_string
    "cancel-deployment version 1 requires an application identity"

let cancel_deployment state _connection_state query =
  Cancellation_request.handle ~applications:state.applications
    ~cancel:(fun ~application ~operation_id ->
      match scope application with
      | Error error -> Deferred.return (Error error)
      | Ok scope ->
          let%map result =
            Application.cancel_deployment state.application ~scope ~operation_id
          in
          Or_error.map result ~f:Consumer_response.cancellation)
    query

let recent_for_application state application ~limit =
  let open Deferred.Or_error.Let_syntax in
  let%bind scope = Deferred.return (scope application) in
  let%map deployments =
    Application.deployment_history state.application ~scope ~limit
  in
  List.map deployments ~f:(fun deployment ->
      Consumer_response.recent_deployment ~application
        ~deployment:(protocol_deployment state scope deployment))

let list_deployments state _connection_state query =
  match query.Protocol.List_deployments.Query.application with
  | Some key -> (
      match find_application state key with
      | Error error -> Deferred.return (Error error)
      | Ok application -> recent_for_application state application ~limit:25)
  | None ->
      let%map result =
        Deferred.Or_error.List.map state.applications ~how:`Parallel
          ~f:(fun application ->
            recent_for_application state application ~limit:50)
      in
      Or_error.map result ~f:(fun histories ->
          List.concat histories
          |> List.sort ~compare:(fun left right ->
              Int64.compare
                right.Protocol.Recent_deployment.deployment.requested_at_ms
                left.deployment.requested_at_ms)
          |> Fn.flip List.take 50)

let get_application_logs state _connection_state query =
  match query.Protocol.Get_application_logs.Query.application with
  | None -> Deferred.Or_error.return None
  | Some key -> (
      match find_application state key with
      | Error _ as error -> Deferred.return error
      | Ok application ->
          let%map result =
            Application.application_logs state.application application
          in
          Or_error.map result ~f:(fun snapshot ->
              Some (Consumer_response.log_snapshot ~application:key snapshot)))

let get_metrics state _connection_state () =
  let%map metrics =
    Consumer_response.collect_metrics state.applications
      ~observe:(Application.application_metrics state.application)
  in
  Ok metrics

let implementations state =
  Rpc.Implementations.create_exn
    ~implementations:
      [
        Rpc.Rpc.implement Protocol.List_applications.t (list_applications state);
        Rpc.Rpc.implement Protocol.Preview_deployment.t
          (preview_deployment state);
        Rpc.Rpc.implement Protocol.Deploy.t (deploy state);
        Rpc.Rpc.implement Protocol.List_deployments.t (list_deployments state);
        Rpc.Rpc.implement Protocol.Cancel_deployment.t
          (cancel_deployment_v0 state);
        Rpc.Rpc.implement Protocol.Cancel_deployment_v1.t
          (cancel_deployment state);
        Rpc.Rpc.implement Protocol.Prune.t (prune state);
        Rpc.Rpc.implement Protocol.Get_application_logs.t
          (get_application_logs state);
        Rpc.Rpc.implement Protocol.Get_metrics.t (get_metrics state);
      ]
    ~on_unknown_rpc:`Continue

let respond_string ~content_type ?status body =
  let headers =
    Cohttp.Header.init_with "Content-Type" content_type |> fun headers ->
    Cohttp.Header.add headers "X-Content-Type-Options" "nosniff"
    |> fun headers -> Cohttp.Header.add headers "X-Frame-Options" "DENY"
  in
  Cohttp_async.Server.respond_string ~headers ?status body

let forbidden () =
  respond_string ~content_type:"text/plain" ~status:`Forbidden
    "Tailscale identity is not authorized for nixploy\n"

let html =
  {|
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="theme-color" content="#242825">
    <title>Nixploy</title>
    <link rel="stylesheet" href="/app.css">
    <script defer src="/main.js"></script>
  </head>
  <body><div id="app"></div></body>
</html>
|}

let not_found =
  {|<!doctype html><html lang="en"><body><h1>Not found</h1></body></html>|}

let http_handler ~authorization ~body:_ _address request =
  match Uri.path (Cohttp.Request.uri request) with
  | "/healthz" -> respond_string ~content_type:"text/plain" "ok\n"
  | path
    when Static_route.serves_spa_shell path
         && Authorization.authorized authorization request.headers ->
      respond_string ~content_type:"text/html" html
  | "/main.js" ->
      if Authorization.authorized authorization request.headers then
        respond_string ~content_type:"application/javascript"
          Embedded_files.main_dot_bc_dot_js
      else forbidden ()
  | "/app.css" ->
      if Authorization.authorized authorization request.headers then
        respond_string ~content_type:"text/css" Embedded_files.app_dot_css
      else forbidden ()
  | "/fonts/ibm-plex-mono-400.ttf" ->
      if Authorization.authorized authorization request.headers then
        respond_string ~content_type:"font/ttf"
          Embedded_files.ibm_plex_mono_400_dot_ttf
      else forbidden ()
  | "/fonts/ibm-plex-mono-600.ttf" ->
      if Authorization.authorized authorization request.headers then
        respond_string ~content_type:"font/ttf"
          Embedded_files.ibm_plex_mono_600_dot_ttf
      else forbidden ()
  | path when Static_route.serves_spa_shell path -> forbidden ()
  | _ -> respond_string ~content_type:"text/html" ~status:`Not_found not_found

let should_process_request authorization origin_policy _address = function
  | Rpc_websocket.Rpc.Connection_source.Plain_tcp ->
      Or_error.error_string "plain TCP RPC is disabled"
  | Web (_headers, `is_websocket_request false) -> Ok ()
  | Web (headers, `is_websocket_request true) ->
      Authorization.authorize_websocket authorization origin_policy headers

let mutation_drain_timeout = Time_ns.Span.of_sec 25.

let run ~port ~state_db =
  let open Deferred.Let_syntax in
  Nixploy.Process_runner.handle_termination_signals ();
  let applications =
    Managed_application.load_authority_file () |> Or_error.ok_exn
  in
  let authorization = Authorization.load_environment () |> Or_error.ok_exn in
  let origin_policy = Authorization.load_origin_policy () |> Or_error.ok_exn in
  let%bind application =
    Application.open_ ~managed_applications:applications ~state_path:state_db ()
    >>| Or_error.ok_exn
  in
  let state = { applications; application } in
  let%bind server =
    Rpc_websocket.Rpc.serve ~on_handler_error:`Raise ~mode:`TCP
      ~where_to_listen:(Tcp.Where_to_listen.bind_to Localhost (On_port port))
      ~http_handler:(fun () -> http_handler ~authorization)
      ~should_process_request:
        (should_process_request authorization origin_policy)
      ~implementations:(implementations state)
      ~initial_connection_state:(fun () _initiated_from _address _connection ->
        ())
      ()
  in
  printf "Nixploy control plane listening on http://127.0.0.1:%d/\n%!" port;
  let%bind outcome =
    Deferred.choose
      [
        Deferred.choice (Cohttp_async.Server.close_finished server) (fun () ->
            `Closed);
        Deferred.choice (Nixploy.Process_runner.termination_requested ())
          (fun signal -> `Signal signal);
      ]
  in
  match outcome with
  | `Closed -> Deferred.unit
  | `Signal signal ->
      ignore
        (Application.begin_shutdown application
          : Application.shutdown_transition);
      don't_wait_for (Cohttp_async.Server.close server);
      let%bind drain =
        Deferred.choose
          [
            Deferred.choice (Application.mutations_drained application)
              (fun () -> `Drained);
            Deferred.choice (Clock_ns.after mutation_drain_timeout) (fun () ->
                `Timed_out);
          ]
      in
      (match drain with
      | `Drained -> ()
      | `Timed_out ->
          eprintf
            "Timed out draining deployment mutations after %s; forcing web \
             shutdown\n\
             %!"
            (Time_ns.Span.to_short_string mutation_drain_timeout));
      Shutdown.shutdown_with_signal_exn signal;
      Deferred.unit

let command =
  Async.Command.async ~summary:"Serve the Nixploy deployment control plane"
    (let%map_open.Command port =
       flag "--port"
         (optional_with_default 8080 int)
         ~doc:"PORT HTTP and WebSocket listen port"
     and state_db =
       flag "--state-db"
         (optional_with_default (Nixploy.State_path.default ()) string)
         ~doc:"PATH durable control-plane state database"
     in
     fun () -> run ~port ~state_db)

let () = Command_unix.run command
