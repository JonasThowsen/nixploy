open Async
open Core

type t = {
  target : Configuration.Target.t;
  web : Configuration.Web.t;
  route_id : string;
  proxy_id : string;
}

type route = Missing | Existing of { active_port : int }
type response = { status : int; body : string }

let request_timeout = Time_ns.Span.of_sec 30.
let max_response_bytes = 262_144
let admin_url = "http://127.0.0.1:2019"

let create ~target ~resource_key ~web =
  let key = Resource_key.to_string resource_key in
  {
    target;
    web;
    route_id = "nixploy-route-" ^ key;
    proxy_id = "nixploy-proxy-" ^ key;
  }

let parse_response output =
  match String.rsplit2 output ~on:'\n' with
  | None ->
      Or_error.error_string "Caddy response did not include an HTTP status"
  | Some (body, status) ->
      Or_error.try_with_join (fun () ->
          let status = Int.of_string (String.strip status) in
          if status >= 100 && status <= 599 then Ok { status; body }
          else Or_error.errorf "invalid Caddy HTTP status %d" status)

let request ?body ?ignore_termination t ~meth ~path =
  let args =
    [ "curl"; "-sS"; "-X"; meth; "--write-out"; "\\n%{http_code}" ]
    @
    match body with
    | None -> [ admin_url ^ path ]
    | Some _ ->
        [
          "-H";
          "Content-Type: application/json";
          "--data-binary";
          "@-";
          admin_url ^ path;
        ]
  in
  let open Deferred.Or_error.Let_syntax in
  let%bind result =
    Remote_command.run ?stdin:body ?ignore_termination ~target:t.target
      ~timeout:request_timeout ~max_output_bytes:max_response_bytes args
  in
  match result.exit_status with
  | Error failure ->
      Deferred.Or_error.errorf "Caddy request failed (%s): %s"
        (Core_unix.Exit_or_signal.to_string_hum (Error failure))
        (String.strip result.stderr)
  | Ok () -> Deferred.return (parse_response result.stdout)

let assoc_member fields name = List.Assoc.find fields ~equal:String.equal name

let expect_single_list ~field = function
  | Some (`List [ value ]) -> Ok value
  | _ -> Or_error.errorf "%s must contain exactly one item" field

let expect_string ~field = function
  | Some (`String value) -> Ok value
  | _ -> Or_error.errorf "%s must be a string" field

let validate_route t body =
  let open Or_error.Let_syntax in
  let%bind json = Or_error.try_with (fun () -> Yojson.Safe.from_string body) in
  match json with
  | `Assoc route -> (
      let%bind route_id =
        expect_string ~field:"route @id" (assoc_member route "@id")
      in
      let%bind () =
        if String.equal route_id t.route_id then Ok ()
        else Or_error.error_string "Caddy route identity does not match nixploy"
      in
      let%bind () =
        match assoc_member route "terminal" with
        | Some (`Bool true) -> Ok ()
        | _ -> Or_error.error_string "Caddy route is not terminal"
      in
      let%bind matcher =
        expect_single_list ~field:"route match" (assoc_member route "match")
      in
      let%bind () =
        match matcher with
        | `Assoc matcher -> (
            match assoc_member matcher "host" with
            | Some (`List [ `String domain ])
              when String.Caseless.equal domain (Configuration.Web.domain t.web)
              ->
                Ok ()
            | _ ->
                Or_error.error_string
                  "Caddy route domain does not match the flake")
        | _ -> Or_error.error_string "Caddy route matcher is malformed"
      in
      let%bind subroute =
        expect_single_list ~field:"route handle" (assoc_member route "handle")
      in
      let%bind nested_route =
        match subroute with
        | `Assoc fields ->
            let%bind handler =
              expect_string ~field:"subroute handler"
                (assoc_member fields "handler")
            in
            if not (String.equal handler "subroute") then
              Or_error.error_string "Caddy route does not contain a subroute"
            else
              expect_single_list ~field:"subroute routes"
                (assoc_member fields "routes")
        | _ -> Or_error.error_string "Caddy subroute is malformed"
      in
      let%bind proxy =
        match nested_route with
        | `Assoc fields ->
            expect_single_list ~field:"nested handles"
              (assoc_member fields "handle")
        | _ -> Or_error.error_string "Caddy nested route is malformed"
      in
      match proxy with
      | `Assoc fields ->
          let%bind proxy_id =
            expect_string ~field:"proxy @id" (assoc_member fields "@id")
          and handler =
            expect_string ~field:"proxy handler" (assoc_member fields "handler")
          in
          if
            String.equal proxy_id t.proxy_id
            && String.equal handler "reverse_proxy"
          then Ok ()
          else
            Or_error.error_string "Caddy proxy identity does not match nixploy"
      | _ -> Or_error.error_string "Caddy proxy is malformed")
  | _ -> Or_error.error_string "Caddy route must be an object"

let upstream_port_of_json body =
  let open Or_error.Let_syntax in
  let%bind json = Or_error.try_with (fun () -> Yojson.Safe.from_string body) in
  match json with
  | `List [ `Assoc fields ] -> (
      let%bind dial =
        expect_string ~field:"upstream dial" (assoc_member fields "dial")
      in
      match String.rsplit2 dial ~on:':' with
      | Some (host, port) when String.equal host "127.0.0.1" ->
          Or_error.try_with (fun () -> Int.of_string port)
      | _ ->
          Or_error.error_string "Caddy upstream is not a loopback host and port"
      )
  | _ -> Or_error.error_string "Caddy proxy must have exactly one upstream"

module For_testing = struct
  let upstream_port_of_json = upstream_port_of_json
end

let read_active_port ?ignore_termination t =
  let open Deferred.Or_error.Let_syntax in
  let%bind response =
    request ?ignore_termination t ~meth:"GET"
      ~path:("/id/" ^ t.proxy_id ^ "/upstreams")
  in
  match response.status with
  | 200 -> Deferred.return (upstream_port_of_json response.body)
  | status ->
      Deferred.Or_error.errorf "Caddy upstream read returned HTTP %d" status

let inspect_internal ?ignore_termination t =
  let open Deferred.Or_error.Let_syntax in
  let%bind response =
    request ?ignore_termination t ~meth:"GET" ~path:("/id/" ^ t.route_id)
  in
  match response.status with
  | 404 -> Deferred.Or_error.return Missing
  | 200 ->
      let%bind () = Deferred.return (validate_route t response.body) in
      let%map active_port = read_active_port ?ignore_termination t in
      Existing { active_port }
  | status ->
      Deferred.Or_error.errorf "Caddy route read returned HTTP %d" status

let inspect ?ignore_termination t = inspect_internal ?ignore_termination t
let server_body = {|{"listen":[":80",":443"],"routes":[]}|}

let ensure_server t =
  let open Deferred.Or_error.Let_syntax in
  let%bind response =
    request t ~meth:"GET" ~path:"/config/apps/http/servers/nixploy"
  in
  match response.status with
  | 200 -> Deferred.Or_error.return ()
  | 404 ->
      let%bind created =
        request ~body:server_body t ~meth:"PUT"
          ~path:"/config/apps/http/servers/nixploy"
      in
      if created.status >= 200 && created.status < 300 then
        Deferred.Or_error.return ()
      else
        Deferred.Or_error.errorf "Caddy server creation returned HTTP %d"
          created.status
  | status ->
      Deferred.Or_error.errorf "Caddy server read returned HTTP %d" status

let upstream_body port =
  `List [ `Assoc [ ("dial", `String (sprintf "127.0.0.1:%d" port)) ] ]
  |> Yojson.Safe.to_string

let route_body t port =
  `Assoc
    [
      ("@id", `String t.route_id);
      ( "match",
        `List
          [
            `Assoc
              [ ("host", `List [ `String (Configuration.Web.domain t.web) ]) ];
          ] );
      ( "handle",
        `List
          [
            `Assoc
              [
                ("handler", `String "subroute");
                ( "routes",
                  `List
                    [
                      `Assoc
                        [
                          ( "handle",
                            `List
                              [
                                `Assoc
                                  [
                                    ("@id", `String t.proxy_id);
                                    ("handler", `String "reverse_proxy");
                                    ( "upstreams",
                                      `List
                                        [
                                          `Assoc
                                            [
                                              ( "dial",
                                                `String
                                                  (sprintf "127.0.0.1:%d" port)
                                              );
                                            ];
                                        ] );
                                  ];
                              ] );
                        ];
                    ] );
              ];
          ] );
      ("terminal", `Bool true);
    ]
  |> Yojson.Safe.to_string

let switch t ~previous ~candidate_port =
  let open Deferred.Or_error.Let_syntax in
  let%bind response =
    match previous with
    | Existing _ ->
        request
          ~body:(upstream_body candidate_port)
          t ~meth:"PATCH"
          ~path:("/id/" ^ t.proxy_id ^ "/upstreams")
    | Missing ->
        let%bind () = ensure_server t in
        request
          ~body:(route_body t candidate_port)
          t ~meth:"POST" ~path:"/config/apps/http/servers/nixploy/routes"
  in
  if response.status >= 200 && response.status < 300 then
    Deferred.Or_error.return ()
  else Deferred.Or_error.errorf "Caddy switch returned HTTP %d" response.status

let delete_route ?ignore_termination t =
  let open Deferred.Or_error.Let_syntax in
  let%bind response =
    request ?ignore_termination t ~meth:"DELETE" ~path:("/id/" ^ t.route_id)
  in
  if List.mem [ 200; 204; 404 ] response.status ~equal:Int.equal then
    Deferred.Or_error.return ()
  else
    Deferred.Or_error.errorf "Caddy route deletion returned HTTP %d"
      response.status

let restore t ~previous =
  let open Deferred.Or_error.Let_syntax in
  let%bind () =
    match previous with
    | Missing -> delete_route ~ignore_termination:true t
    | Existing { active_port } ->
        let%bind response =
          request ~ignore_termination:true
            ~body:(upstream_body active_port)
            t ~meth:"PATCH"
            ~path:("/id/" ^ t.proxy_id ^ "/upstreams")
        in
        if response.status >= 200 && response.status < 300 then
          Deferred.Or_error.return ()
        else
          Deferred.Or_error.errorf "Caddy restoration returned HTTP %d"
            response.status
  in
  let%bind observed = inspect_internal ~ignore_termination:true t in
  match (previous, observed) with
  | Missing, Missing -> Deferred.Or_error.return ()
  | Existing expected, Existing observed
    when Int.equal expected.active_port observed.active_port ->
      Deferred.Or_error.return ()
  | _ ->
      Deferred.Or_error.error_string "Caddy restoration could not be verified"

let health_check t ~port =
  let url =
    sprintf "http://127.0.0.1:%d%s" port (Configuration.Web.health_path t.web)
  in
  let rec attempt remaining =
    let open Deferred.Let_syntax in
    let%bind result =
      Remote_command.run ~target:t.target ~timeout:(Time_ns.Span.of_sec 5.)
        ~max_output_bytes:65_536
        [ "curl"; "-fsS"; "--max-time"; "2"; url ]
    in
    match result with
    | Ok { exit_status = Ok (); _ } -> Deferred.Or_error.return ()
    | _
      when remaining > 1
           && Option.is_none (Process_runner.termination_signal ()) ->
        let%bind () = Clock_ns.after (Time_ns.Span.of_sec 1.) in
        attempt (remaining - 1)
    | Error error -> Deferred.return (Error error)
    | Ok result ->
        Deferred.Or_error.errorf "candidate health check failed: %s"
          (String.strip result.stderr)
  in
  attempt 20

let observe_health t ~port =
  let url =
    sprintf "http://127.0.0.1:%d%s" port (Configuration.Web.health_path t.web)
  in
  let open Deferred.Or_error.Let_syntax in
  let%bind result =
    Remote_command.run ~target:t.target ~timeout:(Time_ns.Span.of_sec 5.)
      ~max_output_bytes:4_096
      [
        "curl";
        "-sS";
        "--output";
        "/dev/null";
        "--write-out";
        "%{http_code}";
        "--max-time";
        "3";
        url;
      ]
  in
  match result.exit_status with
  | Error failure ->
      Deferred.Or_error.errorf "application health probe failed (%s): %s"
        (Core_unix.Exit_or_signal.to_string_hum (Error failure))
        (String.strip result.stderr)
  | Ok () ->
      let%map status =
        Deferred.return
          (Or_error.try_with (fun () ->
               String.strip result.stdout |> Int.of_string))
      in
      status >= 200 && status < 300
