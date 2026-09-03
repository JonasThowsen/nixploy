open! Core
open! Async
module Managed_application = Nixploy.Managed_application
module Application = Nixploy.Application
module Authorization = Nixploy_rpc_mapping.Authorization
module Cancellation_request = Nixploy_rpc_mapping.Cancellation_request
module Capability_grant = Nixploy_rpc_mapping.Capability_grant

module Control_plane_capabilities =
  Nixploy_rpc_mapping.Control_plane_capabilities

module Consumer_response = Nixploy_rpc_mapping.Consumer_response
module Deployment_start = Nixploy_rpc_mapping.Deployment_start

module Managed_deployment_admission_rpc =
  Nixploy_rpc_mapping.Managed_deployment_admission_rpc

module Managed_deployment_rpc = Nixploy_rpc_mapping.Managed_deployment_rpc
module Prune_request = Nixploy_rpc_mapping.Prune_request
module Static_route = Nixploy_rpc_mapping.Static_route

type state = {
  applications : Managed_application.t list;
  application : Application.t;
  capabilities : Control_plane_capabilities.t;
}

type connection_state = {
  identity : Capability_grant.identity option;
  grant : Capability_grant.t option ref;
}

let now_ms () = Caml_unix.gettimeofday () *. 1000. |> Int64.of_float

let protocol_deployment state scope deployment =
  Consumer_response.deployment ~now_ms:(now_ms ())
    ~can_cancel:
      (Application.deployment_can_cancel state.application ~scope deployment)
    deployment

let find_application state key = Managed_application.find state.applications key
let scope application = Application.managed_scope application
let max_concurrent_application_observations = 4

let get_control_plane_capabilities state _connection query =
  Deferred.return
    (Control_plane_capabilities.negotiate_client_capabilities state.capabilities
       query)

let get_control_plane_capabilities_v1 state connection query =
  match connection.identity with
  | None ->
      Deferred.Or_error.error_string
        "NIXPLOY_AUTHENTICATED_IDENTITY_REQUIRED: managed capability grants require Tailscale authentication"
  | Some identity -> (
      match
        Control_plane_capabilities.negotiate_client_capabilities state.capabilities
          query
      with
      | Error _ as error -> Deferred.return error
      | Ok capabilities ->
          let grant =
            Capability_grant.create (Capability_grant.system_factory ()) ~identity
              ~capabilities:query.required_capabilities
              ~package_revision:capabilities.package_revision
              ~protocol_major:capabilities.protocol_major
              ~protocol_minor:capabilities.protocol_minor
          in
          Or_error.map grant ~f:(fun grant ->
              connection.grant := Some grant;
              {
                Protocol.Control_plane_capabilities.V1.Response.control_plane_id =
                  capabilities.control_plane_id;
                package_revision = capabilities.package_revision;
                protocol_major = capabilities.protocol_major;
                protocol_minor = capabilities.protocol_minor;
                deployment_config_schemas = capabilities.deployment_config_schemas;
                capabilities = capabilities.capabilities;
                capability_grant = Capability_grant.token grant;
                server_time_ms = Capability_grant.issued_at_ms grant;
                grant_expires_at_ms = Capability_grant.expires_at_ms grant;
              })
          |> Deferred.return)

let legacy_managed_rpc_error () =
  Deferred.Or_error.error_string
    "NIXPLOY_CAPABILITY_GRANT_REQUIRED: upgrade to a grant-bearing managed RPC version"

let with_control_plane_capability ~capability:_ _handler _state _connection _query =
  legacy_managed_rpc_error ()

let require_control_plane_capability state connection ~capability ~token =
  match (connection.identity, !(connection.grant)) with
  | _, None ->
      Or_error.error_string
        "NIXPLOY_CAPABILITY_GRANT_REQUIRED: call get-control-plane-capabilities version 1 first"
  | None, Some _ ->
      Or_error.error_string
        "NIXPLOY_AUTHENTICATED_IDENTITY_REQUIRED: managed capability grants require Tailscale authentication"
  | Some identity, Some grant ->
      let result =
        Capability_grant.validate grant ~token ~identity
          ~package_revision:(Control_plane_capabilities.package_revision state.capabilities)
          ~protocol_major:1 ~protocol_minor:0 ~capability ~now_ms:(now_ms ())
      in
      (match result with
      | Ok () -> Ok ()
      | Error error ->
          if String.is_substring (Error.to_string_hum error) ~substring:"EXPIRED" then
            connection.grant := None;
          Error error)

let with_capability_grant ~capability ~token handler state connection query =
  match require_control_plane_capability state connection ~capability ~token:(token query) with
  | Error error -> Deferred.return (Error error)
  | Ok () -> handler state connection query

let list_applications state _connection_state () =
  Deferred.Or_error.List.map state.applications
    ~how:(`Max_concurrent_jobs max_concurrent_application_observations)
    ~f:(fun application ->
      let open Deferred.Or_error.Let_syntax in
      let%bind scope = Deferred.return (scope application) in
      let%bind deployments =
        Application.deployment_history state.application ~scope ~limit:1
      in
      let%map resource_state =
        Deferred.map
          (Application.live_resource_state_for_scope state.application ~scope)
          ~f:Or_error.return
      in
      Consumer_response.application application ~resource_state
        ~deployment:
          (List.hd deployments
          |> Option.map ~f:(protocol_deployment state scope)))

let preview_deployment state _connection_state query =
  Managed_deployment_rpc.preview ~applications:state.applications
    ~application:state.application query

let deploy state _connection_state query =
  Managed_deployment_rpc.start ~applications:state.applications
    ~application:state.application query

let admit_managed_deployment state connection query =
  match
    require_control_plane_capability state connection ~capability:"managed-deploy-v1"
      ~token:query.Protocol.Admit_managed_deployment.Query.capability_grant
  with
  | Error error -> Deferred.return (Error error)
  | Ok () ->
      Managed_deployment_admission_rpc.handle ~applications:state.applications
        ~application:state.application query

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
        Rpc.Rpc.implement Protocol.Control_plane_capabilities.t
          (get_control_plane_capabilities state);
        Rpc.Rpc.implement Protocol.Control_plane_capabilities.V1.t
          (get_control_plane_capabilities_v1 state);
        Rpc.Rpc.implement Protocol.List_applications.t
          (with_control_plane_capability ~capability:"managed-read-v1"
             list_applications state);
        Rpc.Rpc.implement Protocol.List_applications.V1.t
          (with_capability_grant ~capability:"managed-read-v1"
             ~token:(fun query -> query.Protocol.List_applications.V1.Query.capability_grant)
             (fun state connection _query -> list_applications state connection ()) state);
        Rpc.Rpc.implement Protocol.Preview_deployment.t
          (with_control_plane_capability ~capability:"managed-deploy-v1"
             preview_deployment state);
        Rpc.Rpc.implement Protocol.Preview_deployment.V1.t
          (with_capability_grant ~capability:"managed-deploy-v1"
             ~token:(fun query -> query.Protocol.Preview_deployment.V1.Query.capability_grant)
             (fun state connection query ->
               preview_deployment state connection
                 { Protocol.Preview_deployment.Query.application = query.application }) state);
        Rpc.Rpc.implement Protocol.Deploy.t
          (with_control_plane_capability ~capability:"managed-deploy-v1" deploy
             state);
        Rpc.Rpc.implement Protocol.Deploy.V1.t
          (with_capability_grant ~capability:"managed-deploy-v1"
             ~token:(fun query -> query.Protocol.Deploy.V1.Query.capability_grant)
             (fun state connection query ->
               deploy state connection
                 { Protocol.Deploy.Query.application = query.application }) state);
        Rpc.Rpc.implement Protocol.Admit_managed_deployment.t
          (admit_managed_deployment state);
        Rpc.Rpc.implement Protocol.List_deployments.t
          (with_control_plane_capability ~capability:"managed-read-v1"
             list_deployments state);
        Rpc.Rpc.implement Protocol.List_deployments.V1.t
          (with_capability_grant ~capability:"managed-read-v1"
             ~token:(fun query -> query.Protocol.List_deployments.V1.Query.capability_grant)
             (fun state connection query ->
               list_deployments state connection
                 { Protocol.List_deployments.Query.application = query.application }) state);
        Rpc.Rpc.implement Protocol.Cancel_deployment.t
          (with_control_plane_capability ~capability:"managed-cancel-v1"
             cancel_deployment_v0 state);
        Rpc.Rpc.implement Protocol.Cancel_deployment_v1.t
          (with_control_plane_capability ~capability:"managed-cancel-v1"
             cancel_deployment state);
        Rpc.Rpc.implement Protocol.Cancel_deployment_v1.V1.t
          (with_capability_grant ~capability:"managed-cancel-v1"
             ~token:(fun query -> query.Protocol.Cancel_deployment_v1.V1.Query.capability_grant)
             (fun state connection query ->
               cancel_deployment state connection
                 {
                   Protocol.Cancel_deployment_v1.Query.application = query.application;
                   operation_id = query.operation_id;
                 }) state);
        Rpc.Rpc.implement Protocol.Prune.t
          (with_control_plane_capability ~capability:"managed-prune-v1" prune
             state);
        Rpc.Rpc.implement Protocol.Prune.V1.t
          (with_capability_grant ~capability:"managed-prune-v1"
             ~token:(fun query -> query.Protocol.Prune.V1.Query.capability_grant)
             (fun state connection query ->
               prune state connection
                 {
                   Protocol.Prune.Query.application = query.application;
                   receipt = query.receipt;
                 }) state);
        Rpc.Rpc.implement Protocol.Get_application_logs.t
          (with_control_plane_capability ~capability:"managed-read-v1"
             get_application_logs state);
        Rpc.Rpc.implement Protocol.Get_application_logs.V1.t
          (with_capability_grant ~capability:"managed-read-v1"
             ~token:(fun query -> query.Protocol.Get_application_logs.V1.Query.capability_grant)
             (fun state connection query ->
               get_application_logs state connection
                 { Protocol.Get_application_logs.Query.application = query.application }) state);
        Rpc.Rpc.implement Protocol.Get_metrics.t
          (with_control_plane_capability ~capability:"managed-read-v1"
             get_metrics state);
        Rpc.Rpc.implement Protocol.Get_metrics.V1.t
          (with_capability_grant ~capability:"managed-read-v1"
             ~token:(fun query -> query.Protocol.Get_metrics.V1.Query.capability_grant)
             (fun state connection _query -> get_metrics state connection ()) state);
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
  | "/healthz" when Authorization.authorized authorization request.headers ->
      respond_string ~content_type:"text/plain" "ok\n"
  | "/healthz" -> forbidden ()
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

let identity_for_connection authorization = function
  | Rpc_websocket.Rpc.Connection_initiated_from.Websocket_request request ->
      Authorization.authenticated_identity authorization request.headers
      |> Result.map ~f:(function
           | Authorization.Tailscale_login login -> Capability_grant.Tailscale_login login)
      |> Result.ok
  | Tcp -> None

let mutation_drain_timeout = Time_ns.Span.of_sec 25.

let run ~port ~state_db ~trusted_tailscale_loopback_proxy =
  let open Deferred.Let_syntax in
  Nixploy.Process_runner.handle_termination_signals ();
  let applications =
    Managed_application.load_authority_file () |> Or_error.ok_exn
  in
  let authorization =
    Authorization.load_environment ~trusted_tailscale_loopback_proxy ()
    |> Or_error.ok_exn
  in
  let origin_policy = Authorization.load_origin_policy () |> Or_error.ok_exn in
  let%bind application =
    Application.open_ ~managed_applications:applications ~state_path:state_db ()
    >>| Or_error.ok_exn
  in
  let capabilities =
    Control_plane_capabilities.create
      ~control_plane_id:
        (Sys.getenv "NIXPLOY_CONTROL_PLANE_ID"
        |> Option.value ~default:(Caml_unix.gethostname ()))
      ~package_revision:
        (Sys.getenv "NIXPLOY_PACKAGE_REVISION"
        |> Option.value ~default:"unknown")
    |> Or_error.ok_exn
  in
  let state = { applications; application; capabilities } in
  let%bind server =
    Rpc_websocket.Rpc.serve ~on_handler_error:`Raise ~mode:`TCP
      ~where_to_listen:(Tcp.Where_to_listen.bind_to Localhost (On_port port))
      ~http_handler:(fun () -> http_handler ~authorization)
      ~should_process_request:
        (should_process_request authorization origin_policy)
      ~implementations:(implementations state)
      ~initial_connection_state:(fun () initiated_from _address _connection ->
        { identity = identity_for_connection authorization initiated_from; grant = ref None })
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
     and trusted_tailscale_loopback_proxy =
       flag "--trusted-tailscale-loopback-proxy" no_arg
         ~doc:
           "Allow Tailscale identity headers only behind a root-owned loopback output-firewall policy"
     in
     fun () -> run ~port ~state_db ~trusted_tailscale_loopback_proxy)

let () = Command_unix.run command
