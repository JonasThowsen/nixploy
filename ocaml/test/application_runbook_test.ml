open Async
open Core
open Nixploy

let write_executable path text =
  Out_channel.write_all path ~data:text;
  Core_unix.chmod path ~perm:0o755

let command ~directory prog args =
  Process_runner.run_stdout ~working_directory:directory
    ~timeout:(Time_ns.Span.of_sec 10.) ~max_output_bytes:65536 ~prog ~args ()
  >>| Or_error.ok_exn

let run_tests () =
  let open Deferred.Let_syntax in
  let root = Filename_unix.temp_dir "nixploy-facade-runbook-" "" in
  let repository = Filename.concat root "repository" in
  let remote = Filename.concat root "remote" in
  let bin = Filename.concat root "bin" in
  let trace = Filename.concat root "trace" in
  List.iter [ repository; remote; bin ] ~f:(fun directory ->
      Core_unix.mkdir directory);
  let%bind _ = command ~directory:repository "git" [ "init"; "-b"; "main" ] in
  let%bind _ =
    command ~directory:repository "git"
      [ "config"; "remote.origin.url"; "git@example.invalid:fixture.git" ]
  in
  write_executable
    (Filename.concat bin "nix")
    {|#!/bin/sh
set -eu
printf 'nix\n' >> "$FACADE_TRACE"
printf '%s\n' '{"__schema":"v0.5","project":"example","targets":{"test":{"image":"unused","ip":"test.invalid","runbook":{"migrate":{"description":"Migrate","command":["/app/bin/app","migrate"]}}}}}'
|};
  write_executable
    (Filename.concat bin "ssh")
    {|#!/bin/sh
set -eu
printf 'ssh|%s\n' "$*" >> "$FACADE_TRACE"
last=""
for arg in "$@"; do last="$arg"; done
case "$last" in
  "'mkdir' "*|"'sync' "*|"'rmdir' "*) cd "$FACADE_REMOTE"; eval "$last" ;;
  *"'podman' 'ps'"*) test -d "$FACADE_GUARD"; printf '[]\n' ;;
  "'true'") test -d "$FACADE_GUARD" ;;
  *) echo 'unexpected SSH command' >&2; exit 99 ;;
esac
|};
  write_executable
    (Filename.concat bin "podman")
    {|#!/bin/sh
set -eu
printf 'podman|%s\n' "$*" >> "$FACADE_TRACE"
test -d "$FACADE_GUARD"
case "$*" in
  'system connection list --format json') printf '[]\n'; exit 0 ;;
  'system connection add '*|*' info') exit 0 ;;
esac
case "${3:-}" in
  container) exit 0 ;;
  inspect)
    name=$6
    printf '[{"Id":"%s","Name":"%s","State":{"Running":true},"Config":{"Labels":{"io.nixploy.managed":"true","io.nixploy.project":"example","io.nixploy.target":"test","io.nixploy.resource_key":"%s","io.nixploy.repository_identity":"git@example.invalid:fixture.git","io.nixploy.revision":"revision","io.nixploy.operation_id":"operation"}}}]\n' "$FACADE_ID" "$name" "$name"
    ;;
  exec)
    printf 'exec\n' >> "$FACADE_EXEC"
    test "$4" = --
    test "$5" = "$FACADE_ID"
    test "$6" = /app/bin/app
    test "$7" = migrate
    exit "$FACADE_EXIT"
    ;;
  *) echo 'unexpected Podman command' >&2; exit 99 ;;
esac
|};
  let project = Project_name.of_string "example" |> Or_error.ok_exn in
  let target = Target_name.of_string "test" |> Or_error.ok_exn in
  let key = Resource_key.derive_current ~project ~target |> Or_error.ok_exn in
  let evidence =
    Filename.concat remote (".nixploy-mutations/" ^ Resource_key.to_string key)
  in
  let executed = Filename.concat root "executed" in
  let container_id = String.make 64 'a' in
  let variables =
    [
      "PATH";
      "FACADE_TRACE";
      "FACADE_REMOTE";
      "FACADE_GUARD";
      "FACADE_ID";
      "FACADE_EXEC";
      "FACADE_EXIT";
      "SSH_AUTH_SOCK";
    ]
  in
  let saved = List.map variables ~f:(fun key -> (key, Sys.getenv key)) in
  List.iter
    [
      ("PATH", bin ^ ":" ^ Sys.getenv_exn "PATH");
      ("FACADE_TRACE", trace);
      ("FACADE_REMOTE", remote);
      ("FACADE_GUARD", evidence);
      ("FACADE_ID", container_id);
      ("FACADE_EXEC", executed);
      ("FACADE_EXIT", "0");
    ]
    ~f:(fun (key, value) -> Caml_unix.putenv key value);
  Core_unix.unsetenv "SSH_AUTH_SOCK";
  Monitor.protect
    ~finally:(fun () ->
      List.iter saved ~f:(fun (key, value) ->
          match value with
          | Some value -> Caml_unix.putenv key value
          | None -> Core_unix.unsetenv key);
      Deferred.unit)
    (fun () ->
      let%bind commands =
        Application.runbook ~working_directory:repository ~target
      in
      assert (List.length (Or_error.ok_exn commands) = 1);
      assert (List.equal String.equal (In_channel.read_lines trace) [ "nix" ]);
      assert (not (Sys_unix.file_exists_exn evidence));
      let selected = ref 0 in
      let on_selection (selection : Runbook.selection) =
        assert (Sys_unix.file_exists_exn evidence);
        assert (String.equal selection.container_id container_id);
        incr selected;
        Deferred.unit
      in
      let run code =
        Caml_unix.putenv "FACADE_EXIT" (Int.to_string code);
        Application.run ~on_selection ~working_directory:repository ~target
          ~name:"migrate"
      in
      let%bind success = run 0 in
      assert ((Or_error.ok_exn success).exit_code = 0);
      assert (not (Sys_unix.file_exists_exn evidence));
      let%bind known_failure = run 23 in
      let known_failure = Or_error.ok_exn known_failure in
      assert (
        known_failure.exit_code = 23 && Option.is_none known_failure.uncertainty);
      assert (not (Sys_unix.file_exists_exn evidence));
      let%bind unknown = run 125 in
      let unknown = Or_error.ok_exn unknown in
      assert (unknown.exit_code = 125 && Option.is_some unknown.uncertainty);
      assert (Sys_unix.file_exists_exn evidence);
      let%bind blocked = run 0 in
      assert (Result.is_error blocked);
      assert (!selected = 3);
      assert (List.length (In_channel.read_lines executed) = 3);
      (* Only the fixture reconciles a known fake effect; no production unlock API. *)
      let%bind () = Async.Unix.rmdir evidence in
      let%bind transport = run 255 in
      let transport = Or_error.ok_exn transport in
      assert (transport.exit_code = 255 && Option.is_some transport.uncertainty);
      assert (Sys_unix.file_exists_exn evidence);
      assert (List.length (In_channel.read_lines executed) = 4);
      assert (
        not
          (Sys_unix.file_exists_exn (Filename.concat repository "state.sqlite")));
      printf
        "Application runbook: guarded resolution/exec, no replay/history, \
         known 23 release, uncertain 125/255 preserved and retained\n\
         %!";
      Deferred.unit)

let () =
  don't_wait_for
    ( Monitor.try_with_or_error run_tests >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n%!" (Error.to_string_hum error);
          Shutdown.shutdown 1 );
  never_returns (Scheduler.go ())
