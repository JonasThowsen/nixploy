open Async
open Core

let run_git ?working_directory args =
  Nixploy.Process_runner.run_stdout ?working_directory
    ~timeout:(Time_ns.Span.of_sec 10.) ~max_output_bytes:65_536 ~prog:"git"
    ~args ()
  >>| Or_error.ok_exn

let write path contents = Out_channel.write_all path ~data:contents

let assert_error_containing result substring =
  match result with
  | Ok _ -> failwith "expected an error"
  | Error error ->
      assert (String.is_substring (Error.to_string_hum error) ~substring)

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
  write (Filename.concat directory ".gitignore") "/deps/\n";
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
  let%bind identity =
    Nixploy.Source.repository_identity ~working_directory:directory
  in
  assert (String.equal (Or_error.ok_exn identity) "git@example.invalid:test.git");
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
  write (Filename.concat directory "release.txt") "working-tree-change\n";
  let deps = Filename.concat directory "deps" in
  let expo = Filename.concat deps "expo" in
  let expo_source = Filename.concat expo "src" in
  Core_unix.mkdir deps;
  Core_unix.mkdir expo;
  Core_unix.mkdir expo_source;
  write (Filename.concat expo_source "ignored.ex") "ignored build artifact\n";
  let%bind local_selection =
    Nixploy.Source.local ~working_directory:directory
  in
  let local_selection = Or_error.ok_exn local_selection in
  assert (Nixploy.Source.selection_is_local local_selection);
  let%bind local =
    Nixploy.Source.prepare ~working_directory:directory
      ~selection:local_selection
  in
  let local = Or_error.ok_exn local in
  assert (Nixploy.Source.is_local local);
  let local_path = Nixploy.Source.path local in
  assert (not (String.equal local_path (Filename_unix.realpath directory)));
  assert (String.equal (Nixploy.Source.nix_root local) local_path);
  assert (String.equal (Nixploy.Source.nix_flake local) ".");
  assert (
    String.equal
      (In_channel.read_all (Filename.concat local_path "release.txt"))
      "working-tree-change\n");
  write (Filename.concat directory "release.txt") "changed-after-prepare\n";
  assert (
    String.equal
      (In_channel.read_all (Filename.concat local_path "release.txt"))
      "working-tree-change\n");
  assert (not (Sys_unix.file_exists_exn (Filename.concat local_path "deps")));
  let%bind () = Nixploy.Source.cleanup local in
  assert (Sys_unix.file_exists_exn directory);
  assert (not (Sys_unix.file_exists_exn local_path));
  let untracked = Filename.concat directory "new_source.ex" in
  write untracked "intentional source\n";
  let%bind rejected_untracked =
    Nixploy.Source.prepare ~working_directory:directory
      ~selection:local_selection
  in
  assert_error_containing rejected_untracked "non-ignored untracked files";
  let%bind _ =
    run_git ~working_directory:directory [ "add"; "-N"; "--"; "new_source.ex" ]
  in
  let%bind intent_to_add =
    Nixploy.Source.prepare ~working_directory:directory
      ~selection:local_selection
  in
  let intent_to_add = Or_error.ok_exn intent_to_add in
  assert (
    String.equal
      (In_channel.read_all
         (Filename.concat (Nixploy.Source.path intent_to_add) "new_source.ex"))
      "intentional source\n");
  let%bind () = Nixploy.Source.cleanup intent_to_add in
  let%bind _ =
    run_git ~working_directory:directory [ "reset"; "--"; "new_source.ex" ]
  in
  Core_unix.unlink untracked;
  let%bind mismatched =
    Nixploy.Source.prepare ~working_directory:application_directory
      ~selection:local_selection
  in
  assert (Result.is_error mismatched);
  let%bind prepared =
    Nixploy.Source.prepare ~working_directory:directory
      ~selection:(Nixploy.Source.immutable preview)
  in
  let prepared = Or_error.ok_exn prepared in
  assert (String.equal revision_a (Nixploy.Source.revision prepared));
  assert (
    not
      (Sys_unix.file_exists_exn
         (Filename.concat (Nixploy.Source.nix_root prepared) ".git")));
  assert (
    String.equal "git@example.invalid:test.git"
      (Nixploy.Source.repository prepared));
  assert (
    String.equal
      (In_channel.read_all
         (Filename.concat (Nixploy.Source.path prepared) "release.txt"))
      "release-a\n");
  let%bind () = Nixploy.Source.cleanup prepared in
  let%bind _ =
    run_git ~working_directory:directory
      [ "config"; "--unset-all"; "remote.origin.url" ]
  in
  let%bind fallback =
    Nixploy.Source.repository_identity ~working_directory:application_directory
  in
  assert (
    String.equal (Or_error.ok_exn fallback)
      (Filename_unix.realpath application_directory));
  let%bind nested =
    Nixploy.Source.prepare ~working_directory:application_directory
      ~selection:(Nixploy.Source.immutable preview)
  in
  let nested = Or_error.ok_exn nested in
  assert (
    String.equal
      (Nixploy.Source.repository nested)
      (Filename_unix.realpath application_directory));
  assert (
    String.equal
      (Nixploy.Source.path nested)
      (Filename.concat (Nixploy.Source.nix_root nested) "application"));
  assert (
    String.equal (Nixploy.Source.nix_flake nested) "path:.?dir=application");
  assert (
    not
      (Sys_unix.file_exists_exn
         (Filename.concat (Nixploy.Source.nix_root nested) ".git")));
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
