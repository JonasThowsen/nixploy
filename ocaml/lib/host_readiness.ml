open Async
open Core

type state = Ready | Not_ready | Unknown of string
[@@deriving compare, equal, sexp]

type check = { name : string; state : state; remedy : string }
[@@deriving compare, equal, sexp]

type t = check list
type probe = Process_runner.t Or_error.t

let checks t = t
let probe_timeout = Time_ns.Span.of_sec 20.
let max_probe_output = 16_384

let bounded text =
  let text = String.strip text in
  if String.length text > 200 then String.prefix text 200 ^ "..." else text

let probe_failure (result : Process_runner.t) =
  let detail =
    if String.is_empty (String.strip result.stderr) then result.stdout
    else result.stderr
  in
  sprintf "%s: %s"
    (Core_unix.Exit_or_signal.to_string_hum result.exit_status)
    (bounded detail)

let restart_unit_state (probe : probe) =
  match probe with
  | Error error -> Unknown (bounded (Error.to_string_hum error))
  | Ok result -> (
      match (result.exit_status, String.strip result.stdout) with
      | Ok (), ("enabled" | "enabled-runtime" | "alias" | "linked") -> Ready
      | Ok (), _ | Error _, ("disabled" | "masked" | "static" | "indirect") ->
          Not_ready
      | Error _, _ ->
          if String.is_substring result.stderr ~substring:"No such file" then
            Not_ready
          else Unknown (probe_failure result))

let linger_state (probe : probe) =
  match probe with
  | Error error -> Unknown (bounded (Error.to_string_hum error))
  | Ok ({ exit_status = Ok (); _ } as result) -> (
      match String.strip result.stdout with
      | "yes" -> Ready
      | "no" -> Not_ready
      | other -> Unknown ("unexpected loginctl output: " ^ bounded other))
  | Ok result -> Unknown (probe_failure result)

let caddy_resume_state (probe : probe) =
  match probe with
  | Error error -> Unknown (bounded (Error.to_string_hum error))
  | Ok ({ exit_status = Ok (); _ } as result) ->
      let exec_start = String.strip result.stdout in
      if String.is_empty exec_start then Unknown "caddy.service was not found"
      else if String.is_substring exec_start ~substring:"--resume" then Ready
      else Not_ready
  | Ok result -> Unknown (probe_failure result)

let rootless (uid : probe) =
  match uid with
  | Ok { exit_status = Ok (); stdout; _ } -> (
      match String.strip stdout with
      | "0" -> Some false
      | uid
        when (not (String.is_empty uid)) && String.for_all uid ~f:Char.is_digit
        ->
          Some true
      | _ -> None)
  | Ok _ | Error _ -> None

let assess ~user ~web ~uid ~linger ~restart_unit ~caddy_exec_start =
  let restart_check ~rootless =
    let remedy =
      if rootless then
        "enable the user unit, e.g. NixOS \
         systemd.user.services.podman-restart.wantedBy = [ \"default.target\" \
         ]"
      else
        "enable the system unit, e.g. NixOS \
         systemd.services.podman-restart.wantedBy = [ \"multi-user.target\" ]"
    in
    {
      name = "podman-restart.service starts owned containers at boot";
      state = restart_unit_state restart_unit;
      remedy;
    }
  in
  let podman_checks =
    match rootless uid with
    | Some true ->
        [
          {
            name =
              sprintf "user %s lingers so its containers run without a login"
                user;
            state = linger_state linger;
            remedy = sprintf "NixOS users.users.%s.linger = true" user;
          };
          restart_check ~rootless:true;
        ]
    | Some false -> [ restart_check ~rootless:false ]
    | None ->
        [
          {
            name = "podman restarts owned containers at boot";
            state =
              Unknown
                (match uid with
                | Error error -> bounded (Error.to_string_hum error)
                | Ok result ->
                    "could not read the remote uid: " ^ probe_failure result);
            remedy = "verify SSH access to the target";
          };
        ]
  in
  let caddy_checks =
    if web then
      [
        {
          name = "Caddy resumes nixploy routes after a restart";
          state = caddy_resume_state caddy_exec_start;
          remedy =
            "NixOS services.caddy.resume = true; routes set through the Caddy \
             admin API are otherwise lost on restart";
        };
      ]
    else []
  in
  podman_checks @ caddy_checks

let warnings t =
  List.filter_map t ~f:(fun check ->
      match check.state with
      | Ready -> None
      | Not_ready ->
          Some (sprintf "not ready: %s; fix: %s" check.name check.remedy)
      | Unknown reason ->
          Some
            (sprintf "unknown: %s (%s); fix: %s" check.name reason check.remedy))

let run_probe ~target argv =
  Remote_command.run ~target ~timeout:probe_timeout
    ~max_output_bytes:max_probe_output argv

let inspect ~target =
  let user = Configuration.Target.user target in
  let web =
    match Configuration.Target.kind target with
    | Web _ -> true
    | Non_web -> false
  in
  let skipped = Or_error.error_string "not probed" in
  let%bind uid = run_probe ~target [ "id"; "-u" ] in
  let caddy_exec_start () =
    if web then
      run_probe ~target
        [
          "systemctl";
          "show";
          "caddy.service";
          "--property=ExecStart";
          "--value";
        ]
    else return skipped
  in
  let%map linger, restart_unit, caddy_exec_start =
    match rootless uid with
    | Some true ->
        let%map linger =
          run_probe ~target
            [ "loginctl"; "show-user"; user; "--property=Linger"; "--value" ]
        and restart_unit =
          run_probe ~target
            [ "systemctl"; "--user"; "is-enabled"; "podman-restart.service" ]
        and caddy = caddy_exec_start () in
        (linger, restart_unit, caddy)
    | Some false ->
        let%map restart_unit =
          run_probe ~target
            [ "systemctl"; "is-enabled"; "podman-restart.service" ]
        and caddy = caddy_exec_start () in
        (skipped, restart_unit, caddy)
    | None ->
        let%map caddy = caddy_exec_start () in
        (skipped, skipped, caddy)
  in
  assess ~user ~web ~uid ~linger ~restart_unit ~caddy_exec_start

module For_testing = struct
  type nonrec probe = probe

  let assess = assess
end
