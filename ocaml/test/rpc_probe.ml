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
      | Failed -> "failed")

let run ~uri ~deploy =
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
  match deploy with
  | None -> Deferred.Or_error.return ()
  | Some application ->
      let%bind operation =
        Rpc.Rpc.dispatch Protocol.Deploy.t connection
          { Protocol.Deploy.Query.application }
      in
      let%map operation = Deferred.return operation in
      printf "deployed %s\n%!" operation

let command =
  Async.Command.async_or_error ~summary:"Probe a nixploy-web RPC endpoint"
    (let%map_open.Command uri =
       flag "--uri"
         (optional_with_default "http://127.0.0.1:8080" string)
         ~doc:"URI nixploy-web endpoint"
     and deploy =
       flag "--deploy" (optional string)
         ~doc:"APPLICATION deploy one managed application"
     in
     fun () -> run ~uri ~deploy)

let () = Command_unix.run command
