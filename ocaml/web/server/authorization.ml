open Core

type t = Unrestricted | Tailscale of string

let normalized_login login = String.strip login |> String.lowercase

let of_values ~mode ~operator_email =
  match
    Option.map mode ~f:(fun mode -> String.strip mode |> String.lowercase)
  with
  | None | Some "unrestricted" -> Ok Unrestricted
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

let authorized authorization headers =
  match authorization with
  | Unrestricted -> true
  | Tailscale expected ->
      Cohttp.Header.get headers "tailscale-user-login"
      |> Option.exists ~f:(fun login ->
          String.equal (normalized_login login) expected)
