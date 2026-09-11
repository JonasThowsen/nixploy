open Async
open Core

let with_guard ?(certainty = fun _ -> None) ~run ~interrupted ~project ~target
    action =
  let open Deferred.Or_error.Let_syntax in
  let%bind key =
    Deferred.return (Resource_key.derive_current ~project ~target)
  in
  let parent = ".nixploy-mutations" in
  let directory = parent ^ "/" ^ Resource_key.to_string key in
  let%bind () = run [ "mkdir"; "-p"; "-m"; "700"; "--"; parent ] in
  let%bind () = run [ "sync"; "-f"; "." ] in
  let%bind () =
    let%map.Deferred result = run [ "mkdir"; "-m"; "700"; "--"; directory ] in
    Result.map_error result ~f:(fun error ->
        Error.tag error
          ~tag:
            ("NIXPLOY_MUTATION_BLOCKED: cannot acquire " ^ directory
           ^ "; another operation or retained uncertainty evidence exists. "
           ^ "Do not remove evidence until remote effects are reconciled"))
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
  let%bind.Deferred result = Monitor.try_with_or_error action in
  match Or_error.join result with
  | Error error ->
      Deferred.Or_error.fail
        (Error.tag error
           ~tag:
             ("NIXPLOY_MUTATION_UNCERTAIN: evidence retained at " ^ directory
            ^ "; reconcile remote state before any further mutation"))
  | Ok value when Option.is_some (certainty value) ->
      Deferred.Or_error.return value
  | Ok _ when interrupted () ->
      Deferred.Or_error.errorf
        "NIXPLOY_MUTATION_INTERRUPTED: evidence retained at %s; remote effects \
         may still be running"
        directory
  | Ok value ->
      let%map.Deferred released =
        let open Deferred.Or_error.Let_syntax in
        let%bind () = run [ "rmdir"; "--"; directory ] in
        run [ "sync"; "-f"; parent ]
      in
      Result.map released ~f:(fun () -> value)
      |> Result.map_error ~f:(fun error ->
          Error.tag error
            ~tag:
              ("NIXPLOY_MUTATION_RELEASE_UNKNOWN: remote effects completed; \
                inspect guard " ^ directory ^ " before retrying"))

let with_mutation ?certainty ~project ~target action =
  let run argv =
    let open Deferred.Or_error.Let_syntax in
    let%bind result =
      Remote_command.run ~target ~timeout:(Time_ns.Span.of_sec 15.)
        ~max_output_bytes:4096 argv
    in
    match result.exit_status with
    | Ok () -> Deferred.Or_error.return ()
    | Error _ ->
        Deferred.Or_error.error_string
          "NIXPLOY_MUTATION_GUARD_COMMAND_FAILED: remote guard command failed"
  in
  with_guard ?certainty ~run
    ~interrupted:(fun () ->
      Option.is_some (Process_runner.termination_signal ())
      || Option.exists (Cancellation.current ()) ~f:Cancellation.was_requested)
    ~project
    ~target:(Configuration.Target.name target)
    action

module For_testing = struct
  let with_mutation = with_guard
end
