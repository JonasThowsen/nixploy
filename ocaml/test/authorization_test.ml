open Core
module Authorization = Nixploy_rpc_mapping.Authorization

let () =
  assert (
    match Authorization.of_values ~mode:None ~operator_email:None with
    | Ok Unrestricted -> true
    | Ok (Tailscale _) | Error _ -> false);
  assert (
    match
      Authorization.of_values ~mode:(Some "unrestricted") ~operator_email:None
    with
    | Ok Unrestricted -> true
    | Ok (Tailscale _) | Error _ -> false);
  assert (
    match
      Authorization.of_values ~mode:(Some "tailscale")
        ~operator_email:(Some " Operator@Example.com ")
    with
    | Ok (Tailscale "operator@example.com") -> true
    | Ok _ | Error _ -> false);
  assert (
    Authorization.of_values ~mode:(Some "tailcale")
      ~operator_email:(Some "operator@example.com")
    |> Result.is_error);
  assert (
    Authorization.of_values ~mode:(Some "") ~operator_email:None
    |> Result.is_error);
  assert (
    Authorization.of_values ~mode:(Some "tailscale") ~operator_email:None
    |> Result.is_error)
