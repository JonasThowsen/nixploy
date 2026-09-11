open Async
open Core
open Nixploy

let ok = Or_error.ok_exn

let refused = function
  | Ok _ -> failwith "unsafe operation succeeded"
  | Error _ -> ()

let run_tests () =
  let open Deferred.Let_syntax in
  let directory = Filename_unix.temp_dir "nixploy-secret-prune-" "" in
  let events = Filename.concat directory "events" in
  let listing = Filename.concat directory "listing" in
  let inspected = Filename.concat directory "inspected" in
  let container = Filename.concat directory "container" in
  let absent = Filename.concat directory "absent" in
  let removal_failure = Filename.concat directory "removal-failure" in
  let program = Filename.concat directory "podman" in
  Out_channel.write_all program
    ~data:
      (sprintf
         {|#!/bin/sh
printf '%%s\n' "$*" >> %s
shift 2
case "$1 $2" in
  'secret ls') cat %s ;;
  'secret inspect') for arg do last="$arg"; done
    if test -f %s/"$last"; then cat %s/"$last"; else cat %s; fi ;;
  'secret rm') test ! -f %s ;;
  'secret create') test "$(cat)" = 'VALUE_MUST_NOT_APPEAR'; exit $? ;;
  'container exists') test ! -f %s ;;
  'inspect --type') cat %s ;;
  'rm -f') exit 0 ;;
  *) exit 99 ;;
esac
|}
         (Filename.quote events) (Filename.quote listing)
         (Filename.quote directory) (Filename.quote directory)
         (Filename.quote inspected)
         (Filename.quote removal_failure)
         (Filename.quote absent) (Filename.quote container));
  Core_unix.chmod program ~perm:0o755;
  Caml_unix.putenv "PATH" (directory ^ ":" ^ Sys.getenv_exn "PATH");
  let target_name = Target_name.of_string "production" |> ok in
  let config =
    Configuration.of_json
      {|{"__schema":"v0.3","project":"sample","targets":{"production":{"image":"image","ip":"example.invalid"}}}|}
    |> ok
  in
  let project = Configuration.project config in
  let target = Configuration.find_target config target_name |> ok in
  let repository_identity = "repository" in
  let resource_key =
    Resource_key.derive ~project ~target:target_name ~repository_identity |> ok
  in
  let prefix = Resource_key.to_string resource_key ^ "-" in
  let name = prefix ^ "PASSWORD" in
  let id = String.make 25 'a' in
  let ownership =
    [
      ("io.nixploy.managed", `String "true");
      ("io.nixploy.project", `String "sample");
      ("io.nixploy.target", `String "production");
      ("io.nixploy.resource_key", `String (Resource_key.to_string resource_key));
      ("io.nixploy.repository", `String repository_identity);
      ("io.nixploy.repository_identity", `String repository_identity);
    ]
  in
  let metadata ?(name = name) ?(id = id) labels =
    Yojson.Safe.to_string
      (`Assoc [ ("ID", `String id); ("Name", `String name); ("Labels", labels) ])
  in
  let reset ?(names = id ^ "\t" ^ name ^ "\n") data =
    Out_channel.write_all events ~data:"";
    Out_channel.write_all listing ~data:names;
    Out_channel.write_all inspected ~data
  in
  let event_lines () = In_channel.read_lines events in
  let no_mutation () =
    List.iter (event_lines ()) ~f:(fun line ->
        assert (not (String.is_substring line ~substring:"secret rm"));
        assert (not (String.is_substring line ~substring:"secret create"));
        assert (not (String.is_substring line ~substring:"rm -f")))
  in
  let preflight () =
    Podman.preflight_prune_owned_secrets ~connection:"test" ~project ~target
      ~resource_key ~repository_identity
  in
  reset ~names:"" "{}";
  let%bind empty = preflight () in
  assert (Poly.equal (Podman.prepared_secret_prune_counts (ok empty)) (0, 0));
  no_mutation ();
  reset (metadata (`Assoc ownership));
  let%bind prepared = preflight () in
  let prepared = ok prepared in
  assert (Poly.equal (Podman.prepared_secret_prune_counts prepared) (1, 0));
  no_mutation ();
  let%bind removed = Podman.execute_prepared_secret_prune prepared in
  assert (Poly.equal (ok removed) (1, 0));
  assert (
    String.equal
      (List.last_exn (event_lines ()))
      ("--connection test secret rm " ^ id));
  assert (
    String.equal
      (List.hd_exn (event_lines ()))
      ("--connection test secret ls --filter name=^" ^ prefix
     ^ " --format {{.ID}}\t{{.Name}}"));
  reset (metadata `Null);
  let%bind legacy = preflight () in
  let%bind retained = Podman.execute_prepared_secret_prune (ok legacy) in
  assert (Poly.equal (ok retained) (0, 1));
  no_mutation ();
  let%bind () =
    Deferred.List.iter
      [
        metadata ~name:(name ^ "-collision") (`Assoc ownership);
        metadata ~id:(String.make 25 'b') (`Assoc ownership);
        metadata (`Assoc [ ("io.nixploy.managed", `String "true") ]);
        metadata
          (`Assoc
             (("io.nixploy.repository", `String "foreign")
             :: List.Assoc.remove ownership ~equal:String.equal
                  "io.nixploy.repository"));
        metadata (`Assoc (("io.nixploy.managed", `String "false") :: ownership));
        "{malformed VALUE_MUST_NOT_APPEAR";
      ]
      ~how:`Sequential
      ~f:(fun data ->
        reset data;
        let%map result = preflight () in
        refused result;
        (match result with
        | Error e ->
            assert (
              not
                (String.is_substring (Error.to_string_hum e)
                   ~substring:"VALUE_MUST_NOT_APPEAR"))
        | _ -> ());
        no_mutation ())
  in
  let%bind () =
    Deferred.List.iter
      [
        id ^ "\t" ^ name ^ "\n" ^ id ^ "\t" ^ name ^ "\n";
        id ^ "\t" ^ name ^ "\n" ^ String.make 25 'b' ^ "\t" ^ name ^ "\n";
        id ^ "\t" ^ name ^ "\n" ^ id ^ "\t" ^ name ^ "_OTHER\n";
        id ^ "\tforeign\n";
        "short\t" ^ name ^ "\n";
        "\n";
        id ^ "\t" ^ name ^ "\n\n";
      ]
      ~how:`Sequential
      ~f:(fun names ->
        reset ~names (metadata (`Assoc ownership));
        let%map result = preflight () in
        refused result;
        no_mutation ())
  in
  reset (metadata (`Assoc ownership));
  let%bind snapshot = preflight () in
  Out_channel.write_all inspected
    ~data:(metadata ~id:(String.make 25 'b') (`Assoc ownership));
  let%bind changed = Podman.execute_prepared_secret_prune (ok snapshot) in
  refused changed;
  no_mutation ();
  let second_id = String.make 25 'b' in
  let second_name = prefix ^ "SECOND" in
  let second_metadata = Filename.concat directory second_id in
  let two_names =
    id ^ "\t" ^ name ^ "\n" ^ second_id ^ "\t" ^ second_name ^ "\n"
  in
  reset ~names:two_names (metadata (`Assoc ownership));
  Out_channel.write_all second_metadata
    ~data:(metadata ~id:second_id ~name:second_name (`Assoc ownership));
  let%bind two = preflight () in
  Out_channel.write_all second_metadata
    ~data:
      (metadata ~id:second_id ~name:second_name
         (`Assoc [ ("io.nixploy.managed", `String "false") ]));
  let%bind second_changed = Podman.execute_prepared_secret_prune (ok two) in
  refused second_changed;
  no_mutation ();
  let%bind later_foreign = preflight () in
  refused later_foreign;
  no_mutation ();
  Core_unix.unlink second_metadata;
  let placement = Deployment_plan.Single_container in
  let container_name = Deployment_plan.container_name ~resource_key placement in
  let write_container name labels =
    Out_channel.write_all container
      ~data:
        (Yojson.Safe.to_string
           (`List
              [
                `Assoc
                  [
                    ("Id", `String (String.make 64 'c'));
                    ("Name", `String name);
                    ("Config", `Assoc [ ("Labels", `Assoc labels) ]);
                  ];
              ]))
  in
  let prepare () =
    Podman.prepare_candidate ~connection:"test" ~project ~target ~resource_key
      ~repository_identity ~placement
  in
  reset "{}";
  Out_channel.write_all absent ~data:"";
  let%bind missing = prepare () in
  ok missing;
  no_mutation ();
  Core_unix.unlink absent;
  let%bind () =
    Deferred.List.iter
      [ ("foreign", ownership); (container_name, []) ]
      ~how:`Sequential
      ~f:(fun (name, labels) ->
        reset "{}";
        write_container name labels;
        let%map result = prepare () in
        refused result;
        no_mutation ())
  in
  reset "{}";
  write_container ("/" ^ container_name) ownership;
  let%bind matching = prepare () in
  ok matching;
  assert (
    String.equal
      (List.last_exn (event_lines ()))
      ("--connection test rm -f " ^ String.make 64 'c'));
  let secrets =
    Secrets.For_testing.parse_dotenv "PASSWORD=VALUE_MUST_NOT_APPEAR\n" |> ok
  in
  let install () =
    Podman.install_secrets ~connection:"test" ~project ~target ~resource_key
      ~repository_identity ~secrets
  in
  reset ~names:"" "{}";
  let%bind installed = install () in
  ignore (ok installed);
  let created = List.last_exn (event_lines ()) in
  List.iter ownership ~f:(fun (key, value) ->
      match value with
      | `String value ->
          assert (
            String.is_substring created
              ~substring:("--label " ^ key ^ "=" ^ value))
      | _ -> assert false);
  assert (String.is_suffix created ~suffix:(name ^ " -"));
  assert (not (String.is_substring created ~substring:"VALUE_MUST_NOT_APPEAR"));
  reset (metadata `Null);
  let%bind legacy_replace = install () in
  refused legacy_replace;
  no_mutation ();
  reset (metadata (`Assoc [ ("io.nixploy.managed", `String "false") ]));
  let%bind foreign_replace = install () in
  refused foreign_replace;
  no_mutation ();
  reset (metadata (`Assoc ownership));
  Out_channel.write_all removal_failure ~data:"";
  let%bind failed_replace = install () in
  refused failed_replace;
  assert (
    not
      (List.exists (event_lines ()) ~f:(fun line ->
           String.is_substring line ~substring:"secret create")));
  Core_unix.unlink removal_failure;
  reset (metadata (`Assoc ownership));
  let%map owned_replace = install () in
  ignore (ok owned_replace);
  assert (
    List.exists (event_lines ())
      ~f:(String.equal ("--connection test secret rm " ^ id)));
  List.iter (event_lines ()) ~f:(fun line ->
      List.iter
        [
          "--all";
          "--showsecret";
          ".SecretData";
          "volume";
          "image";
          "VALUE_MUST_NOT_APPEAR";
        ] ~f:(fun forbidden ->
          assert (not (String.is_substring line ~substring:forbidden))))

let () =
  don't_wait_for
    ( Monitor.try_with run_tests >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1 );
  never_returns (Scheduler.go ())
