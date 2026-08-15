open! Core
open! Async
module Managed_application = Nixploy.Managed_application
module Application = Nixploy.Application
module Authorization = Nixploy_rpc_mapping.Authorization
module Cancellation_request = Nixploy_rpc_mapping.Cancellation_request
module Deployment_start = Nixploy_rpc_mapping.Deployment_start
module Prune_request = Nixploy_rpc_mapping.Prune_request
module Resource_state_response = Nixploy_rpc_mapping.Resource_state_response

type state = {
  applications : Managed_application.t list;
  application : Application.t;
}

let now_ms () = Caml_unix.gettimeofday () *. 1000. |> Int64.of_float

let protocol_state = function
  | Application.Requested -> Protocol.Deployment.State.Requested
  | Running -> Running
  | Succeeded -> Succeeded
  | Failed -> Failed
  | Cancelled -> Cancelled

let is_active deployment =
  match Application.deployment_state deployment with
  | Requested | Running -> true
  | Succeeded | Failed | Cancelled -> false

let protocol_commit deployment =
  Application.deployment_revision deployment
  |> Option.map ~f:(fun revision ->
      {
        Protocol.Commit.revision;
        subject =
          Application.deployment_commit_subject deployment
          |> Option.value ~default:"Commit subject unavailable";
        timestamp_ms =
          Application.deployment_commit_timestamp_ms deployment
          |> Option.value
               ~default:(Application.deployment_requested_at_ms deployment);
      })

let protocol_deployment state scope deployment =
  let started_at_ms = Application.deployment_started_at_ms deployment in
  let finished_at_ms = Application.deployment_finished_at_ms deployment in
  {
    Protocol.Deployment.id = Application.deployment_id deployment;
    state = protocol_state (Application.deployment_state deployment);
    stage = Application.deployment_stage deployment;
    message = Application.deployment_message deployment;
    commit = protocol_commit deployment;
    container_name = Application.deployment_container_name deployment;
    error = Application.deployment_error deployment;
    requested_at_ms = Application.deployment_requested_at_ms deployment;
    started_at_ms;
    finished_at_ms;
    elapsed_ms =
      Option.map started_at_ms ~f:(fun started ->
          let finished = Option.value finished_at_ms ~default:(now_ms ()) in
          Int64.max 0L Int64.(finished - started));
    cancel_requested_at_ms =
      Application.deployment_cancel_requested_at_ms deployment;
    updated_at_ms = Application.deployment_updated_at_ms deployment;
    can_cancel =
      is_active deployment
      && Application.deployment_can_cancel state.application ~scope deployment;
  }

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
      {
        Protocol.Application.key = Managed_application.key application;
        project =
          Managed_application.project application
          |> Nixploy.Project_name.to_string;
        target =
          Managed_application.target application
          |> Nixploy.Target_name.to_string;
        repository = Managed_application.repository_identity application;
        resource_state = Resource_state_response.of_application resource_state;
        deployment =
          List.hd deployments |> Option.map ~f:(protocol_deployment state scope);
      })

let preview_deployment state _connection_state query =
  match
    find_application state query.Protocol.Preview_deployment.Query.application
  with
  | Error _ as error -> Deferred.return error
  | Ok application ->
      let%map preview =
        Application.preview_main_commit state.application
          ~working_directory:(Managed_application.working_directory application)
      in
      Or_error.map preview ~f:(fun commit ->
          {
            Protocol.Commit.revision = Application.commit_revision commit;
            subject = Application.commit_subject commit;
            timestamp_ms = Application.commit_timestamp_ms commit;
          })

let deploy state _connection_state query =
  match find_application state query.Protocol.Deploy.Query.application with
  | Error _ as error -> Deferred.return error
  | Ok managed -> (
      let working_directory = Managed_application.working_directory managed in
      let%bind commit =
        Application.resolve_commit state.application ~working_directory
          ~revision:query.Protocol.Deploy.Query.revision
      in
      match commit with
      | Error _ as error -> Deferred.return error
      | Ok commit ->
          let started = Ivar.create () in
          let execution =
            Application.deploy
              ~on_requested:(fun operation ->
                Ivar.fill_if_empty started
                  (Deployment_start.operation_id operation))
              ~application_key:(Managed_application.key managed)
              ~expected_project:(Deployment_start.expected_project managed)
              state.application ~working_directory
              ~source:
                (Application.immutable_source
                   ~repository_identity:
                     (Managed_application.repository_identity managed)
                   commit)
              ~target:(Managed_application.target managed)
              ()
          in
          don't_wait_for
            (let%map result = execution in
             match result with
             | Ok _ -> ()
             | Error error ->
                 eprintf "Deployment task failed: %s\n%!"
                   (Error.to_string_hum error));
          Deferred.choose
            [
              Deferred.choice (Ivar.read started) Or_error.return;
              Deferred.choice execution (function
                | Error error -> Error error
                | Ok deployment -> Ok (Deployment_start.operation_id deployment));
            ])

let prune state _connection_state query =
  Prune_request.handle ~applications:state.applications
    ~prune:(fun ~application ->
      Application.prune
        ~application_key:(Managed_application.key application)
        ~expected_project:(Managed_application.project application)
        ~repository_identity:
          (Managed_application.repository_identity application)
        state.application
        ~working_directory:(Managed_application.working_directory application)
        ~target:(Managed_application.target application))
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
          Or_error.map result ~f:(fun _ -> ()))
    query

let recent_for_application state application ~limit =
  let open Deferred.Or_error.Let_syntax in
  let%bind scope = Deferred.return (scope application) in
  let%map deployments =
    Application.deployment_history state.application ~scope ~limit
  in
  List.map deployments ~f:(fun deployment ->
      {
        Protocol.Recent_deployment.application =
          Managed_application.key application;
        deployment = protocol_deployment state scope deployment;
      })

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
              Some
                {
                  Protocol.Log_snapshot.application = key;
                  container_name = snapshot.container_name;
                  revision = snapshot.revision;
                  observed_at_ms = snapshot.observed_at_ms;
                  lines =
                    List.map snapshot.lines ~f:(fun line ->
                        {
                          Protocol.Log_line.timestamp = line.timestamp;
                          text = line.text;
                        });
                  truncated = snapshot.truncated;
                }))

let protocol_health = function
  | Application.Healthy -> Protocol.Health.Healthy
  | Unhealthy -> Unhealthy
  | Unavailable error -> Unavailable error

let protocol_metrics (metrics : Application.target_metrics) =
  {
    Protocol.Target_metrics.target = metrics.target;
    host = metrics.host;
    observed_at_ms = metrics.observed_at_ms;
    error = metrics.error;
    cpu_percent = metrics.cpu_percent;
    memory_used_bytes = metrics.memory_used_bytes;
    memory_total_bytes = metrics.memory_total_bytes;
    filesystem_used_bytes = metrics.filesystem_used_bytes;
    filesystem_total_bytes = metrics.filesystem_total_bytes;
    load_1 = metrics.load_1;
    load_5 = metrics.load_5;
    load_15 = metrics.load_15;
    uptime_seconds = metrics.uptime_seconds;
    applications =
      List.map metrics.applications ~f:(fun application ->
          {
            Protocol.Application_metrics.application = application.application;
            container_name = application.container_name;
            health = protocol_health application.health;
            error = application.error;
            cpu_percent = application.cpu_percent;
            memory_used_bytes = application.memory_used_bytes;
            memory_host_percent = application.memory_host_percent;
            uptime_seconds = application.uptime_seconds;
          });
  }

let merge_target_metrics targets (metric : Protocol.Target_metrics.t) =
  match
    List.findi targets ~f:(fun _ existing ->
        String.equal existing.Protocol.Target_metrics.host metric.host
        && not (String.equal existing.host "unavailable"))
  with
  | None -> targets @ [ metric ]
  | Some (index, existing) ->
      List.mapi targets ~f:(fun current item ->
          if Int.equal current index then
            {
              existing with
              applications = existing.applications @ metric.applications;
            }
          else item)

let get_metrics state _connection_state () =
  let%map metrics =
    Deferred.List.map state.applications ~how:`Parallel ~f:(fun application ->
        Application.application_metrics state.application application
        >>| protocol_metrics)
  in
  Ok (List.fold metrics ~init:[] ~f:merge_target_metrics)

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
    <meta name="theme-color" content="#171914">
    <title>Nixploy / Deployment ledger</title>
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
  | ("" | "/" | "/index.html")
    when Authorization.authorized authorization request.headers ->
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
  | "" | "/" | "/index.html" -> forbidden ()
  | _ -> respond_string ~content_type:"text/html" ~status:`Not_found not_found

let should_process_request authorization origin_policy _address = function
  | Rpc_websocket.Rpc.Connection_source.Plain_tcp ->
      Or_error.error_string "plain TCP RPC is disabled"
  | Web (_headers, `is_websocket_request false) -> Ok ()
  | Web (headers, `is_websocket_request true) ->
      Authorization.authorize_websocket authorization origin_policy headers

let run ~port ~state_db =
  let open Deferred.Let_syntax in
  let applications =
    Managed_application.load_environment () |> Or_error.ok_exn
  in
  let authorization = Authorization.load_environment () |> Or_error.ok_exn in
  let origin_policy = Authorization.load_origin_policy () |> Or_error.ok_exn in
  let%bind application =
    Application.open_ ~state_path:state_db >>| Or_error.ok_exn
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
  Cohttp_async.Server.close_finished server

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
