open! Core
open! Async
module Managed_application = Nixploy.Managed_application
module Store = Nixploy.Store
module Authorization = Nixploy_rpc_mapping.Authorization
module Deployment_start = Nixploy_rpc_mapping.Deployment_start
module Prune_request = Nixploy_rpc_mapping.Prune_request
module Resource_state_response = Nixploy_rpc_mapping.Resource_state_response

type cached_runtime = {
  mutable expires_at : Time_ns.t;
  value : Nixploy.Runtime_application.t Or_error.t Deferred.t;
}

type state = {
  applications : Managed_application.t list;
  application : Nixploy.Application.t;
  store : Store.t;
  active : Nixploy.Cancellation.t String.Table.t;
  runtime_cache : cached_runtime String.Table.t;
}

let now_ms () = Caml_unix.gettimeofday () *. 1000. |> Int64.of_float

let protocol_state = function
  | Store.Requested -> Protocol.Deployment.State.Requested
  | Running -> Running
  | Succeeded -> Succeeded
  | Failed -> Failed
  | Cancelled -> Cancelled

let is_active deployment =
  match Store.state deployment with
  | Requested | Running -> true
  | Succeeded | Failed | Cancelled -> false

let protocol_commit deployment =
  Store.revision deployment
  |> Option.map ~f:(fun revision ->
      {
        Protocol.Commit.revision;
        subject =
          Store.commit_subject deployment
          |> Option.value ~default:"Commit subject unavailable";
        timestamp_ms =
          Store.commit_timestamp_ms deployment
          |> Option.value ~default:(Store.requested_at_ms deployment);
      })

let protocol_deployment state deployment =
  {
    Protocol.Deployment.id = Store.id deployment;
    state = protocol_state (Store.state deployment);
    stage = Store.stage deployment;
    message = Store.message deployment;
    commit = protocol_commit deployment;
    container_name = Store.container_name deployment;
    error = Store.error deployment;
    requested_at_ms = Store.requested_at_ms deployment;
    started_at_ms = Store.started_at_ms deployment;
    finished_at_ms = Store.finished_at_ms deployment;
    elapsed_ms =
      Option.map (Store.started_at_ms deployment) ~f:(fun started ->
          let finished =
            Store.finished_at_ms deployment |> Option.value ~default:(now_ms ())
          in
          Int64.max 0L Int64.(finished - started));
    cancel_requested_at_ms = Store.cancel_requested_at_ms deployment;
    updated_at_ms = Store.updated_at_ms deployment;
    can_cancel =
      is_active deployment && Hashtbl.mem state.active (Store.id deployment);
  }

let canonical_working_directory application =
  let working_directory = Managed_application.working_directory application in
  Or_error.try_with (fun () -> Filename_unix.realpath working_directory)
  |> Result.ok
  |> Option.value ~default:working_directory

let deployment_matches application deployment =
  Option.equal String.equal
    (Store.application_key deployment)
    (Some (Managed_application.key application))
  || Option.is_none (Store.application_key deployment)
     && String.equal
          (Store.working_directory deployment)
          (canonical_working_directory application)
     && Nixploy.Target_name.equal (Store.target deployment)
          (Managed_application.target application)

let list_applications state _connection_state () =
  Deferred.Or_error.List.map state.applications ~how:`Parallel
    ~f:(fun application ->
      let%bind.Deferred.Or_error deployments =
        Store.list_for_application state.store
          ~application_key:(Managed_application.key application)
          ~working_directory:(canonical_working_directory application)
          ~target:(Managed_application.target application)
          ~limit:1
      in
      let%map.Deferred.Or_error resource_state =
        Nixploy.Application.resource_state state.application
          ~working_directory:(Managed_application.working_directory application)
          ~target:(Managed_application.target application)
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
          List.hd deployments |> Option.map ~f:(protocol_deployment state);
      })

let preview_deployment state _connection_state query =
  match
    Managed_application.find state.applications
      query.Protocol.Preview_deployment.Query.application
  with
  | Error _ as error -> Deferred.return error
  | Ok application ->
      let%map preview =
        Nixploy.Application.preview_main_commit state.application
          ~working_directory:(Managed_application.working_directory application)
      in
      Or_error.map preview ~f:(fun commit ->
          {
            Protocol.Commit.revision =
              Nixploy.Application.commit_revision commit;
            subject = Nixploy.Application.commit_subject commit;
            timestamp_ms = Nixploy.Application.commit_timestamp_ms commit;
          })

let deploy state _connection_state query =
  match
    Managed_application.find state.applications
      query.Protocol.Deploy.Query.application
  with
  | Error _ as error -> Deferred.return error
  | Ok application -> (
      let working_directory =
        Managed_application.working_directory application
      in
      let%bind commit =
        Nixploy.Application.resolve_commit state.application ~working_directory
          ~revision:query.Protocol.Deploy.Query.revision
      in
      match commit with
      | Error _ as error -> Deferred.return error
      | Ok commit ->
          let cancellation = Nixploy.Cancellation.create () in
          let started = Ivar.create () in
          let execution =
            Nixploy.Cancellation.within cancellation (fun () ->
                Nixploy.Application.deploy
                  ~on_requested:(fun operation ->
                    let operation_id =
                      Deployment_start.operation_id operation
                    in
                    Hashtbl.set state.active ~key:operation_id
                      ~data:cancellation;
                    Ivar.fill_if_empty started operation_id)
                  ~application_key:(Managed_application.key application)
                  ~expected_project:
                    (Deployment_start.expected_project application)
                  state.application ~working_directory ~commit
                  ~target:(Managed_application.target application)
                  ())
          in
          don't_wait_for
            (let%map result = execution in
             Hashtbl.remove state.runtime_cache
               (Managed_application.key application);
             (match Ivar.peek started with
             | Some operation_id -> (
                 match Hashtbl.find state.active operation_id with
                 | Some registered when phys_equal registered cancellation ->
                     Hashtbl.remove state.active operation_id
                 | _ -> ())
             | None -> ());
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
    ~prune:(fun ~expected_project ~working_directory ~target ->
      Nixploy.Application.prune ~expected_project state.application
        ~working_directory ~target)
    ~on_started:(fun ~application_key ->
      Hashtbl.remove state.runtime_cache application_key)
    query

let cancel_deployment state _connection_state query =
  let operation_id = query.Protocol.Cancel_deployment.Query.operation_id in
  match Hashtbl.find state.active operation_id with
  | None ->
      Deferred.Or_error.error_string
        "deployment is not active in this control-plane process"
  | Some cancellation -> (
      match Nixploy.Cancellation.request cancellation with
      | Too_late ->
          Deferred.Or_error.error_string "deployment is already finalizing"
      | Accepted | Already_requested -> (
          let%bind requested =
            Store.request_cancellation state.store ~id:operation_id
          in
          match requested with
          | Ok () -> Deferred.Or_error.return ()
          | Error request_error ->
              let%map found = Store.find state.store ~id:operation_id in
              Or_error.bind found ~f:(function
                | Some deployment
                  when [%equal: Store.state] (Store.state deployment) Cancelled
                  ->
                    Ok ()
                | _ -> Error request_error)))

let application_for_deployment state deployment =
  List.find state.applications ~f:(fun application ->
      deployment_matches application deployment)

let list_deployments state _connection_state query =
  let%map deployments =
    match query.Protocol.List_deployments.Query.application with
    | None -> Store.list state.store ~limit:50
    | Some key -> (
        match Managed_application.find state.applications key with
        | Error error -> Deferred.return (Error error)
        | Ok application ->
            Store.list_for_application state.store ~application_key:key
              ~working_directory:(canonical_working_directory application)
              ~target:(Managed_application.target application)
              ~limit:25)
  in
  Or_error.map deployments ~f:(fun deployments ->
      List.filter_map deployments ~f:(fun deployment ->
          application_for_deployment state deployment
          |> Option.map ~f:(fun application ->
              {
                Protocol.Recent_deployment.application =
                  Managed_application.key application;
                deployment = protocol_deployment state deployment;
              })))

let resolve_runtime state application =
  let key = Managed_application.key application in
  let now = Time_ns.now () in
  match Hashtbl.find state.runtime_cache key with
  | Some cached when Time_ns.compare now cached.expires_at < 0 -> cached.value
  | _ ->
      let value =
        let open Deferred.Or_error.Let_syntax in
        let%bind deployments =
          Store.list_for_application state.store ~application_key:key
            ~working_directory:(canonical_working_directory application)
            ~target:(Managed_application.target application)
            ~limit:25
        in
        let successful_identity =
          List.find_map deployments ~f:(fun deployment ->
              if [%equal: Store.state] (Store.state deployment) Succeeded then
                Option.map (Store.revision deployment) ~f:(fun revision ->
                    (revision, Store.id deployment))
              else None)
        in
        let%bind commit, operation_id =
          match successful_identity with
          | None -> Deferred.Or_error.return (None, None)
          | Some (revision, operation_id) ->
              let%map commit =
                Nixploy.Source.find_commit
                  ~working_directory:
                    (Managed_application.working_directory application)
                  ~revision
              in
              (Some commit, Some operation_id)
        in
        Nixploy.Runtime_application.resolve ?commit ?operation_id application
      in
      let cached =
        { expires_at = Time_ns.add now (Time_ns.Span.of_min 5.); value }
      in
      Hashtbl.set state.runtime_cache ~key ~data:cached;
      don't_wait_for
        (let%map result = value in
         cached.expires_at <-
           Time_ns.add (Time_ns.now ())
             (Time_ns.Span.of_sec (if Result.is_ok result then 10. else 3.)));
      value

let get_application_logs state _connection_state query =
  match query.Protocol.Get_application_logs.Query.application with
  | None -> Deferred.Or_error.return None
  | Some key -> (
      match Managed_application.find state.applications key with
      | Error _ as error -> Deferred.return error
      | Ok application -> (
          let open Deferred.Or_error.Let_syntax in
          let%bind runtime = resolve_runtime state application in
          let container = Nixploy.Runtime_application.container runtime in
          let%bind.Deferred snapshot =
            Nixploy.Podman.read_logs
              ~connection:(Nixploy.Runtime_application.connection runtime)
              ~container
          in
          match snapshot with
          | Error error ->
              Hashtbl.remove state.runtime_cache key;
              Deferred.return (Error error)
          | Ok snapshot ->
              Deferred.Or_error.return
                (Some
                   {
                     Protocol.Log_snapshot.application = key;
                     container_name =
                       Nixploy.Podman.runtime_container_name container;
                     revision =
                       Nixploy.Podman.runtime_container_revision container;
                     observed_at_ms = now_ms ();
                     lines =
                       List.map snapshot.lines ~f:(fun line ->
                           {
                             Protocol.Log_line.timestamp = line.timestamp;
                             text = line.text;
                           });
                     truncated = snapshot.truncated;
                   })))

let container_uptime container =
  Nixploy.Podman.runtime_container_started_at container
  |> Option.bind ~f:(fun started_at ->
      Or_error.try_with (fun () -> Time_ns.of_string_with_utc_offset started_at)
      |> Result.ok
      |> Option.map ~f:(fun started ->
          Time_ns.diff (Time_ns.now ()) started
          |> Time_ns.Span.to_sec |> Float.max 0. |> Float.iround_down_exn
          |> Int64.of_int))

let application_metrics state application =
  let key = Managed_application.key application in
  let%bind runtime = resolve_runtime state application in
  match runtime with
  | Error error ->
      Deferred.return
        {
          Protocol.Target_metrics.target =
            Managed_application.target application
            |> Nixploy.Target_name.to_string;
          host = "unavailable";
          observed_at_ms = now_ms ();
          error = Some (Error.to_string_hum error);
          cpu_percent = None;
          memory_used_bytes = None;
          memory_total_bytes = None;
          filesystem_used_bytes = None;
          filesystem_total_bytes = None;
          load_1 = None;
          load_5 = None;
          load_15 = None;
          uptime_seconds = None;
          applications =
            [
              {
                Protocol.Application_metrics.application = key;
                container_name = None;
                health = Unavailable (Error.to_string_hum error);
                error = Some (Error.to_string_hum error);
                cpu_percent = None;
                memory_used_bytes = None;
                memory_host_percent = None;
                uptime_seconds = None;
              };
            ];
        }
  | Ok runtime ->
      let target = Nixploy.Runtime_application.target runtime in
      let container = Nixploy.Runtime_application.container runtime in
      let%map host = Nixploy.Host_metrics.observe target
      and stats =
        Nixploy.Podman.read_stats
          ~connection:(Nixploy.Runtime_application.connection runtime)
          ~container
      and health =
        Nixploy.Caddy.observe_health
          (Nixploy.Runtime_application.caddy runtime)
          ~port:(Nixploy.Runtime_application.active_port runtime)
      in
      let host_error = Result.error host |> Option.map ~f:Error.to_string_hum in
      let host_value = Result.ok host in
      let stats_value = Result.ok stats in
      let health =
        match health with
        | Ok true -> Protocol.Health.Healthy
        | Ok false -> Unhealthy
        | Error error -> Unavailable (Error.to_string_hum error)
      in
      let memory_host_percent =
        let open Option.Let_syntax in
        let%bind stats = stats_value in
        let%map host = host_value in
        Int64.to_float stats.memory_used_bytes
        /. Int64.to_float (Nixploy.Host_metrics.memory_total_bytes host)
        *. 100.
      in
      {
        Protocol.Target_metrics.target =
          Nixploy.Configuration.Target.name target
          |> Nixploy.Target_name.to_string;
        host =
          sprintf "%s@%s:%d"
            (Nixploy.Configuration.Target.user target)
            (Nixploy.Configuration.Target.host target)
            (Nixploy.Configuration.Target.port target);
        observed_at_ms = now_ms ();
        error = host_error;
        cpu_percent = Option.map host_value ~f:Nixploy.Host_metrics.cpu_percent;
        memory_used_bytes =
          Option.map host_value ~f:Nixploy.Host_metrics.memory_used_bytes;
        memory_total_bytes =
          Option.map host_value ~f:Nixploy.Host_metrics.memory_total_bytes;
        filesystem_used_bytes =
          Option.map host_value ~f:Nixploy.Host_metrics.filesystem_used_bytes;
        filesystem_total_bytes =
          Option.map host_value ~f:Nixploy.Host_metrics.filesystem_total_bytes;
        load_1 = Option.map host_value ~f:Nixploy.Host_metrics.load_1;
        load_5 = Option.map host_value ~f:Nixploy.Host_metrics.load_5;
        load_15 = Option.map host_value ~f:Nixploy.Host_metrics.load_15;
        uptime_seconds =
          Option.map host_value ~f:Nixploy.Host_metrics.uptime_seconds;
        applications =
          [
            {
              Protocol.Application_metrics.application = key;
              container_name =
                Some (Nixploy.Podman.runtime_container_name container);
              health;
              error = Result.error stats |> Option.map ~f:Error.to_string_hum;
              cpu_percent =
                Option.bind stats_value ~f:(fun stats -> stats.cpu_percent);
              memory_used_bytes =
                Option.map stats_value ~f:(fun stats -> stats.memory_used_bytes);
              memory_host_percent;
              uptime_seconds = container_uptime container;
            };
          ];
      }

let merge_target_metrics targets metric =
  match
    List.findi targets ~f:(fun _ existing ->
        String.equal existing.Protocol.Target_metrics.host
          metric.Protocol.Target_metrics.host
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
    Deferred.List.map state.applications ~how:`Parallel
      ~f:(application_metrics state)
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
        Rpc.Rpc.implement Protocol.Cancel_deployment.t (cancel_deployment state);
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
  let%bind store = Store.open_ ~path:state_db >>| Or_error.ok_exn in
  let state =
    {
      applications;
      application = Nixploy.Application.create ~store ();
      store;
      active = String.Table.create ();
      runtime_cache = String.Table.create ();
    }
  in
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
