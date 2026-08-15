open Core
module Authorization = Nixploy_rpc_mapping.Authorization

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let headers ?origin ?host ?login () =
  let headers = Cohttp.Header.init () in
  let headers =
    Option.value_map origin ~default:headers ~f:(fun value ->
        Cohttp.Header.add headers "Origin" value)
  in
  let headers =
    Option.value_map host ~default:headers ~f:(fun value ->
        Cohttp.Header.add headers "Host" value)
  in
  Option.value_map login ~default:headers ~f:(fun value ->
      Cohttp.Header.add headers "Tailscale-User-Login" value)

let request_host_policy = Authorization.origin_policy_of_value None |> assert_ok

let unrestricted =
  Authorization.of_values ~mode:None ~operator_email:None |> assert_ok

let websocket ?origin ?host ?login authorization policy =
  Authorization.authorize_websocket authorization policy
    (headers ?origin ?host ?login ())

let () =
  assert (match unrestricted with Unrestricted -> true | Tailscale _ -> false);
  assert (
    match
      Authorization.of_values ~mode:(Some "unrestricted") ~operator_email:None
    with
    | Ok Unrestricted -> true
    | Ok (Tailscale _) | Error _ -> false);
  let tailscale =
    Authorization.of_values ~mode:(Some "tailscale")
      ~operator_email:(Some " Operator@Example.com ")
    |> assert_ok
  in
  assert (
    match tailscale with Tailscale "operator@example.com" -> true | _ -> false);
  assert (
    Authorization.of_values ~mode:(Some "tailcale")
      ~operator_email:(Some "operator@example.com")
    |> Result.is_error);
  assert (
    Authorization.of_values ~mode:(Some "") ~operator_email:None
    |> Result.is_error);
  assert (
    Authorization.of_values ~mode:(Some "tailscale") ~operator_email:None
    |> Result.is_error);

  (* Same-origin localhost remains the development default. *)
  assert (
    websocket unrestricted request_host_policy ~origin:"http://LOCALHOST:8080"
      ~host:"localhost:8080"
    |> Result.is_ok);
  assert (
    websocket unrestricted request_host_policy ~origin:"https://example.com"
      ~host:"EXAMPLE.COM"
    |> Result.is_ok);
  assert (
    websocket unrestricted request_host_policy ~origin:"http://example.com"
      ~host:"example.com:80"
    |> Result.is_ok);
  assert (
    websocket unrestricted request_host_policy ~origin:"https://example.com:443"
      ~host:"example.com"
    |> Result.is_ok);

  (* Authority equality is exact; suffixes and userinfo never qualify. *)
  assert (
    websocket unrestricted request_host_policy
      ~origin:"https://example.com.evil.invalid" ~host:"example.com"
    |> Result.is_error);
  assert (
    websocket unrestricted request_host_policy
      ~origin:"https://example.com@evil.invalid" ~host:"evil.invalid"
    |> Result.is_error);
  assert (
    websocket unrestricted request_host_policy ~origin:"https://example.com"
      ~host:"example.com:8443"
    |> Result.is_error);
  assert (
    websocket unrestricted request_host_policy ~host:"example.com"
    |> Result.is_error);
  List.iter
    [ "null"; "not a URI"; "ftp://example.com"; "https://example.com/path" ]
    ~f:(fun origin ->
      assert (
        websocket unrestricted request_host_policy ~origin ~host:"example.com"
        |> Result.is_error));

  let configured =
    Authorization.origin_policy_of_value (Some "https://CONTROL.Example:443")
    |> assert_ok
  in
  assert (
    websocket unrestricted configured ~origin:"https://control.example"
      ~host:"internal.invalid:8080"
    |> Result.is_ok);
  assert (
    websocket unrestricted configured ~origin:"https://evil.invalid"
      ~host:"evil.invalid"
    |> Result.is_error);
  assert (
    Authorization.origin_policy_of_value (Some "https://control.example/path")
    |> Result.is_error);

  assert (
    websocket tailscale request_host_policy ~origin:"https://control.example"
      ~host:"control.example" ~login:"operator@example.com"
    |> Result.is_ok);
  assert (
    websocket tailscale request_host_policy ~origin:"https://control.example"
      ~host:"control.example" ~login:"intruder@example.com"
    |> Result.is_error);
  assert (
    websocket tailscale request_host_policy ~host:"control.example"
      ~login:"operator@example.com"
    |> Result.is_error)
