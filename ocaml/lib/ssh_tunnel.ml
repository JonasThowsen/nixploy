open Async
open Core

let ready_timeout = Time_ns.Span.of_sec 30.
let poll_interval = Time_ns.Span.of_ms 50.
let stop_grace = Time_ns.Span.of_sec 2.
let max_stderr_bytes = 16_384

(* Keeps the newest [max_stderr_bytes] of what ssh writes to stderr, for as
   long as it runs, so a long-lived forward never fills the pipe. *)
let collect_stderr reader =
  let kept = ref "" in
  let buffer = Bytes.create 4096 in
  let rec loop () =
    match%bind Reader.read reader buffer with
    | `Eof -> return ()
    | `Ok length ->
        let text = !kept ^ Bytes.To_string.sub buffer ~pos:0 ~len:length in
        kept :=
          String.suffix text (Int.min (String.length text) max_stderr_bytes);
        loop ()
  in
  (kept, Monitor.handle_errors loop ignore)

let group_exists group =
  match Signal_unix.send Signal.zero group with
  | `Ok -> true
  | `No_such_process -> false

let stop process =
  let group = `Group (Process.pid process) in
  if group_exists group then (
    Signal_unix.send_i Signal.term group;
    let%map () =
      Deferred.any_unit
        [ Deferred.ignore_m (Process.wait process); Clock_ns.after stop_grace ]
    in
    if group_exists group then Signal_unix.send_i Signal.kill group)
  else Deferred.unit

let socket_exists path = Async.Sys.file_exists_exn path

let open_unix_forward ~target ~local_socket ~remote_socket =
  let open Deferred.Let_syntax in
  match%bind
    Process.create ~setpgid:Core_unix.Pgid.new_process_group ~prog:"ssh"
      ~args:
        (Remote_command.unix_forward_args target ~local_socket ~remote_socket)
      ()
  with
  | Error _ as error -> return error
  | Ok process -> (
      let%bind () = Writer.close (Process.stdin process) in
      don't_wait_for (Reader.drain (Process.stdout process));
      let stderr, stderr_closed = collect_stderr (Process.stderr process) in
      let exited = Process.wait process in
      let deadline = Time_ns.add (Time_ns.now ()) ready_timeout in
      let rec wait_until_ready () =
        if%bind socket_exists local_socket then return `Ready
        else if Deferred.is_determined exited then return `Exited
        else if Time_ns.( >= ) (Time_ns.now ()) deadline then return `Timed_out
        else
          let%bind () =
            Deferred.any_unit
              [ Deferred.ignore_m exited; Clock_ns.after poll_interval ]
          in
          wait_until_ready ()
      in
      match%bind wait_until_ready () with
      | `Ready ->
          Shutdown.at_shutdown (fun () -> stop process);
          return (Ok ())
      | `Exited ->
          (* Let the reader take ssh's last words before reporting them. *)
          let%map () =
            Deferred.any_unit [ stderr_closed; Clock_ns.after stop_grace ]
          in
          Error (Remote_command.ssh_failure target !stderr)
      | `Timed_out ->
          let%map () = stop process in
          Or_error.errorf
            "NIXPLOY_SSH_FAILED: ssh did not open the Podman socket forward to \
             %s within %s"
            (Configuration.Target.host target)
            (Time_ns.Span.to_short_string ready_timeout))
