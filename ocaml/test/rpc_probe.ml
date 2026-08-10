open Async
open Core

let deployment_state application =
  match application.Protocol.Application.deployment with
  | None -> "not-deployed"
  | Some deployment -> (
      match deployment.Protocol.Deployment.state with
      | Requested -> "requested"
      | Running -> "running"
      | Succeeded -> "succeeded"
      | Failed -> "failed"
      | Cancelled -> "cancelled")

let inspect_application connection application =
  let open Deferred.Or_error.Let_syntax in
  let%bind commit =
    Rpc.Rpc.dispatch Protocol.Preview_deployment.t connection
      { Protocol.Preview_deployment.Query.application }
  in
  let%bind commit = Deferred.return commit in
  printf "preview %s %s\n%!" commit.revision commit.subject;
  let%bind logs =
    Rpc.Rpc.dispatch Protocol.Get_application_logs.t connection
      { Protocol.Get_application_logs.Query.application = Some application }
  in
  let%bind logs = Deferred.return logs in
  let logs = Option.value_exn logs in
  printf "logs %s %d lines%s\n%!" logs.container_name (List.length logs.lines)
    (if logs.truncated then " truncated" else "");
  let%bind metrics = Rpc.Rpc.dispatch Protocol.Get_metrics.t connection () in
  let%bind metrics = Deferred.return metrics in
  let%map () =
    Deferred.return
      (Or_error.all_unit
         (List.map metrics ~f:(fun target ->
              let open Or_error.Let_syntax in
              let%bind () =
                Option.value_map target.Protocol.Target_metrics.error
                  ~default:(Ok ()) ~f:Or_error.error_string
              in
              let%bind _ =
                Option.value_map target.cpu_percent
                  ~default:(Or_error.error_string "host CPU is unavailable")
                  ~f:Or_error.return
              in
              let%bind _ =
                Option.value_map target.memory_total_bytes
                  ~default:(Or_error.error_string "host memory is unavailable")
                  ~f:Or_error.return
              in
              Or_error.all_unit
                (List.map target.applications ~f:(fun application ->
                     match application.Protocol.Application_metrics.health with
                     | Healthy -> Ok ()
                     | Unhealthy ->
                         Or_error.error_string "application is unhealthy"
                     | Unavailable error -> Or_error.error_string error)))))
  in
  List.iter metrics ~f:(fun target ->
      printf "metrics %s %s cpu=%s applications=%d\n%!" target.target
        target.host
        (Option.value_map target.cpu_percent ~default:"unavailable"
           ~f:(sprintf "%.1f%%"))
        (List.length target.applications))

let rec wait_for_terminal connection application operation_id attempts =
  let open Deferred.Or_error.Let_syntax in
  if attempts = 0 then
    Deferred.Or_error.error_string
      "cancelled deployment did not become terminal"
  else
    let%bind deployments =
      Rpc.Rpc.dispatch Protocol.List_deployments.t connection
        { Protocol.List_deployments.Query.application = Some application }
    in
    let%bind deployments = Deferred.return deployments in
    match
      List.find deployments ~f:(fun recent ->
          String.equal recent.Protocol.Recent_deployment.deployment.id
            operation_id)
    with
    | Some recent -> (
        match recent.deployment.state with
        | Cancelled ->
            printf "cancelled %s\n%!" operation_id;
            Deferred.Or_error.return ()
        | Succeeded | Failed ->
            Deferred.Or_error.errorf "operation reached %s instead of cancelled"
              (Sexp.to_string_hum
                 ([%sexp_of: Protocol.Deployment.State.t]
                    recent.deployment.state))
        | Requested | Running ->
            let%bind.Deferred () = Clock_ns.after (Time_ns.Span.of_sec 1.) in
            wait_for_terminal connection application operation_id (attempts - 1)
        )
    | None ->
        let%bind.Deferred () = Clock_ns.after (Time_ns.Span.of_sec 1.) in
        wait_for_terminal connection application operation_id (attempts - 1)

let run ~uri ~inspect ~deploy ~cancel_started =
  let open Deferred.Or_error.Let_syntax in
  let headers =
    Sys.getenv "NIXPLOY_PROBE_TAILSCALE_LOGIN"
    |> Option.map ~f:(fun login ->
        Cohttp.Header.init_with "Tailscale-User-Login" login)
  in
  let%bind connection = Rpc_websocket.Rpc.client ?headers (Uri.of_string uri) in
  let%bind applications =
    Rpc.Rpc.dispatch Protocol.List_applications.t connection ()
  in
  let%bind applications = Deferred.return applications in
  List.iter applications ~f:(fun application ->
      printf "%s %s\n%!" application.Protocol.Application.key
        (deployment_state application));
  let%bind () =
    match inspect with
    | None -> Deferred.Or_error.return ()
    | Some application -> inspect_application connection application
  in
  match deploy with
  | None -> Deferred.Or_error.return ()
  | Some application ->
      let%bind commit =
        Rpc.Rpc.dispatch Protocol.Preview_deployment.t connection
          { Protocol.Preview_deployment.Query.application }
      in
      let%bind commit = Deferred.return commit in
      printf "preview %s %s\n%!" commit.revision commit.subject;
      let%bind operation =
        Rpc.Rpc.dispatch Protocol.Deploy.t connection
          { Protocol.Deploy.Query.application; revision = commit.revision }
      in
      let%bind operation = Deferred.return operation in
      printf "started %s\n%!" operation;
      if cancel_started then
        let cancelled =
          Rpc.Rpc.dispatch Protocol.Cancel_deployment.t connection
            { Protocol.Cancel_deployment.Query.operation_id = operation }
        in
        let%bind cancellation = cancelled in
        let%bind () = Deferred.return cancellation in
        wait_for_terminal connection application operation 180
      else Deferred.Or_error.return ()

let command =
  Async.Command.async_or_error ~summary:"Probe a nixploy-web RPC endpoint"
    (let%map_open.Command uri =
       flag "--uri"
         (optional_with_default "http://127.0.0.1:8080" string)
         ~doc:"URI nixploy-web endpoint"
     and deploy =
       flag "--deploy" (optional string)
         ~doc:"APPLICATION deploy one managed application"
     and inspect =
       flag "--inspect" (optional string)
         ~doc:"APPLICATION preview and inspect runtime reads"
     and cancel_started =
       flag "--cancel-started" no_arg
         ~doc:" cancel a deployment immediately after it starts"
     in
     fun () -> run ~uri ~inspect ~deploy ~cancel_started)

let () = Command_unix.run command
