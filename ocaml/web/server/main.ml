open! Core
open! Async
module Managed_application = Nixploy.Managed_application
module Store = Nixploy.Store

type state = { applications : Managed_application.t list; store : Store.t }

let protocol_state = function
  | Store.Requested -> Protocol.Deployment.State.Requested
  | Running -> Running
  | Succeeded -> Succeeded
  | Failed -> Failed

let protocol_deployment deployment =
  {
    Protocol.Deployment.id = Store.id deployment;
    state = protocol_state (Store.state deployment);
    stage = Store.stage deployment;
    message = Store.message deployment;
    revision = Store.revision deployment;
    container_name = Store.container_name deployment;
    error = Store.error deployment;
    updated_at_ms = Store.updated_at_ms deployment;
  }

let latest_deployment deployments application =
  List.find deployments ~f:(fun deployment ->
      String.equal
        (Store.working_directory deployment)
        (Managed_application.working_directory application)
      && Nixploy.Target_name.equal (Store.target deployment)
           (Managed_application.target application))

let list_applications state _connection_state () =
  let%map deployments = Store.list state.store ~limit:10_000 in
  Or_error.map deployments ~f:(fun deployments ->
      List.map state.applications ~f:(fun application ->
          {
            Protocol.Application.key = Managed_application.key application;
            project =
              Managed_application.project application
              |> Nixploy.Project_name.to_string;
            target =
              Managed_application.target application
              |> Nixploy.Target_name.to_string;
            repository = Managed_application.repository application;
            deployment =
              latest_deployment deployments application
              |> Option.map ~f:protocol_deployment;
          }))

let deploy state _connection_state query =
  match
    Managed_application.find state.applications
      query.Protocol.Deploy.Query.application
  with
  | Error _ as error -> Deferred.return error
  | Ok application ->
      Monitor.try_with_or_error (fun () ->
          Nixploy.Tracked_deployment.deploy ~store:state.store
            ~working_directory:
              (Managed_application.working_directory application)
            ~target:(Managed_application.target application)
            ())
      >>| Or_error.join
      >>| Or_error.bind ~f:(fun deployment ->
          match Store.state deployment with
          | Succeeded -> Ok (Store.id deployment)
          | Failed ->
              Or_error.errorf "operation %s failed: %s" (Store.id deployment)
                (Store.error deployment
                |> Option.value ~default:(Store.message deployment))
          | Requested | Running ->
              Or_error.errorf "operation %s did not reach a terminal state"
                (Store.id deployment))

let implementations state =
  Rpc.Implementations.create_exn
    ~implementations:
      [
        Rpc.Rpc.implement Protocol.List_applications.t (list_applications state);
        Rpc.Rpc.implement Protocol.Deploy.t (deploy state);
      ]
    ~on_unknown_rpc:`Continue

let respond_string ~content_type ?status body =
  let headers =
    Cohttp.Header.init_with "Content-Type" content_type |> fun headers ->
    Cohttp.Header.add headers "X-Content-Type-Options" "nosniff"
    |> fun headers -> Cohttp.Header.add headers "X-Frame-Options" "DENY"
  in
  Cohttp_async.Server.respond_string ~headers ?status body

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

let http_handler ~body:_ _address request =
  match Uri.path (Cohttp.Request.uri request) with
  | "" | "/" | "/index.html" -> respond_string ~content_type:"text/html" html
  | "/main.js" ->
      respond_string ~content_type:"application/javascript"
        Embedded_files.main_dot_bc_dot_js
  | "/app.css" ->
      respond_string ~content_type:"text/css" Embedded_files.app_dot_css
  | "/healthz" -> respond_string ~content_type:"text/plain" "ok\n"
  | _ -> respond_string ~content_type:"text/html" ~status:`Not_found not_found

let run ~port ~state_db =
  let open Deferred.Let_syntax in
  let applications =
    Managed_application.load_environment () |> Or_error.ok_exn
  in
  let%bind store = Store.open_ ~path:state_db >>| Or_error.ok_exn in
  let state = { applications; store } in
  let%bind server =
    Rpc_websocket.Rpc.serve ~on_handler_error:`Raise ~mode:`TCP
      ~where_to_listen:(Tcp.Where_to_listen.bind_to Localhost (On_port port))
      ~http_handler:(fun () -> http_handler)
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
