open Async
open Core
open Nixploy

let ok = Or_error.ok_exn

(* The fake podman keeps a log of [window] lines, all after any requested
   instant, and answers like Podman: the newest --tail lines of the window. *)
let run_tests () =
  let open Deferred.Let_syntax in
  let directory = Filename_unix.temp_dir "nixploy-logs-" "" in
  let events = Filename.concat directory "events" in
  let window = Filename.concat directory "window" in
  let program = Filename.concat directory "podman" in
  Out_channel.write_all program
    ~data:
      (sprintf
         {|#!/bin/sh
printf '%%s\n' "$*" >> %s
tail=
previous=
for argument do
  if [ "$previous" = --tail ]; then tail="$argument"; fi
  previous="$argument"
done
last=$(cat %s)
first=$((last - tail + 1))
if [ "$first" -lt 1 ]; then first=1; fi
for index in $(seq "$first" "$last"); do
  printf '2026-11-01T10:00:01Z line-%%04d token=secret-%%d\n' "$index" "$index"
done
|}
         (Filename.quote events) (Filename.quote window));
  Core_unix.chmod program ~perm:0o755;
  Caml_unix.putenv "PATH" (directory ^ ":" ^ Sys.getenv_exn "PATH");
  let since = Log_since.of_string "2026-11-01T10:00:00Z" |> ok in
  let read ?since ~lines () =
    Out_channel.write_all events ~data:"";
    Out_channel.write_all window ~data:(Int.to_string lines);
    let%map snapshot =
      Podman.For_testing.read_container_logs ?since ~connection:"test"
        "container-id"
    in
    (ok snapshot, In_channel.read_lines events)
  in
  let texts (snapshot : Podman.log_snapshot) =
    List.map snapshot.lines ~f:(fun line -> line.text)
  in
  (* A window longer than the bound keeps the newest 500 lines and says so. *)
  let%bind snapshot, argv = read ~since ~lines:600 () in
  [%test_eq: string list]
    [
      "--connection test logs --tail 501 --since 2026-11-01T10:00:00Z \
       --timestamps container-id";
    ]
    argv;
  assert snapshot.truncated;
  [%test_eq: int] 500 (List.length snapshot.lines);
  [%test_eq: string] "line-0101 token=[REDACTED]" (List.hd_exn (texts snapshot));
  [%test_eq: string] "line-0600 token=[REDACTED]"
    (List.last_exn (texts snapshot));
  [%test_eq: string option] (Some "2026-11-01T10:00:01Z")
    (List.hd_exn snapshot.lines).timestamp;
  (* A window of exactly 500 lines is returned whole. *)
  let%bind snapshot, _ = read ~since ~lines:500 () in
  assert (not snapshot.truncated);
  [%test_eq: int] 500 (List.length snapshot.lines);
  [%test_eq: string] "line-0001 token=[REDACTED]" (List.hd_exn (texts snapshot));
  (* Without since, longer logs are bounded and reported the same way. *)
  let%bind snapshot, argv = read ~lines:600 () in
  [%test_eq: string list]
    [ "--connection test logs --tail 501 --timestamps container-id" ]
    argv;
  assert snapshot.truncated;
  [%test_eq: int] 500 (List.length snapshot.lines);
  [%test_eq: string] "line-0101 token=[REDACTED]" (List.hd_exn (texts snapshot));
  [%test_eq: string] "line-0600 token=[REDACTED]"
    (List.last_exn (texts snapshot));
  let%map snapshot, _ = read ~lines:3 () in
  assert (not snapshot.truncated);
  [%test_eq: int] 3 (List.length snapshot.lines)

let () =
  don't_wait_for
    ( Monitor.try_with run_tests >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1 );
  never_returns (Scheduler.go ())
