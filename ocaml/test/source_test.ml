open Async
open Core

let run_git ?working_directory args =
  Nixploy.Process_runner.run_stdout ?working_directory
    ~timeout:(Time_ns.Span.of_sec 10.) ~max_output_bytes:65_536 ~prog:"git"
    ~args ()
  >>| Or_error.ok_exn

let write path contents = Out_channel.write_all path ~data:contents

let run_tests () =
  let open Deferred.Let_syntax in
  let directory = Filename_unix.temp_dir "nixploy-source-test-" "" in
  let%bind _ = run_git [ "init"; "-b"; "main"; directory ] in
  let%bind _ =
    run_git ~working_directory:directory
      [ "config"; "user.email"; "test@nixploy" ]
  in
  let%bind _ =
    run_git ~working_directory:directory
      [ "config"; "user.name"; "Nixploy Test" ]
  in
  let%bind _ =
    run_git ~working_directory:directory
      [ "config"; "remote.origin.url"; "git@example.invalid:test.git" ]
  in
  write (Filename.concat directory "flake.nix") "{ outputs = _: {}; }\n";
  write (Filename.concat directory "flake.lock") "{}\n";
  write (Filename.concat directory "release.txt") "release-a\n";
  let application_directory = Filename.concat directory "application" in
  Core_unix.mkdir application_directory;
  write
    (Filename.concat application_directory "flake.nix")
    "{ outputs = _: {}; }\n";
  write (Filename.concat application_directory "flake.lock") "{}\n";
  write (Filename.concat application_directory "release.txt") "nested-a\n";
  let%bind _ = run_git ~working_directory:directory [ "add"; "." ] in
  let%bind _ =
    run_git ~working_directory:directory [ "commit"; "-m"; "Release A" ]
  in
  let%bind preview = Nixploy.Source.preview_main ~working_directory:directory in
  let preview = Or_error.ok_exn preview in
  assert (String.equal (Nixploy.Source.commit_subject preview) "Release A");
  let revision_a = Nixploy.Source.commit_revision preview in
  write (Filename.concat directory "release.txt") "release-b\n";
  let%bind _ = run_git ~working_directory:directory [ "add"; "release.txt" ] in
  let%bind _ =
    run_git ~working_directory:directory [ "commit"; "-m"; "Release B" ]
  in
  let%bind latest = Nixploy.Source.preview_main ~working_directory:directory in
  let latest = Or_error.ok_exn latest in
  assert (not (String.equal revision_a (Nixploy.Source.commit_revision latest)));
  let%bind prepared =
    Nixploy.Source.prepare ~working_directory:directory ~commit:preview
  in
  let prepared = Or_error.ok_exn prepared in
  assert (String.equal revision_a (Nixploy.Source.revision prepared));
  assert (
    String.equal
      (In_channel.read_all
         (Filename.concat (Nixploy.Source.path prepared) "release.txt"))
      "release-a\n");
  let%bind () = Nixploy.Source.cleanup prepared in
  let%bind nested =
    Nixploy.Source.prepare ~working_directory:application_directory
      ~commit:preview
  in
  let nested = Or_error.ok_exn nested in
  assert (
    String.equal
      (In_channel.read_all
         (Filename.concat (Nixploy.Source.path nested) "release.txt"))
      "nested-a\n");
  let%bind () = Nixploy.Source.cleanup nested in
  let%map _ =
    Nixploy.Process_runner.run_stdout ~timeout:(Time_ns.Span.of_sec 5.)
      ~max_output_bytes:65_536 ~prog:"rm" ~args:[ "-rf"; "--"; directory ] ()
  in
  ()

let () =
  don't_wait_for
    ( Monitor.try_with run_tests >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1 );
  never_returns (Scheduler.go ())
