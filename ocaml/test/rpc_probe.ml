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

let preview_application connection ~capability_grant application =
  let open Deferred.Or_error.Let_syntax in
  let%bind response =
    Rpc.Rpc.dispatch Protocol.Preview_deployment.V1.t connection
      {
        Protocol.Preview_deployment.V1.Query.capability_grant;
        application;
      }
  in
  let%map preview = Deferred.return response in
  let commit = preview.Protocol.Deployment_preview.commit in
  printf "preview %s %s\n%!" commit.revision commit.subject

let inspect_application connection ~capability_grant application =
  let open Deferred.Or_error.Let_syntax in
  let%bind commit =
    Rpc.Rpc.dispatch Protocol.Preview_deployment.V1.t connection
      {
        Protocol.Preview_deployment.V1.Query.capability_grant;
        application;
      }
  in
  let%bind preview = Deferred.return commit in
  let commit = preview.Protocol.Deployment_preview.commit in
  printf "preview %s %s\n%!" commit.revision commit.subject;
  let%bind logs =
    Rpc.Rpc.dispatch Protocol.Get_application_logs.V1.t connection
      {
        Protocol.Get_application_logs.V1.Query.capability_grant;
        application = Some application;
      }
  in
  let%bind logs = Deferred.return logs in
  let logs = Option.value_exn logs in
  printf "logs %s %d lines%s\n%!" logs.container_name (List.length logs.lines)
    (if logs.truncated then " truncated" else "");
  let%bind metrics =
    Rpc.Rpc.dispatch Protocol.Get_metrics.V1.t connection
      { Protocol.Get_metrics.V1.Query.capability_grant }
  in
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

let rec wait_for_terminal connection ~capability_grant application operation_id attempts =
  let open Deferred.Or_error.Let_syntax in
  if attempts = 0 then
    Deferred.Or_error.error_string
      "cancelled deployment did not become terminal"
  else
    let%bind deployments =
      Rpc.Rpc.dispatch Protocol.List_deployments.V1.t connection
        {
          Protocol.List_deployments.V1.Query.capability_grant;
          application = Some application;
        }
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
            wait_for_terminal connection ~capability_grant application operation_id
              (attempts - 1)
        )
    | None ->
        let%bind.Deferred () = Clock_ns.after (Time_ns.Span.of_sec 1.) in
        wait_for_terminal connection ~capability_grant application operation_id
          (attempts - 1)

let origin_of_uri uri =
  let open Or_error.Let_syntax in
  let%bind scheme =
    Uri.scheme uri
    |> Or_error.of_option ~error:(Error.of_string "URI has no scheme")
  in
  let%bind host =
    Uri.host uri
    |> Or_error.of_option ~error:(Error.of_string "URI has no host")
  in
  if not (String.equal scheme "http" || String.equal scheme "https") then
    Or_error.errorf "unsupported URI scheme %S" scheme
  else Ok (Uri.make ~scheme ~host ?port:(Uri.port uri) () |> Uri.to_string)

let admission_query ~capability_grant ~managed_application_key ~requested_target
    ~provenance ~revision =
  {
    Protocol.Admit_managed_deployment.Query.capability_grant;
    managed_application_key;
    requested_target;
    provenance;
    revision;
  }

let run ~uri ~preview ~inspect ~deploy ~admit_managed_key ~admit_target
    ~admit_provenance ~admit_revision ~cancel_started ~skip_capabilities =
  let open Deferred.Or_error.Let_syntax in
  let%bind admission =
    match
      (admit_managed_key, admit_target, admit_provenance, admit_revision)
    with
    | None, None, None, None -> Deferred.Or_error.return None
    | ( Some managed_application_key,
        Some requested_target,
        Some provenance,
        Some revision ) ->
        Deferred.Or_error.return
          (Some
             (admission_query ~capability_grant:"" ~managed_application_key
                ~requested_target ~provenance ~revision))
    | _ ->
        Deferred.Or_error.error_string
          "--admit-managed-key, --admit-target, --admit-provenance, and \
           --admit-revision must be supplied together"
  in
  let uri = Uri.of_string uri in
  let%bind origin = origin_of_uri uri |> Deferred.return in
  let headers = Cohttp.Header.init_with "Origin" origin in
  let headers =
    Sys.getenv "NIXPLOY_PROBE_TAILSCALE_LOGIN"
    |> Option.value_map ~default:headers ~f:(fun login ->
        Cohttp.Header.add headers "Tailscale-User-Login" login)
  in
  let required_capabilities =
    [ "managed-read-v1" ]
    @ (if
         Option.is_some preview || Option.is_some inspect
         || Option.is_some deploy || Option.is_some admission
       then [ "managed-deploy-v1" ]
       else [])
    @ if cancel_started then [ "managed-cancel-v1" ] else []
  in
  let%bind connection = Rpc_websocket.Rpc.client ~headers uri in
  let%bind capability_grant =
    if skip_capabilities then Deferred.Or_error.return ""
    else
      let%bind capabilities =
        Rpc.Rpc.dispatch Protocol.Control_plane_capabilities.V1.t connection
          {
            Protocol.Control_plane_capabilities.Query.protocol_major = 1;
            protocol_minor = 0;
            required_capabilities;
          }
      in
      let%map capabilities = Deferred.return capabilities in
      printf "capabilities %s %d.%d\n%!" capabilities.control_plane_id
        capabilities.protocol_major capabilities.protocol_minor;
      capabilities.capability_grant
  in
  let admission =
    Option.map admission ~f:(fun query ->
        { query with Protocol.Admit_managed_deployment.Query.capability_grant })
  in
  let%bind () =
    if Option.is_some preview || Option.is_some inspect || Option.is_some deploy
    then Deferred.Or_error.return ()
    else
      let%bind applications =
        Rpc.Rpc.dispatch Protocol.List_applications.V1.t connection
          { Protocol.List_applications.V1.Query.capability_grant }
      in
      let%map applications = Deferred.return applications in
      List.iter applications ~f:(fun application ->
          printf "%s %s\n%!" application.Protocol.Application.key
            (deployment_state application))
  in
  let%bind () =
    match preview with
    | None -> Deferred.Or_error.return ()
    | Some application -> preview_application connection ~capability_grant application
  in
  let%bind () =
    match inspect with
    | None -> Deferred.Or_error.return ()
    | Some application -> inspect_application connection ~capability_grant application
  in
  let%bind () =
    match admission with
    | None -> Deferred.Or_error.return ()
    | Some query ->
        let%bind response =
          Rpc.Rpc.dispatch Protocol.Admit_managed_deployment.t connection query
        in
        let%map _response = Deferred.return response in
        ()
  in
  match deploy with
  | None -> Deferred.Or_error.return ()
  | Some application ->
      let%bind operation =
        Rpc.Rpc.dispatch Protocol.Deploy.V1.t connection
          { Protocol.Deploy.V1.Query.capability_grant; application }
      in
      let%bind operation = Deferred.return operation in
      printf "started %s\n%!" operation;
      if cancel_started then
        let cancelled =
          Rpc.Rpc.dispatch Protocol.Cancel_deployment_v1.V1.t connection
            {
              Protocol.Cancel_deployment_v1.V1.Query.capability_grant;
              application;
              operation_id = operation;
            }
        in
        let%bind cancellation = cancelled in
        let%bind () = Deferred.return cancellation in
        wait_for_terminal connection ~capability_grant application operation 180
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
     and preview =
       flag "--preview" (optional string)
         ~doc:"APPLICATION preview one managed application"
     and admit_managed_key =
       flag "--admit-managed-key" (optional string)
         ~doc:"KEY test-only managed admission application key"
     and admit_target =
       flag "--admit-target" (optional string)
         ~doc:"TARGET test-only managed admission target"
     and admit_provenance =
       flag "--admit-provenance" (optional string)
         ~doc:"PROVENANCE test-only managed admission provenance"
     and admit_revision =
       flag "--admit-revision" (optional string)
         ~doc:"SHA test-only managed admission full commit SHA"
     and inspect =
       flag "--inspect" (optional string)
         ~doc:"APPLICATION preview and inspect runtime reads"
     and cancel_started =
       flag "--cancel-started" no_arg
         ~doc:" cancel a deployment immediately after it starts"
     and skip_capabilities =
       flag "--skip-capabilities" no_arg
         ~doc:" test only: dispatch without the required capabilities handshake"
     in
     fun () ->
       run ~uri ~preview ~inspect ~deploy ~admit_managed_key ~admit_target
         ~admit_provenance ~admit_revision ~cancel_started ~skip_capabilities)

let () = Command_unix.run command
