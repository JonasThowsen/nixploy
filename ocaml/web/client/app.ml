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

let state_class = function
  | Protocol.Deployment.State.Requested -> "queued"
  | Running -> "running"
  | Succeeded -> "succeeded"
  | Failed -> "failed"

let short_revision = function
  | None -> "NO IMMUTABLE REVISION"
  | Some revision ->
      String.prefix revision (Int.min 12 (String.length revision))

let application_card ~dispatch_deploy ~refresh ~set_notice application =
  let deployment = application.Protocol.Application.deployment in
  let is_running =
    Option.exists deployment ~f:(fun deployment ->
        match deployment.Protocol.Deployment.state with
        | Requested | Running -> true
        | Succeeded | Failed -> false)
  in
  let status, status_class, stage, message, revision =
    match deployment with
    | None ->
        ( "NOT DEPLOYED",
          "empty",
          "awaiting first release",
          "No operation has been recorded for this application.",
          "NO IMMUTABLE REVISION" )
    | Some deployment ->
        ( state_name deployment.state,
          state_class deployment.state,
          deployment.stage,
          Option.value deployment.error ~default:deployment.message,
          short_revision deployment.revision )
  in
  let deploy_effect =
    let%bind.Effect () =
      set_notice
        ("REQUESTING DEPLOYMENT: " ^ application.Protocol.Application.key)
    in
    let%bind.Effect response =
      dispatch_deploy
        {
          Protocol.Deploy.Query.application =
            application.Protocol.Application.key;
        }
    in
    let notice =
      match response with
      | Error error -> "RPC FAILED: " ^ Error.to_string_hum error
      | Ok (Error error) -> "DEPLOY REJECTED: " ^ Error.to_string_hum error
      | Ok (Ok id) -> "OPERATION VERIFIED: " ^ id
    in
    let%bind.Effect () = refresh in
    set_notice notice
  in
  Vdom.Node.create "article"
    ~attrs:[ Vdom.Attr.class_ "application-card" ]
    [
      Vdom.Node.div
        ~attrs:[ Vdom.Attr.class_ "card-index" ]
        [ Vdom.Node.text application.key ];
      Vdom.Node.div
        ~attrs:[ Vdom.Attr.class_ "card-main" ]
        [
          Vdom.Node.div
            ~attrs:[ Vdom.Attr.class_ "card-heading" ]
            [
              Vdom.Node.div
                [
                  Vdom.Node.h2 [ Vdom.Node.text application.project ];
                  text_with_class "repository" application.repository;
                ];
              Vdom.Node.div
                ~attrs:[ Vdom.Attr.classes [ "state"; status_class ] ]
                [
                  Vdom.Node.span ~attrs:[ Vdom.Attr.class_ "state-light" ] [];
                  Vdom.Node.text status;
                ];
            ];
          Vdom.Node.div
            ~attrs:[ Vdom.Attr.class_ "readout" ]
            [
              Vdom.Node.div
                [
                  Vdom.Node.span [ Vdom.Node.text "TARGET" ];
                  Vdom.Node.strong [ Vdom.Node.text application.target ];
                ];
              Vdom.Node.div
                [
                  Vdom.Node.span [ Vdom.Node.text "REVISION" ];
                  Vdom.Node.strong [ Vdom.Node.text revision ];
                ];
              Vdom.Node.div
                [
                  Vdom.Node.span [ Vdom.Node.text "STAGE" ];
                  Vdom.Node.strong [ Vdom.Node.text stage ];
                ];
            ];
          Vdom.Node.p
            ~attrs:[ Vdom.Attr.class_ "operation-message" ]
            [ Vdom.Node.text message ];
          Vdom.Node.button
            ~attrs:
              ([ Vdom.Attr.class_ "deploy-button" ]
              @
              if is_running then [ Vdom.Attr.disabled ]
              else [ Vdom.Attr.on_click (fun _ -> deploy_effect) ])
            [
              Vdom.Node.span
                [
                  Vdom.Node.text
                    (if is_running then "DEPLOYMENT ACTIVE" else "DEPLOY MAIN");
                ];
              Vdom.Node.span
                ~attrs:[ Vdom.Attr.class_ "button-mark" ]
                [ Vdom.Node.text "->" ];
            ];
        ];
    ]

let component graph =
  let applications =
    Rpc_effect.Rpc.poll Protocol.List_applications.t ~where_to_connect:Self
      ~equal_query:[%equal: unit]
      ~equal_response:[%equal: Protocol.Application.t list Or_error.t]
      ~every:(Time_ns.Span.of_sec 1.) (Bonsai.return ()) graph
  in
  let dispatch_deploy =
    Rpc_effect.Rpc.dispatcher Protocol.Deploy.t ~where_to_connect:Self graph
  in
  let notice, set_notice = Bonsai.state "" graph in
  let connection = Rpc_effect.Status.state ~where_to_connect:Self graph in
  let%arr applications = applications
  and dispatch_deploy = dispatch_deploy
  and notice = notice
  and set_notice = set_notice
  and connection = connection in
  let content =
    match applications.last_ok_response with
    | Some (_, Ok application_list) ->
        if List.is_empty application_list then
          [
            text_with_class "empty-panel"
              "NO APPLICATIONS ARE ALLOWLISTED ON THIS MACHINE";
          ]
        else
          List.map application_list
            ~f:
              (application_card ~dispatch_deploy ~refresh:applications.refresh
                 ~set_notice)
    | Some (_, Error error) ->
        [ text_with_class "error-panel" (Error.to_string_hum error) ]
    | None -> (
        match applications.last_error with
        | Some (_, error) ->
            [ text_with_class "error-panel" (Error.to_string_hum error) ]
        | None -> [ text_with_class "loading-panel" "READING CONTROL PLANE" ])
  in
  Vdom.Node.create "main"
    ~attrs:[ Vdom.Attr.class_ "shell" ]
    [
      Vdom.Node.create "header"
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
              Vdom.Node.h1 [ Vdom.Node.text "Deployment ledger" ];
            ];
          Vdom.Node.div
            ~attrs:[ Vdom.Attr.class_ "connection" ]
            [
              Vdom.Node.span [ Vdom.Node.text "RPC" ];
              Vdom.Node.strong
                [
                  Vdom.Node.text
                    (Sexp.to_string_hum
                       ([%sexp_of: Rpc_effect.Status.t] connection));
                ];
            ];
        ];
      Vdom.Node.create "section"
        ~attrs:[ Vdom.Attr.class_ "intro" ]
        [
          Vdom.Node.p
            [
              Vdom.Node.text
                "ALLOWLISTED SOURCES / EXACT MAIN / INDEPENDENT READBACK";
            ];
          Vdom.Node.div
            [
              Vdom.Node.span [ Vdom.Node.text "LIVE LEDGER" ];
              Vdom.Node.span ~attrs:[ Vdom.Attr.class_ "pulse" ] [];
            ];
        ];
      (if String.is_empty notice then Vdom.Node.none
       else text_with_class "notice" notice);
      Vdom.Node.create "section"
        ~attrs:[ Vdom.Attr.class_ "applications" ]
        content;
      Vdom.Node.create "footer"
        [
          Vdom.Node.span [ Vdom.Node.text "ONE MUTATION AT A TIME" ];
          Vdom.Node.span [ Vdom.Node.text "STATE: SQLITE / SOURCE: HOST" ];
        ];
    ]
