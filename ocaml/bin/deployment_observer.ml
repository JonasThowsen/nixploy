open Async
open Core

type outcome =
  | Completed of Nixploy.Application.deployment
  | Interrupted of Signal.t

let rec follow application ~scope ~started ~last_event ~render_stage =
  let completion = Nixploy.Application.await_started_deployment started in
  let%bind observation =
    Deferred.choose
      [
        Deferred.choice completion (fun terminal -> `Completed terminal);
        Deferred.choice
          (Nixploy.Application.deployment_history application ~scope ~limit:100)
          (fun history -> `History history);
      ]
  in
  match observation with
  | `Completed terminal -> Deferred.return terminal
  | `History (Error error) -> Deferred.return (Error error)
  | `History (Ok history) -> (
      match
        List.find history ~f:(fun deployment ->
            String.equal
              (Nixploy.Application.deployment_id deployment)
              (Nixploy.Application.started_deployment_id started))
      with
      | None -> Deferred.Or_error.error_string "started deployment disappeared"
      | Some deployment -> (
          let event =
            ( Nixploy.Application.deployment_stage deployment,
              Nixploy.Application.deployment_message deployment )
          in
          if
            not (Option.equal [%equal: string * string] last_event (Some event))
          then render_stage (fst event) (snd event);
          (* Store reads are observer data only. Completion remains the
             application-owned authority for process, lease, and mutation drain. *)
          let%bind wait =
            Deferred.choose
              [
                Deferred.choice completion (fun terminal -> `Completed terminal);
                Deferred.choice
                  (Clock_ns.after (Time_ns.Span.of_ms 100.))
                  (fun () -> `Poll);
              ]
          in
          match wait with
          | `Completed terminal -> Deferred.return terminal
          | `Poll ->
              follow application ~scope ~started ~last_event:(Some event)
                ~render_stage))

let cancel_and_drain application started =
  let cancellation =
    Nixploy.Application.cancel_started_deployment application started
  in
  let completion = Nixploy.Application.await_started_deployment started in
  let%map _ = cancellation and completion = completion in
  completion

let observe_and_drain ?termination ~render_stage application ~scope started =
  let termination =
    Option.value termination
      ~default:(Nixploy.Process_runner.termination_requested ())
  in
  let observed =
    Monitor.try_with (fun () ->
        follow application ~scope ~started ~last_event:None ~render_stage)
    >>| function
    | Ok result -> result
    | Error error -> Error (Error.of_exn error)
  in
  let%bind observation =
    Deferred.choose
      [
        Deferred.choice observed (fun result -> `Observed result);
        Deferred.choice termination (fun signal -> `Signal signal);
      ]
  in
  match observation with
  | `Observed (Ok deployment) -> Deferred.Or_error.return (Completed deployment)
  | `Observed (Error error) ->
      let%bind.Deferred _ = cancel_and_drain application started in
      Deferred.return (Error error)
  | `Signal signal ->
      let%map.Deferred _ = cancel_and_drain application started in
      Ok (Interrupted signal)
