open Core

type t = Unrestricted | Tailscale of string | Test_authenticated_identity
type authenticated_identity = Tailscale_login of string [@@deriving compare, equal, sexp]
type origin = { scheme : string; host : string; port : int }
type host_authority = { host : string; port : int option }
type origin_policy = Request_host | Allowed_origin of origin

let normalized_login login = String.strip login |> String.lowercase

let of_values ~test_only ~mode ~operator_email =
  match
    Option.map mode ~f:(fun mode -> String.strip mode |> String.lowercase)
  with
  | None | Some "unrestricted" -> Ok Unrestricted
  | Some "test-authenticated-identity" ->
      if Option.value_map test_only ~default:false ~f:(String.equal "true") then
        Ok Test_authenticated_identity
      else
        Or_error.error_string
          "NIXPLOY_TEST_AUTHENTICATED_IDENTITY_REQUIRES_TEST_ONLY: test-only authentication is disabled"
  | Some "tailscale" -> (
      match operator_email with
      | Some email when not (String.is_empty (String.strip email)) ->
          Ok (Tailscale (normalized_login email))
      | _ ->
          Or_error.error_string
            "NIXPLOY_OPERATOR_EMAIL is required in Tailscale auth mode")
  | Some mode ->
      Or_error.errorf
        "unknown NIXPLOY_AUTH_MODE %S (expected tailscale or unrestricted)" mode

let load_environment () =
  of_values
    ~mode:(Sys.getenv "NIXPLOY_AUTH_MODE")
    ~operator_email:(Sys.getenv "NIXPLOY_OPERATOR_EMAIL")
    ~test_only:(Sys.getenv "NIXPLOY_TEST_ONLY")

let default_port = function "http" -> 80 | "https" -> 443 | _ -> assert false
let valid_port port = port > 0 && port <= 65_535

let parse_origin value =
  Or_error.try_with (fun () ->
      if
        String.length value > 2_048
        || (not (String.equal value (String.strip value)))
        || String.exists value ~f:Char.is_whitespace
        || String.mem value ',' || String.mem value '?' || String.mem value '#'
      then failwith "origin is not a single serialized browser origin";
      let uri = Uri.of_string value in
      let scheme = Uri.scheme uri |> Option.value_exn |> String.lowercase in
      if not (String.equal scheme "http" || String.equal scheme "https") then
        failwith "origin scheme is not HTTP";
      if Option.is_some (Uri.userinfo uri) then failwith "origin has userinfo";
      if not (String.is_empty (Uri.path uri)) then failwith "origin has a path";
      if not (List.is_empty (Uri.query uri)) then failwith "origin has a query";
      if Option.is_some (Uri.fragment uri) then failwith "origin has a fragment";
      let host = Uri.host uri |> Option.value_exn |> String.lowercase in
      if String.is_empty host then failwith "origin host is empty";
      let port = Uri.port uri |> Option.value ~default:(default_port scheme) in
      if not (valid_port port) then failwith "origin port is invalid";
      { scheme; host; port })

let parse_host value =
  Or_error.try_with (fun () ->
      if
        String.is_empty value
        || (not (String.equal value (String.strip value)))
        || String.exists value ~f:Char.is_whitespace
        || String.mem value ','
      then failwith "invalid Host authority";
      let uri = Uri.of_string ("http://" ^ value) in
      if Option.is_some (Uri.userinfo uri) then failwith "Host has userinfo";
      if not (String.is_empty (Uri.path uri)) then failwith "Host has a path";
      if not (List.is_empty (Uri.query uri)) then failwith "Host has a query";
      if Option.is_some (Uri.fragment uri) then failwith "Host has a fragment";
      let host = Uri.host uri |> Option.value_exn |> String.lowercase in
      if String.is_empty host then failwith "Host is empty";
      let port = Uri.port uri in
      Option.iter port ~f:(fun port ->
          if not (valid_port port) then failwith "Host port is invalid");
      { host; port })

let origin_policy_of_value = function
  | None -> Ok Request_host
  | Some value ->
      Or_error.map (parse_origin value) ~f:(fun origin -> Allowed_origin origin)

let load_origin_policy () =
  origin_policy_of_value (Sys.getenv "NIXPLOY_ALLOWED_ORIGIN")

let authenticated_identity authorization headers =
  match authorization with
  | Test_authenticated_identity -> Ok (Tailscale_login "nixos-vm-test")
  | Unrestricted ->
      Or_error.error_string "NIXPLOY_AUTHENTICATED_IDENTITY_REQUIRED: managed capability grants require Tailscale authentication"
  | Tailscale expected ->
      Cohttp.Header.get headers "tailscale-user-login"
      |> Option.map ~f:normalized_login
      |> Option.filter ~f:(String.equal expected)
      |> Option.map ~f:(fun login -> Tailscale_login login)
      |> Or_error.of_option
           ~error:(Error.of_string "NIXPLOY_AUTHENTICATED_IDENTITY_REQUIRED: managed capability grants require the configured Tailscale identity")

let authorized authorization headers =
  match authenticated_identity authorization headers with
  | Ok _ -> true
  | Error _ -> (
      match authorization with Unrestricted -> true | Tailscale _ | Test_authenticated_identity -> false)

let same_origin left right =
  String.equal left.scheme right.scheme
  && String.equal left.host right.host
  && Int.equal left.port right.port

let matches_host (origin : origin) (host : host_authority) =
  String.equal origin.host host.host
  &&
  match host.port with
  | Some port -> Int.equal origin.port port
  | None -> Int.equal origin.port (default_port origin.scheme)

let authorize_websocket authorization origin_policy headers =
  if not (authorized authorization headers) then
    Or_error.error_string "WebSocket upgrade rejected: unauthorized identity"
  else
    match Cohttp.Header.get_multi headers "origin" with
    | [ value ] -> (
        match parse_origin value with
        | Error _ ->
            Or_error.error_string
              "WebSocket upgrade rejected: invalid or disallowed Origin"
        | Ok origin ->
            let allowed =
              match origin_policy with
              | Allowed_origin expected -> same_origin origin expected
              | Request_host -> (
                  match Cohttp.Header.get_multi headers "host" with
                  | [ host ] -> (
                      match parse_host host with
                      | Ok host -> matches_host origin host
                      | Error _ -> false)
                  | [] | _ :: _ :: _ -> false)
            in
            if allowed then Ok ()
            else
              Or_error.error_string
                "WebSocket upgrade rejected: invalid or disallowed Origin")
    | [] | _ :: _ :: _ ->
        Or_error.error_string
          "WebSocket upgrade rejected: invalid or disallowed Origin"
