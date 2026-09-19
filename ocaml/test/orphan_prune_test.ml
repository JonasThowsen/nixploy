open Async
open Core
module Inspection_output = Nixploy_cli_mapping.Inspection_output

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let expect_error_containing result text =
  match result with
  | Ok _ -> failwith "orphan prune unexpectedly succeeded"
  | Error error ->
      let message = Error.to_string_hum error in
      if not (String.is_substring message ~substring:text) then
        failwithf "expected %S in: %s" text message ()

let write path contents = Out_channel.write_all path ~data:contents

let install_executable directory name contents =
  let path = Filename.concat directory name in
  write path contents;
  Caml_unix.chmod path 0o755

let run_git ?working_directory args =
  Nixploy.Process_runner.run_stdout ?working_directory
    ~timeout:(Time_ns.Span.of_sec 10.) ~max_output_bytes:65_536 ~prog:"git"
    ~args ()
  >>| Or_error.ok_exn

let repository_identity = "git@example.invalid:shop.git"

let run_tests () =
  let root = Filename_unix.temp_dir "nixploy-orphan-test-" "" in
  let repository = Filename.concat root "repository" in
  let bin = Filename.concat root "bin" in
  let trace = Filename.concat root "trace" in
  Core_unix.mkdir repository;
  Core_unix.mkdir bin;
  write trace "";
  write (Filename.concat repository "flake.nix") "{ outputs = _: {}; }\n";
  let%bind _ = run_git [ "init"; "-b"; "main"; repository ] in
  let%bind _ =
    run_git ~working_directory:repository
      [ "config"; "remote.origin.url"; repository_identity ]
  in
  let project = Nixploy.Project_name.of_string "shop" |> assert_ok in
  let key target =
    Nixploy.Resource_key.derive ~project
      ~target:(Nixploy.Target_name.of_string target |> assert_ok)
      ~repository_identity
    |> assert_ok
  in
  let current_key = key "production" in
  let orphan_key = key "staging-old" in
  let current = Nixploy.Resource_key.to_string current_key in
  let orphan = Nixploy.Resource_key.to_string orphan_key in
  let orphan_reference =
    Nixploy.Owned_image.repository orphan_key ^ ":20260101T000000Z-aaaaaaaaaaaa"
  in
  let current_reference =
    Nixploy.Owned_image.repository current_key
    ^ ":20260102T000000Z-bbbbbbbbbbbb"
  in
  let orphan_marker =
    Nixploy.Resource_key.derive_current ~project
      ~target:(Nixploy.Target_name.of_string "staging-old" |> assert_ok)
    |> assert_ok |> Nixploy.Resource_key.to_string
  in
  let labels ~target ~key =
    sprintf
      {|{"io.nixploy.managed":"true","io.nixploy.project":"shop","io.nixploy.target":"%s","io.nixploy.resource_key":"%s","io.nixploy.repository":"%s","io.nixploy.repository_identity":"%s"}|}
      target key repository_identity repository_identity
  in
  let secret_id = String.make 25 'a' in
  install_executable bin "nix"
    {|#!/bin/sh
printf '%s\n' '{"__schema":"v0.5","project":"shop","targets":{"production":{"image":"docker","ip":"host.invalid","user":"deployer","port":2222}}}'
|};
  install_executable bin "ssh"
    (sprintf
       {|#!/bin/sh
set -eu
printf 'ssh' >> "$NIXPLOY_TEST_TRACE"
printf '|%%s' "$@" >> "$NIXPLOY_TEST_TRACE"
printf '\n' >> "$NIXPLOY_TEST_TRACE"
last=""
for argument in "$@"; do last="$argument"; done
case "$last" in
  *"'podman' 'ps'"*) printf '[{"Labels":%s}]\n' ;;
  "'find' '.nixploy-mutations'"*) exit 0 ;;
  "'mkdir'"*|"'sync'"*|"'rmdir'"*) exit 0 ;;
  *) echo "unexpected ssh command: $last" >&2; exit 98 ;;
esac
|}
       (labels ~target:"production" ~key:current));
  install_executable bin "podman"
    (sprintf
       {|#!/bin/sh
set -eu
printf 'podman' >> "$NIXPLOY_TEST_TRACE"
printf '|%%s' "$@" >> "$NIXPLOY_TEST_TRACE"
printf '\n' >> "$NIXPLOY_TEST_TRACE"
case "$*" in
  "system connection list --format json")
    printf '[{"Name":"%s","URI":"ssh://deployer@host.invalid:2222/run/user/1000/podman/podman.sock"}]\n'
    ;;
  *" info") ;;
  *" ps --all --filter label=io.nixploy.managed=true --format json")
    printf '[{"Id":"prod-container-id","Names":["%s"],"State":"running","Labels":%s},{"Id":"old-container-id","Names":["%s"],"State":"exited","Status":"Exited (0) 3 weeks ago","Labels":%s}]\n'
    ;;
  *" secret ls --filter name=^nixploy- "*) printf '%s\t%s-DATABASE_URL\n' ;;
  *" secret inspect --format "*)
    printf '{"ID":"%s","Name":"%s-DATABASE_URL","Labels":%s}\n'
    ;;
  *" secret inspect %s")
    printf '[{"ID":"%s","Spec":{"Name":"%s-DATABASE_URL","Labels":%s}}]\n'
    ;;
  *" images --format json")
    printf '[{"Id":"shared-image","Names":["%s","%s"],"Size":1024,"Containers":1}]\n'
    ;;
  *" inspect --type container old-container-id")
    printf '[{"Id":"old-container-id","Config":{"Labels":%s}}]\n'
    ;;
  *" rm -f old-container-id"|*" secret rm %s"|*" rmi %s") ;;
  *) echo "unexpected podman command: $*" >&2; exit 99 ;;
esac
|}
       current current
       (labels ~target:"production" ~key:current)
       orphan
       (labels ~target:"staging-old" ~key:orphan)
       secret_id orphan secret_id orphan
       (labels ~target:"staging-old" ~key:orphan)
       secret_id secret_id orphan
       (labels ~target:"staging-old" ~key:orphan)
       orphan_reference current_reference
       (labels ~target:"staging-old" ~key:orphan)
       secret_id orphan_reference);
  let environment_names = [ "PATH"; "SSH_AUTH_SOCK"; "NIXPLOY_TEST_TRACE" ] in
  let old_environment =
    List.map environment_names ~f:(fun name -> (name, Sys.getenv name))
  in
  Caml_unix.putenv "PATH" (bin ^ ":" ^ Sys.getenv_exn "PATH");
  Core_unix.unsetenv "SSH_AUTH_SOCK";
  Caml_unix.putenv "NIXPLOY_TEST_TRACE" trace;
  let cleanup () =
    List.iter old_environment ~f:(fun (name, value) ->
        match value with
        | Some value -> Caml_unix.putenv name value
        | None -> Core_unix.unsetenv name);
    Nixploy.Process_runner.run_stdout ~timeout:(Time_ns.Span.of_sec 5.)
      ~max_output_bytes:65_536 ~prog:"rm" ~args:[ "-rf"; "--"; root ] ()
    >>| fun _ -> ()
  in
  let target = Nixploy.Target_name.of_string "production" |> assert_ok in
  let mutations () =
    In_channel.read_lines trace
    |> List.filter ~f:(fun line ->
        List.exists
          [ "|rm|"; "|rmi|"; "|secret|rm|"; "'mkdir' '-m'"; "'rmdir'" ]
          ~f:(fun substring -> String.is_substring line ~substring))
  in
  Monitor.protect ~finally:cleanup (fun () ->
      let%bind inventory =
        Nixploy.Application.resources ~working_directory:repository ~target
      in
      let inventory = assert_ok inventory in
      let rendered = Inspection_output.resources inventory in
      List.iter
        [
          "current  " ^ current;
          "orphaned  " ^ orphan ^ "  (shop/staging-old)";
          "Exited (0) 3 weeks ago";
          "nixploy prune -t production --orphan " ^ orphan ^ " --dry-run";
        ]
        ~f:(fun expected ->
          if not (String.is_substring rendered ~substring:expected) then
            failwithf "resources output lacks %S:\n%s" expected rendered ());
      [%test_eq: string list] [] (mutations ());
      let%bind application =
        Nixploy.Application.open_
          ~state_path:(Filename.concat root "state.sqlite")
          ()
      in
      let application = assert_ok application in
      let prune ?dry_run ?(confirmed = true) resource_key =
        Nixploy.Application.prune_orphan application ?dry_run
          ~working_directory:repository ~target ~resource_key ~confirmed
      in
      let%bind refused = prune ~confirmed:false orphan in
      expect_error_containing refused "NIXPLOY_PRUNE_CONFIRMATION_REQUIRED";
      let%bind declared = prune current in
      expect_error_containing declared "which this flake declares";
      let%bind unknown = prune "nixploy-shop-0000000000-missing" in
      expect_error_containing unknown "no nixploy resources with key";
      let%bind malformed = prune "../etc" in
      expect_error_containing malformed "is not a nixploy resource key";
      [%test_eq: string list] [] (mutations ());
      let%bind preview = prune ~dry_run:true ~confirmed:false orphan in
      let preview = assert_ok preview in
      [%test_eq: string list] [ orphan_reference ]
        (Nixploy.Orphan_prune.image_references preview);
      (* The image is shared with the current target, so nothing is freed. *)
      [%test_eq: int64] 0L (Nixploy.Orphan_prune.image_bytes preview);
      [%test_eq: string list] [] (mutations ());
      write trace "";
      let%bind removed = prune orphan in
      let removed = assert_ok removed in
      [%test_eq: string list] [ orphan ]
        (Nixploy.Orphan_prune.containers removed);
      let lines = mutations () in
      let expected =
        [
          "'mkdir' '-m' '700' '--' '.nixploy-mutations/" ^ orphan_marker ^ "'";
          "|rm|-f|old-container-id";
          "|secret|rm|" ^ secret_id;
          "|rmi|" ^ orphan_reference;
          "'rmdir' '--' '.nixploy-mutations/" ^ orphan_marker ^ "'";
        ]
      in
      [%test_eq: int] (List.length expected) (List.length lines);
      List.iter2_exn expected lines ~f:(fun expected line ->
          if not (String.is_substring line ~substring:expected) then
            failwithf "expected %S, got %s" expected line ());
      assert (
        not
          (List.exists
             (In_channel.read_lines trace)
             ~f:(String.is_substring ~substring:("|rmi|" ^ current_reference))));
      printf
        "orphan prune: classification, refusals, read-only preview, guarded \
         exact removal passed\n";
      Deferred.unit)

let () =
  don't_wait_for
    ( Monitor.try_with run_tests >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1 );
  never_returns (Scheduler.go ())
