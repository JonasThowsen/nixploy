open Async
open Core

let parent = ".nixploy-mutations"

let marker_directory ~project ~target =
  let%map.Or_error key = Resource_key.derive_current ~project ~target in
  parent ^ "/" ^ Resource_key.to_string key

let owner_file directory = directory ^ ".owner"

let recovery_hint ~target =
  sprintf "check `nixploy status -t %s`, then run `nixploy unlock -t %s`"
    (Target_name.to_string target)
    (Target_name.to_string target)

let with_guard ?(certainty = fun _ -> None)
    ?(record_owner = fun _ -> Deferred.unit)
    ?(clear_owner = fun _ -> Deferred.unit) ~run ~interrupted ~project ~target
    action =
  let open Deferred.Or_error.Let_syntax in
  let%bind directory = Deferred.return (marker_directory ~project ~target) in
  let%bind () = run [ "mkdir"; "-p"; "-m"; "700"; "--"; parent ] in
  let%bind () = run [ "sync"; "-f"; "." ] in
  let%bind () =
    let%map.Deferred result = run [ "mkdir"; "-m"; "700"; "--"; directory ] in
    Result.map_error result ~f:(fun error ->
        Error.tag error
          ~tag:
            ("NIXPLOY_MUTATION_BLOCKED: cannot acquire " ^ directory
           ^ "; another operation is running or left uncertainty evidence. "
           ^ recovery_hint ~target))
  in
  (* Persist the directory entry before any remote mutation. A lost response to
     either command leaves evidence and never starts the callback. *)
  let%bind () =
    let%map.Deferred result = run [ "sync"; "-f"; parent ] in
    Result.map_error result ~f:(fun error ->
        Error.tag error
          ~tag:
            ("NIXPLOY_MUTATION_DURABILITY_FAILED: evidence retained at "
           ^ directory ^ "; mutation was not started"))
  in
  let%bind.Deferred () = record_owner directory in
  let%bind.Deferred result = Monitor.try_with_or_error action in
  match Or_error.join result with
  | Error error ->
      Deferred.Or_error.fail
        (Error.tag error
           ~tag:
             ("NIXPLOY_MUTATION_UNCERTAIN: evidence retained at " ^ directory
            ^ "; " ^ recovery_hint ~target))
  | Ok value when Option.is_some (certainty value) ->
      Deferred.Or_error.return value
  | Ok _ when interrupted () ->
      Deferred.Or_error.errorf
        "NIXPLOY_MUTATION_INTERRUPTED: evidence retained at %s; remote effects \
         may still be running; %s"
        directory (recovery_hint ~target)
  | Ok value ->
      let%bind.Deferred released =
        let open Deferred.Or_error.Let_syntax in
        let%bind () = run [ "rmdir"; "--"; directory ] in
        run [ "sync"; "-f"; parent ]
      in
      let%map.Deferred () =
        if Result.is_ok released then clear_owner directory else Deferred.unit
      in
      Result.map released ~f:(fun () -> value)
      |> Result.map_error ~f:(fun error ->
          Error.tag error
            ~tag:
              ("NIXPLOY_MUTATION_RELEASE_UNKNOWN: remote effects completed; \
                inspect guard " ^ directory ^ " before retrying"))

let with_mutation_for ?certainty ~host ~project ~target_name action =
  let target = host in
  let run argv =
    let open Deferred.Or_error.Let_syntax in
    let%bind result =
      Remote_command.run ~target ~timeout:(Time_ns.Span.of_sec 15.)
        ~max_output_bytes:4096 argv
    in
    match result.exit_status with
    | Ok () -> Deferred.Or_error.return ()
    | Error failure ->
        Deferred.Or_error.errorf
          "NIXPLOY_MUTATION_GUARD_COMMAND_FAILED: remote %s failed (%s): %s"
          (List.hd argv |> Option.value ~default:"command")
          (Core_unix.Exit_or_signal.to_string_hum (Error failure))
          (String.prefix (String.strip result.stderr) 512)
  in
  let record_owner directory =
    let owner =
      sprintf "command=%s\nhost=%s\npid=%d\nstarted=%s\n"
        (String.concat ~sep:" " (Array.to_list (Sys.get_argv ()))
        |> String.map ~f:(fun c -> if Char.equal c '\n' then ' ' else c))
        (Core_unix.gethostname ())
        (Pid.to_int (Core_unix.getpid ()))
        (Time_ns.to_string_iso8601_basic (Time_ns.now ())
           ~zone:Time_float.Zone.utc)
    in
    (* Best effort: the directory alone is the guard; the owner record only
       helps an operator identify the holder, and older clients ignore it. It
       is a symlink target so no stdin is streamed to a possibly failing ssh. *)
    Remote_command.run ~target ~timeout:(Time_ns.Span.of_sec 15.)
      ~max_output_bytes:4096
      [
        "ln";
        "-s";
        "-f";
        "-n";
        "--";
        String.prefix owner 2048;
        owner_file directory;
      ]
    |> Deferred.ignore_m
  in
  let clear_owner directory =
    Remote_command.run ~target ~timeout:(Time_ns.Span.of_sec 15.)
      ~max_output_bytes:4096
      [ "rm"; "-f"; "--"; owner_file directory ]
    |> Deferred.ignore_m
  in
  with_guard ?certainty ~record_owner ~clear_owner ~run
    ~interrupted:(fun () ->
      Option.is_some (Process_runner.termination_signal ())
      || Option.exists (Cancellation.current ()) ~f:Cancellation.was_requested)
    ~project ~target:target_name action

let with_mutation ?certainty ~project ~target action =
  with_mutation_for ?certainty ~host:target ~project
    ~target_name:(Configuration.Target.name target)
    action

let list_markers ~host =
  let open Deferred.Or_error.Let_syntax in
  let%bind result =
    Remote_command.run ~target:host ~timeout:(Time_ns.Span.of_sec 15.)
      ~max_output_bytes:65_536
      [ "find"; parent; "-mindepth"; "1"; "-maxdepth"; "1"; "-type"; "d" ]
  in
  match result.exit_status with
  | Ok () ->
      Deferred.Or_error.return
        (String.split_lines result.stdout
        |> List.filter_map ~f:(fun line ->
            String.chop_prefix (String.strip line) ~prefix:(parent ^ "/"))
        |> List.sort ~compare:String.compare)
  | Error _ when String.is_substring result.stderr ~substring:"No such file" ->
      Deferred.Or_error.return []
  | Error failure ->
      Deferred.Or_error.errorf "mutation marker listing failed (%s)"
        (Core_unix.Exit_or_signal.to_string_hum (Error failure))

type marker = Absent | Present of string [@@deriving compare, equal, sexp]

let inspect ~project ~target =
  let open Deferred.Or_error.Let_syntax in
  let%bind directory =
    Deferred.return
      (marker_directory ~project ~target:(Configuration.Target.name target))
  in
  let%bind result =
    Remote_command.run ~target ~timeout:(Time_ns.Span.of_sec 15.)
      ~max_output_bytes:4096
      [ "test"; "-d"; directory ]
  in
  match result.exit_status with
  | Ok () -> Deferred.Or_error.return (Present directory)
  | Error (`Exit_non_zero 1) -> Deferred.Or_error.return Absent
  | Error failure ->
      Deferred.Or_error.errorf "mutation marker check failed (%s)"
        (Core_unix.Exit_or_signal.to_string_hum (Error failure))

type holder = {
  directory : string;
  owner : (string * string) list;
  acquired_at_unix : int64 option;
}

let parse_owner text =
  String.split_lines text
  |> List.filter_map ~f:(fun line ->
      match String.lsplit2 line ~on:'=' with
      | Some (key, value) when not (String.is_empty key) ->
          Some (String.strip key, String.strip value)
      | _ -> None)

let inspect_holder ~project ~target =
  let open Deferred.Or_error.Let_syntax in
  let%bind marker = inspect ~project ~target in
  match marker with
  | Absent -> return None
  | Present directory ->
      let run argv =
        Remote_command.run ~target ~timeout:(Time_ns.Span.of_sec 15.)
          ~max_output_bytes:4096 argv
      in
      let%bind owner = run [ "readlink"; "--"; owner_file directory ] in
      let%map stat = run [ "stat"; "-c"; "%Y"; "--"; directory ] in
      let owner =
        match owner.exit_status with
        | Ok () -> parse_owner owner.stdout
        | Error _ -> []
      in
      let acquired_at_unix =
        match stat.exit_status with
        | Ok () -> Int64.of_string_opt (String.strip stat.stdout)
        | Error _ -> None
      in
      Some { directory; owner; acquired_at_unix }

let remove_retained ~project ~target ~directory =
  let open Deferred.Or_error.Let_syntax in
  let%bind expected =
    Deferred.return
      (marker_directory ~project ~target:(Configuration.Target.name target))
  in
  if not (String.equal expected directory) then
    Deferred.Or_error.errorf "refusing to remove %s: the marker for %s is %s"
      directory
      (Target_name.to_string (Configuration.Target.name target))
      expected
  else
    let run argv =
      let%bind result =
        Remote_command.run ~target ~timeout:(Time_ns.Span.of_sec 15.)
          ~max_output_bytes:4096 argv
      in
      match result.exit_status with
      | Ok () -> return ()
      | Error failure ->
          Deferred.Or_error.errorf "remote %s failed (%s): %s"
            (List.hd_exn argv)
            (Core_unix.Exit_or_signal.to_string_hum (Error failure))
            (String.strip result.stderr)
    in
    let%bind () = run [ "rmdir"; "--"; directory ] in
    let%bind () = run [ "sync"; "-f"; parent ] in
    run [ "rm"; "-f"; "--"; owner_file directory ]

module For_testing = struct
  let with_mutation ?certainty ~run ~interrupted ~project ~target action =
    with_guard ?certainty ~run ~interrupted ~project ~target action
end
