open Core

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let assert_error_containing substring result =
  match result with
  | Ok _ -> failwith "expected an error"
  | Error error ->
      assert (String.is_substring (Error.to_string_hum error) ~substring)

let%test_unit "Nix evaluation and builds use Git-aware local flake snapshots" =
  [%test_eq: string list]
    [
      "eval";
      "--json";
      "--no-update-lock-file";
      "--no-write-lock-file";
      ".#nixploy";
    ]
    (Nixploy.Nix_command.evaluation_args ~flake:"." ~output:"nixploy");
  [%test_eq: string list]
    [
      "build";
      "--no-update-lock-file";
      "--no-write-lock-file";
      ".#docker";
      "--print-out-paths";
      "--no-link";
    ]
    (Nixploy.Nix_command.build_args ~flake:"." ~output:"docker");
  [%test_eq: string list]
    [
      "build";
      "--no-update-lock-file";
      "--no-write-lock-file";
      "path:.?dir=deploy#docker";
      "--print-out-paths";
      "--no-link";
    ]
    (Nixploy.Nix_command.build_args ~flake:"path:.?dir=deploy" ~output:"docker")

let%test_unit "termination state forces only a repeated signal" =
  assert (
    not
      (Nixploy.Process_runner.For_testing.should_force_termination
         ~already_delivered:false));
  assert (
    Nixploy.Process_runner.For_testing.should_force_termination
      ~already_delivered:true)

let%test_unit "resource identity matches the deployed host contract" =
  let cases =
    [
      ( "fixture-90295-r1",
        "production",
        "nixploy-fixture-90295-r1-22ce5117b6-production" );
      ( "Salgs Oversikt",
        "Production EU",
        "nixploy-salgs-oversikt-f44116184a-production-eu" );
    ]
  in
  List.iter cases ~f:(fun (project, target, expected) ->
      let project = Nixploy.Project_name.of_string project |> assert_ok in
      let target = Nixploy.Target_name.of_string target |> assert_ok in
      let actual =
        Nixploy.Resource_key.derive_current ~project ~target |> assert_ok
      in
      [%test_eq: string] expected (Nixploy.Resource_key.to_string actual))

let%test_unit "resource identity bounds both readable parts" =
  let project =
    Nixploy.Project_name.of_string (String.make 80 'A') |> assert_ok
  in
  let target =
    Nixploy.Target_name.of_string (String.make 80 'B') |> assert_ok
  in
  let key =
    Nixploy.Resource_key.derive_current ~project ~target
    |> assert_ok |> Nixploy.Resource_key.to_string
  in
  let expected = "nixploy-" ^ String.make 48 'a' ^ "-" in
  assert (String.is_prefix key ~prefix:expected);
  assert (String.is_suffix key ~suffix:("-" ^ String.make 48 'b'))

let%test_unit "canonical resource identity separates repositories" =
  let project = Nixploy.Project_name.of_string "shared" |> assert_ok in
  let target = Nixploy.Target_name.of_string "production" |> assert_ok in
  let first =
    Nixploy.Resource_key.derive ~project ~target
      ~repository_identity:"git@example.invalid:first.git"
    |> assert_ok
  in
  let second =
    Nixploy.Resource_key.derive ~project ~target
      ~repository_identity:"git@example.invalid:second.git"
    |> assert_ok
  in
  assert (not (Nixploy.Resource_key.equal first second))

let%test_unit "legacy resource identity adopts the deployed repository key" =
  let project = Nixploy.Project_name.of_string "jomat" |> assert_ok in
  let target = Nixploy.Target_name.of_string "production" |> assert_ok in
  let key =
    Nixploy.Resource_key.derive_legacy ~project ~target
      ~repository:"git@github.com:JonasThowsen/jomat.git"
    |> assert_ok |> Nixploy.Resource_key.to_string
  in
  [%test_eq: string] "nixploy-jomat-4df9ec6871-production" key

let%test_unit "managed applications preserve host-owned deployment identity" =
  let applications =
    Nixploy.Managed_application.all_of_json
      {|{
        "sales": {
          "project": "sales-dashboard",
          "target": "production",
          "repository": "/srv/nixploy/sales",
          "subdirectory": "."
        }
      }|}
    |> assert_ok
  in
  let application = List.hd_exn applications in
  [%test_eq: string] "sales" (Nixploy.Managed_application.key application);
  [%test_eq: string] "/srv/nixploy/sales"
    (Nixploy.Managed_application.working_directory application);
  assert (
    Result.is_error
      (Nixploy.Managed_application.all_of_json
         {|{
           "Sales": {
             "project": "sales-dashboard",
             "target": "production",
             "repository": "/srv/nixploy/sales"
           }
         }|}))

let%test_unit "managed application count and operational identities are bounded"
    =
  let entry index =
    ( sprintf "app-%d" index,
      `Assoc
        [
          ("project", `String "sample");
          ("target", `String (sprintf "target-%d" index));
          ("repository", `String (sprintf "/srv/sample-%d" index));
        ] )
  in
  let too_many =
    `Assoc (List.init (Nixploy.Managed_application.maximum_count + 1) ~f:entry)
    |> Yojson.Safe.to_string
  in
  assert (Result.is_error (Nixploy.Managed_application.all_of_json too_many));
  assert (
    Result.is_error
      (Nixploy.Managed_application.all_of_json
         {|{
           "first":{"project":"sample","target":"production","repository":"/srv/sample","repositoryIdentity":"owner/sample"},
           "alias":{"project":"sample","target":"production","repository":"/srv/sample","repositoryIdentity":"owner/sample"}
         }|}));
  let root = Filename_unix.temp_dir "nixploy-managed-alias-" "" in
  let repository = Filename.concat root "repository" in
  let alias = Filename.concat root "alias" in
  Core_unix.mkdir repository;
  Core_unix.symlink ~target:repository ~link_name:alias;
  let duplicate_alias =
    sprintf
      {|{
        "first":{"project":"sample","target":"production","repository":"%s","repositoryIdentity":"owner/sample"},
        "alias":{"project":"sample","target":"production","repository":"%s","repositoryIdentity":"owner/sample"}
      }|}
      repository alias
    |> Nixploy.Managed_application.all_of_json
  in
  assert (Result.is_error duplicate_alias);
  Core_unix.unlink alias;
  Core_unix.rmdir repository;
  Core_unix.rmdir root

let%test_unit "configuration reads the current flake schema" =
  let json =
    {|{
      "__schema":"v0.3",
      "project":"sample",
      "targets":{
        "production":{
          "image":"docker",
          "ip":"example.internal",
          "user":"deploy",
          "port":2222,
          "run":{
            "command":["/app/server"],
            "environment":{"PORT":"{port}"},
            "preStart":[["/app/migrate"]],
            "network":"host",
            "ports":[]
          },
          "web":{
            "domain":"app.example.com",
            "healthPath":"/ready",
            "slots":{"blue":8080,"green":8081}
          },
          "secrets":{}
        }
      }
    }|}
  in
  let configuration = Nixploy.Configuration.of_json json |> assert_ok in
  let name = Nixploy.Target_name.of_string "production" |> assert_ok in
  let target =
    Nixploy.Configuration.find_target configuration name |> assert_ok
  in
  [%test_eq: string] "sample"
    (Nixploy.Configuration.project configuration
    |> Nixploy.Project_name.to_string);
  [%test_eq: string] "docker" (Nixploy.Configuration.Target.image target);
  [%test_eq: string] "example.internal"
    (Nixploy.Configuration.Target.host target);
  [%test_eq: int] 2222 (Nixploy.Configuration.Target.port target)

let%test_unit "configuration parses typed read-only binds only in schema v0.4" =
  let configuration =
    Nixploy.Configuration.of_json
      {|{
        "__schema":"v0.4",
        "project":"sample",
        "targets":{"worker":{"image":"image","ip":"host","run":{
          "command":["/app/server"],
          "preStart":[["/app/migrate"]],
          "readOnlyBinds":[
            {"source":"/srv/reference data","destination":"/app/reference data"},
            {"source":"/srv/config","destination":"/app/config"}
          ]
        }}}
      }|}
    |> assert_ok
  in
  let target_name = Nixploy.Target_name.of_string "worker" |> assert_ok in
  let target =
    Nixploy.Configuration.find_target configuration target_name |> assert_ok
  in
  let binds =
    Nixploy.Configuration.Target.run target
    |> Nixploy.Configuration.Run.read_only_binds
  in
  [%test_eq: string list]
    [ "/srv/reference data"; "/srv/config" ]
    (List.map binds ~f:Nixploy.Configuration.Read_only_bind.source);
  [%test_eq: string list]
    [ "/app/reference data"; "/app/config" ]
    (List.map binds ~f:Nixploy.Configuration.Read_only_bind.destination)

let%test_unit "configuration rejects unsafe or ambiguous read-only binds" =
  let invalid_sources =
    [
      {|""|};
      {|"relative"|};
      {|"/"|};
      {|"/srv//data"|};
      {|"/srv/./data"|};
      {|"/srv/../data"|};
      {|"/srv/data/"|};
      {|"/srv/data,ro=false"|};
      {|"/srv/data\nother"|};
      {|"/srv/data\u0000other"|};
      {|"/srv/data\u007fother"|};
      {|"/srv/data\u0085other"|};
    ]
  in
  List.iter invalid_sources ~f:(fun source ->
      sprintf
        {|{"__schema":"v0.4","project":"sample","targets":{"worker":{"image":"image","ip":"host","run":{"readOnlyBinds":[{"source":%s,"destination":"/app/data"}]}}}}|}
        source
      |> Nixploy.Configuration.of_json
      |> assert_error_containing "absolute normalized Unix path");
  List.iter
    [
      {|{"source":"/same","destination":"/same"}|};
      {|{"source":"/srv/data","destination":"relative"}|};
      {|{"source":"/srv/data","destination":"/app/data","readOnly":false}|};
      {|{"source":"/srv/data","destination":"/app/data","options":["rw"]}|};
    ] ~f:(fun bind ->
      assert (
        Result.is_error
          (sprintf
             {|{"__schema":"v0.4","project":"sample","targets":{"worker":{"image":"image","ip":"host","run":{"readOnlyBinds":[%s]}}}}|}
             bind
          |> Nixploy.Configuration.of_json)));
  Nixploy.Configuration.of_json
    {|{"__schema":"v0.4","project":"sample","targets":{"worker":{"image":"image","ip":"host","run":{"readOnlyBinds":[{"source":"/srv/first","destination":"/app/data"},{"source":"/srv/second","destination":"/app/data"}]}}}}|}
  |> assert_error_containing "duplicate destination"

let%test_unit
    "configuration rejects bind fields in old schemas and unknown members" =
  List.iter [ "v0.1"; "v0.5" ] ~f:(fun schema ->
      sprintf {|{"__schema":"%s","project":"sample","targets":{}}|} schema
      |> Nixploy.Configuration.of_json
      |> assert_error_containing "unsupported nixploy configuration schema");
  List.iter [ "v0.2"; "v0.3" ] ~f:(fun schema ->
      sprintf
        {|{"__schema":"%s","project":"sample","targets":{"worker":{"image":"image","ip":"host","run":{"readOnlyBinds":[]}}}}|}
        schema
      |> Nixploy.Configuration.of_json
      |> assert_error_containing "requires nixploy configuration schema v0.4");
  List.iter
    [
      {|{"__schema":"v0.4","project":"sample","targets":{},"unknown":true}|};
      {|{"__schema":"v0.4","project":"sample","targets":{"worker":{"image":"image","ip":"host","unknown":true}}}|};
      {|{"__schema":"v0.4","project":"sample","targets":{"worker":{"image":"image","ip":"host","run":{"unknown":true}}}}|};
      {|{"__schema":"v0.4","project":"sample","targets":{"worker":{"image":"image","ip":"host","web":{"domain":"example.invalid","unknown":true}}}}|};
      {|{"__schema":"v0.4","project":"sample","targets":{"worker":{"image":"image","ip":"host","run":{"readOnlyBinds":[{"source":"/srv/data","destination":"/app/data","unknown":true}]}}}}|};
      {|{"__schema":"v0.4","project":"sample","targets":{"worker":{"image":"image","ip":"host","tasks":{}}}}|};
      {|{"__schema":"v0.4","project":"first","project":"second","targets":{}}|};
    ] ~f:(fun json ->
      assert (Result.is_error (Nixploy.Configuration.of_json json)));
  ignore
    (Nixploy.Configuration.of_json
       {|{"__schema":"v0.3","project":"sample","targets":{"worker":{"image":"image","ip":"host","tasks":{}}}}|}
     |> assert_ok
      : Nixploy.Configuration.t);
  Nixploy.Configuration.of_json
    {|{"__schema":"v0.3","project":"sample","targets":{"worker":{"image":"image","ip":"host","tasks":{"vacuum":{"command":["/app/vacuum"]}}}}}|}
  |> assert_error_containing "named operational tasks"

let%test_unit
    "pre-start and application render identical mandatory read-only mounts" =
  let configuration =
    Nixploy.Configuration.of_json
      {|{
        "__schema":"v0.4",
        "project":"sample",
        "targets":{"worker":{"image":"image","ip":"host","run":{
          "command":["/app/server"],
          "environment":{"PORT":"{port}"},
          "preStart":[["/app/migrate"]],
          "network":"private",
          "ports":["127.0.0.1:9000:9000"],
          "readOnlyBinds":[{"source":"/srv/data;$(touch nope)","destination":"/app/input data"}]
        }}}
      }|}
    |> assert_ok
  in
  let target_name = Nixploy.Target_name.of_string "worker" |> assert_ok in
  let run =
    Nixploy.Configuration.find_target configuration target_name
    |> assert_ok |> Nixploy.Configuration.Target.run
  in
  let pre_start =
    Nixploy.Podman.For_testing.pre_start_argvs ~connection:"connection" ~run
      ~port:(Some 8080)
      ~secret_args:[ "--secret"; "typed-secret" ]
      ~image_reference:"image"
    |> List.hd_exn
  in
  let runtime =
    Nixploy.Podman.For_testing.runtime_argv ~connection:"connection"
      ~name:"owned" ~run ~port:(Some 8080)
      ~secret_args:[ "--secret"; "typed-secret" ]
      ~labels:[] ~image_reference:"image"
  in
  let mount_tokens argv =
    let rec collect mounts = function
      | "--mount" :: value :: rest ->
          collect (("--mount", value) :: mounts) rest
      | _ :: rest -> collect mounts rest
      | [] -> List.rev mounts
    in
    collect [] argv
  in
  let expected =
    [
      ( "--mount",
        "type=bind,source=/srv/data;$(touch nope),destination=/app/input \
         data,ro=true" );
    ]
  in
  [%test_eq: (string * string) list] expected (mount_tokens pre_start);
  [%test_eq: (string * string) list] expected (mount_tokens runtime)

let%test_unit "configuration preserves empty environment and argv values" =
  let configuration =
    Nixploy.Configuration.of_json
      {|{
        "__schema":"v0.3",
        "project":"sample",
        "targets":{"worker":{"image":"image","ip":"host","run":{
          "command":["/app/worker",""],
          "environment":{"EMPTY":""},
          "preStart":[["/app/prepare",""]]
        }}}
      }|}
    |> assert_ok
  in
  let target_name = Nixploy.Target_name.of_string "worker" |> assert_ok in
  let target =
    Nixploy.Configuration.find_target configuration target_name |> assert_ok
  in
  let run = Nixploy.Configuration.Target.run target in
  [%test_eq: string list option]
    (Some [ "/app/worker"; "" ])
    (Nixploy.Configuration.Run.command run);
  [%test_eq: (string * string) list]
    [ ("EMPTY", "") ]
    (Nixploy.Configuration.Run.environment run);
  [%test_eq: string list list]
    [ [ "/app/prepare"; "" ] ]
    (Nixploy.Configuration.Run.pre_start run);
  let argv =
    Nixploy.Podman.For_testing.runtime_argv ~connection:"connection"
      ~name:"owned" ~run ~port:None ~secret_args:[] ~labels:[]
      ~image_reference:"image"
  in
  [%test_eq: string list]
    [
      "--connection";
      "connection";
      "run";
      "-d";
      "--name";
      "owned";
      "-e";
      "EMPTY=";
      "image";
      "/app/worker";
      "";
    ]
    argv

let%test_unit "deployment configuration renders the selected slot port" =
  let configuration =
    Nixploy.Configuration.of_json
      {|{
        "__schema":"v0.3",
        "project":"sample",
        "targets":{
          "production":{
            "image":"docker",
            "ip":"host",
            "run":{"environment":{"PORT":"{port}","URL":"http://0.0.0.0:{port}"}},
            "web":{"domain":"app.example.com","slots":{"blue":8080,"green":8081}},
            "secrets":{}
          }
        }
      }|}
    |> assert_ok
  in
  let target_name = Nixploy.Target_name.of_string "production" |> assert_ok in
  let target =
    Nixploy.Configuration.find_target configuration target_name |> assert_ok
  in
  let web = Nixploy.Configuration.Target.require_web target |> assert_ok in
  [%test_eq: int] 8081 (Nixploy.Configuration.Web.green_port web);
  [%test_eq: (string * string) list]
    [ ("PORT", "8081"); ("URL", "http://0.0.0.0:8081") ]
    (Nixploy.Configuration.Run.rendered_environment
       (Nixploy.Configuration.Target.run target)
       ~port:(Some 8081))

let%test_unit "secret-bearing web targets remain deployable" =
  let configuration =
    Nixploy.Configuration.of_json
      {|{
        "__schema":"v0.3",
        "project":"sample",
        "targets":{
          "production":{
            "image":"docker",
            "ip":"host",
            "web":{"domain":"app.example.com"},
            "secrets":{"app":"/nix/store/encrypted"}
          }
        }
      }|}
    |> assert_ok
  in
  let target_name = Nixploy.Target_name.of_string "production" |> assert_ok in
  let target =
    Nixploy.Configuration.find_target configuration target_name |> assert_ok
  in
  ignore (Nixploy.Configuration.Target.require_web target |> assert_ok)

let%test_unit "dotenv secrets are strict and redact retained output" =
  let secrets =
    Nixploy.Secrets.For_testing.parse_dotenv
      "DATABASE_URL='postgres://private'\nTOKEN=secret\\nvalue\n"
    |> assert_ok
  in
  [%test_eq: string list]
    [ "DATABASE_URL"; "TOKEN" ]
    (List.map secrets ~f:Nixploy.Secrets.name);
  [%test_eq: string] "failed [REDACTED] and [REDACTED]"
    (Nixploy.Secrets.redact secrets
       "failed postgres://private and secret\\nvalue");
  assert (
    Result.is_error
      (Nixploy.Secrets.For_testing.parse_dotenv "GOOD=one\nnot valid\n"));
  assert (
    Result.is_error
      (Nixploy.Secrets.For_testing.parse_dotenv "DUP=one\nDUP=two\n"))

let%test_unit "private SOPS identity files require secure filesystem metadata" =
  let root = Filename_unix.temp_dir "nixploy-private-identity-" "" in
  let identity = Filename.concat root "identity" in
  Out_channel.write_all identity ~data:"private identity test data\n";
  Core_unix.chmod identity ~perm:0o600;
  assert (
    Result.is_ok
      (Nixploy.Secrets.For_testing.validate_private_identity_file identity));
  Core_unix.chmod identity ~perm:0o640;
  assert (
    Result.is_error
      (Nixploy.Secrets.For_testing.validate_private_identity_file identity));
  Core_unix.chmod identity ~perm:0o600;
  let final_link = Filename.concat root "identity-link" in
  Core_unix.symlink ~target:identity ~link_name:final_link;
  assert (
    Result.is_error
      (Nixploy.Secrets.For_testing.validate_private_identity_file final_link));
  let linked_directory = Filename.concat root "linked-directory" in
  Core_unix.symlink ~target:root ~link_name:linked_directory;
  assert (
    Result.is_error
      (Nixploy.Secrets.For_testing.validate_private_identity_file
         (Filename.concat linked_directory "identity")));
  assert (
    Result.is_error
      (Nixploy.Secrets.For_testing.validate_private_identity_file root));
  assert (
    Result.is_error
      (Nixploy.Secrets.For_testing.validate_private_identity_file
         "relative-identity"));
  Core_unix.unlink linked_directory;
  Core_unix.unlink final_link;
  Core_unix.unlink identity;
  Core_unix.rmdir root

let%test_unit "workload accepts current deployment labels" =
  let json =
    {|[{
      "Names":["nixploy-sample-123-production-blue"],
      "Image":"sample:latest",
      "State":"running",
      "Status":"Up 3 hours",
      "Labels":{"io.nixploy.revision":"0123456789abcdef0123456789abcdef01234567"}
    }]|}
  in
  let workloads = Nixploy.Workload.all_of_json json |> assert_ok in
  let workload = List.hd_exn workloads in
  [%test_eq: string] "nixploy-sample-123-production-blue"
    (Nixploy.Workload.name workload);
  [%test_eq: string option] (Some "0123456789abcdef0123456789abcdef01234567")
    (Nixploy.Workload.revision workload)

let%test_unit "status workload readback rejects another repository" =
  let project = Nixploy.Project_name.of_string "shared" |> assert_ok in
  let target = Nixploy.Target_name.of_string "production" |> assert_ok in
  let repository_identity = "git@example.invalid:requested.git" in
  let resource_key =
    Nixploy.Resource_key.derive ~project ~target ~repository_identity
    |> assert_ok
  in
  let name = Nixploy.Resource_key.to_string resource_key in
  let json repository =
    sprintf
      {|[{"Names":["%s"],"Labels":{"io.nixploy.managed":"true","io.nixploy.project":"shared","io.nixploy.target":"production","io.nixploy.resource_key":"%s","io.nixploy.repository_identity":"%s"}}]|}
      name name repository
  in
  let requested =
    Nixploy.Workload.all_owned_of_json ~ownership:`Modern ~project ~target
      ~resource_key ~repository_identity ~expected_names:[ name ]
      (json repository_identity)
    |> assert_ok
  in
  [%test_eq: int] 1 (List.length requested);
  assert (
    Result.is_error
      (Nixploy.Workload.all_owned_of_json ~ownership:`Modern ~project ~target
         ~resource_key ~repository_identity ~expected_names:[ name ]
         (json "git@example.invalid:other.git")))

let%test_unit "connection resolution uses the target SSH endpoint, not its name"
    =
  let configuration =
    Nixploy.Configuration.of_json
      {|{
        "__schema":"v0.3",
        "project":"sample",
        "targets":{
          "production":{
            "image":"docker",
            "ip":"server.internal",
            "user":"deploy",
            "port":2222
          }
        }
      }|}
    |> assert_ok
  in
  let target_name = Nixploy.Target_name.of_string "production" |> assert_ok in
  let target =
    Nixploy.Configuration.find_target configuration target_name |> assert_ok
  in
  let connections =
    Nixploy.Podman_connection.all_of_json
      {|[
        {"Name":"stale-resource-name","URI":"ssh://deploy@server.internal:2222/run/user/1000/podman/podman.sock","Identity":"/run/credentials/retired/key"},
        {"Name":"wrong-user","URI":"ssh://root@server.internal:2222/run/podman/podman.sock"}
      ]|}
    |> assert_ok
  in
  let connection =
    Nixploy.Podman_connection.find_for_target connections target |> assert_ok
  in
  [%test_eq: string] "stale-resource-name"
    (Nixploy.Podman_connection.name connection);
  [%test_eq: string option] (Some "/run/credentials/retired/key")
    (Nixploy.Podman_connection.identity connection);
  assert (
    not
      (Nixploy.Podman_connection.matches_identity connection
         (Some "/run/credentials/current/key")))

let%test_unit
    "relative secret paths cannot traverse or follow symlinks outside source" =
  let root = Filename_unix.temp_dir "nixploy-secrets-root-" "" in
  let inside = Filename.concat root "inside.env" in
  Out_channel.write_all inside ~data:"VALUE=inside\n";
  let outside = Filename_unix.temp_file "nixploy-secrets-outside-" ".env" in
  Out_channel.write_all outside ~data:"VALUE=outside\n";
  let escape = Filename.concat root "escape.env" in
  Caml_unix.symlink outside escape;
  [%test_eq: string]
    (Filename_unix.realpath inside)
    (Nixploy.Secrets.For_testing.resolve_reference ~source_root:root
       "inside.env"
    |> assert_ok);
  assert (
    Result.is_error
      (Nixploy.Secrets.For_testing.resolve_reference ~source_root:root
         "../outside.env"));
  assert (
    Result.is_error
      (Nixploy.Secrets.For_testing.resolve_reference ~source_root:root
         "escape.env"));
  [%test_eq: string] outside
    (Nixploy.Secrets.For_testing.resolve_reference ~source_root:root outside
    |> assert_ok);
  Core_unix.unlink escape;
  Core_unix.unlink inside;
  Core_unix.unlink outside;
  Core_unix.rmdir root

let%test_unit "remote workload discovery deduplicates resource identities" =
  let keys =
    Nixploy.Podman.For_testing.resource_keys_of_containers
      {|[
        {"Labels":{"io.nixploy.resource_key":"nixploy-jomat-legacy-production"}},
        {"Labels":{"io.nixploy.resource_key":"nixploy-jomat-legacy-production"}},
        {"Labels":{"io.nixploy.managed":"true"}}
      ]|}
    |> assert_ok
  in
  [%test_eq: string list] [ "nixploy-jomat-legacy-production" ] keys

let%test_unit "deployment plan always selects the inactive slot" =
  let configuration =
    Nixploy.Configuration.of_json
      {|{
        "__schema":"v0.3",
        "project":"sample",
        "targets":{
          "production":{
            "image":"docker",
            "ip":"host",
            "web":{"domain":"app.example.com","slots":{"blue":8080,"green":8081}}
          }
        }
      }|}
    |> assert_ok
  in
  let target_name = Nixploy.Target_name.of_string "production" |> assert_ok in
  let target =
    Nixploy.Configuration.find_target configuration target_name |> assert_ok
  in
  let web = Nixploy.Configuration.Target.require_web target |> assert_ok in
  let target_kind = Nixploy.Configuration.Target.Web web in
  let first =
    Nixploy.Deployment_plan.create ~target_kind ~active_port:None |> assert_ok
  in
  let after_blue =
    Nixploy.Deployment_plan.create ~target_kind ~active_port:(Some 8080)
    |> assert_ok
  in
  [%test_eq: Nixploy.Deployment_plan.placement]
    (Nixploy.Deployment_plan.Web_slot { slot = Blue; port = 8080 })
    (Nixploy.Deployment_plan.placement first);
  [%test_eq: Nixploy.Deployment_plan.slot option] None
    (Nixploy.Deployment_plan.active_slot first);
  [%test_eq: Nixploy.Deployment_plan.placement]
    (Nixploy.Deployment_plan.Web_slot { slot = Green; port = 8081 })
    (Nixploy.Deployment_plan.placement after_blue);
  [%test_eq: Nixploy.Deployment_plan.slot option]
    (Some Nixploy.Deployment_plan.Blue)
    (Nixploy.Deployment_plan.active_slot after_blue)

let%test_unit "non-web targets select exact single-container placement" =
  let configuration =
    Nixploy.Configuration.of_json
      {|{
        "__schema":"v0.3",
        "project":"sample",
        "targets":{"worker":{"image":"worker-image","ip":"host"}}
      }|}
    |> assert_ok
  in
  let target_name = Nixploy.Target_name.of_string "worker" |> assert_ok in
  let target =
    Nixploy.Configuration.find_target configuration target_name |> assert_ok
  in
  let target_kind = Nixploy.Configuration.Target.kind target in
  (match target_kind with
  | Nixploy.Configuration.Target.Non_web -> ()
  | Web _ -> failwith "non-web target was classified as web");
  let plan =
    Nixploy.Deployment_plan.create ~target_kind ~active_port:None |> assert_ok
  in
  [%test_eq: Nixploy.Deployment_plan.placement]
    Nixploy.Deployment_plan.Single_container
    (Nixploy.Deployment_plan.placement plan);
  let project = Nixploy.Configuration.project configuration in
  let resource_key =
    Nixploy.Resource_key.derive ~project ~target:target_name
      ~repository_identity:"git@example.invalid:sample.git"
    |> assert_ok
  in
  [%test_eq: string]
    (Nixploy.Resource_key.to_string resource_key)
    (Nixploy.Deployment_plan.container_name ~resource_key
       (Nixploy.Deployment_plan.placement plan))

let%test_unit "modern ownership labels override contradictory legacy labels" =
  let configuration =
    Nixploy.Configuration.of_json
      {|{"__schema":"v0.3","project":"sample","targets":{"worker":{"image":"worker-image","ip":"host"}}}|}
    |> assert_ok
  in
  let project = Nixploy.Configuration.project configuration in
  let target_name = Nixploy.Target_name.of_string "worker" |> assert_ok in
  let target =
    Nixploy.Configuration.find_target configuration target_name |> assert_ok
  in
  let resource_key =
    Nixploy.Resource_key.derive ~project ~target:target_name
      ~repository_identity:"git@example.invalid:sample.git"
    |> assert_ok
  in
  let owned labels =
    Nixploy.Podman.For_testing.owned_candidate_collision
      (sprintf {|[{"Config":{"Labels":%s}}]|} labels)
      ~project ~target ~resource_key
    |> assert_ok
  in
  assert (
    not
      (owned
         {|{"io.nixploy.managed":"true","io.nixploy.project":"sample","io.nixploy.target":"worker","io.nixploy.resource_key":"conflicting-resource","nixploy.project":"sample","nixploy.target":"worker"}|}));
  assert (
    not
      (owned
         (sprintf
            {|{"io.nixploy.managed":"false","io.nixploy.project":"sample","io.nixploy.target":"worker","io.nixploy.resource_key":"%s","nixploy.project":"sample","nixploy.target":"worker"}|}
            (Nixploy.Resource_key.to_string resource_key))));
  assert (
    not
      (owned
         {|{"io.nixploy.project":"other","nixploy.project":"sample","nixploy.target":"worker"}|}));
  assert (owned {|{"nixploy.project":"sample","nixploy.target":"worker"}|})

let%test_unit "legacy ownership labels with resource_key are recognized" =
  let configuration =
    Nixploy.Configuration.of_json
      {|{"__schema":"v0.3","project":"sample","targets":{"worker":{"image":"worker-image","ip":"host"}}}|}
    |> assert_ok
  in
  let project = Nixploy.Configuration.project configuration in
  let target_name = Nixploy.Target_name.of_string "worker" |> assert_ok in
  let target =
    Nixploy.Configuration.find_target configuration target_name |> assert_ok
  in
  let resource_key =
    Nixploy.Resource_key.derive ~project ~target:target_name
      ~repository_identity:"git@example.invalid:sample.git"
    |> assert_ok
  in
  let owned labels =
    Nixploy.Podman.For_testing.owned_candidate_collision
      (sprintf {|[{"Config":{"Labels":%s}}]|} labels)
      ~project ~target ~resource_key
    |> assert_ok
  in
  assert (
    owned
      (sprintf
         {|{"nixploy.project":"sample","nixploy.target":"worker","nixploy.resource_key":"%s"}|}
         (Nixploy.Resource_key.to_string resource_key)));
  assert (
    not
      (owned {|{"nixploy.project":"other","nixploy.target":"worker"}|}))

let%test_unit "non-web command construction preserves ordering and options" =
  let configuration =
    Nixploy.Configuration.of_json
      {|{
        "__schema":"v0.3",
        "project":"sample",
        "targets":{
          "worker":{
            "image":"worker-image",
            "ip":"host",
            "run":{
              "command":["/app/worker","--once"],
              "environment":{"PORT":"{port}","MODE":"worker"},
              "preStart":[["/app/migrate","one"],["/app/seed"]],
              "network":"private",
              "ports":["127.0.0.1:9000:9000"]
            }
          }
        }
      }|}
    |> assert_ok
  in
  let target_name = Nixploy.Target_name.of_string "worker" |> assert_ok in
  let target =
    Nixploy.Configuration.find_target configuration target_name |> assert_ok
  in
  let run = Nixploy.Configuration.Target.run target in
  [%test_eq: (string * string) list]
    [ ("PORT", "{port}"); ("MODE", "worker") ]
    (Nixploy.Configuration.Run.rendered_environment run ~port:None);
  let secret_args = [ "--secret"; "source=owned-db,type=env,target=DB" ] in
  let pre_start =
    Nixploy.Podman.For_testing.pre_start_argvs ~connection:"connection" ~run
      ~port:None ~secret_args ~image_reference:"loaded@sha256:immutable"
  in
  [%test_eq: string list list]
    [
      [
        "--connection";
        "connection";
        "run";
        "--rm";
        "--secret";
        "source=owned-db,type=env,target=DB";
        "--network";
        "private";
        "-e";
        "PORT={port}";
        "-e";
        "MODE=worker";
        "loaded@sha256:immutable";
        "/app/migrate";
        "one";
      ];
      [
        "--connection";
        "connection";
        "run";
        "--rm";
        "--secret";
        "source=owned-db,type=env,target=DB";
        "--network";
        "private";
        "-e";
        "PORT={port}";
        "-e";
        "MODE=worker";
        "loaded@sha256:immutable";
        "/app/seed";
      ];
    ]
    pre_start;
  let runtime =
    Nixploy.Podman.For_testing.runtime_argv ~connection:"connection"
      ~name:"nixploy-sample-owned-worker" ~run ~port:None ~secret_args
      ~labels:
        [
          ("io.nixploy.managed", "true");
          ("io.nixploy.operation_id", "operation-1");
        ]
      ~image_reference:"loaded@sha256:immutable"
  in
  [%test_eq: string list]
    [
      "--connection";
      "connection";
      "run";
      "-d";
      "--name";
      "nixploy-sample-owned-worker";
      "--secret";
      "source=owned-db,type=env,target=DB";
      "--network";
      "private";
      "-e";
      "PORT={port}";
      "-e";
      "MODE=worker";
      "-p";
      "127.0.0.1:9000:9000";
      "--label";
      "io.nixploy.managed=true";
      "--label";
      "io.nixploy.operation_id=operation-1";
      "loaded@sha256:immutable";
      "/app/worker";
      "--once";
    ]
    runtime

let%test_unit "Caddy upstream parsing is exact" =
  [%test_eq: int] 8081
    (Nixploy.Caddy.For_testing.upstream_port_of_json
       {|[{"dial":"127.0.0.1:8081"}]|}
    |> assert_ok);
  assert (
    Result.is_error
      (Nixploy.Caddy.For_testing.upstream_port_of_json
         {|[{"dial":"10.0.0.1:8081"}]|}))

let%test_unit "Podman load parser accepts current output variants" =
  [%test_eq: string] "localhost/app:latest"
    (Nixploy.Podman.For_testing.loaded_reference
       "Loaded image: localhost/app:latest\n"
    |> assert_ok);
  [%test_eq: string] "localhost/app:latest"
    (Nixploy.Podman.For_testing.loaded_reference
       "Loaded image(s): localhost/app:latest\n"
    |> assert_ok)

let%test_unit "Podman runtime stats parse bounded numeric values" =
  let stats =
    Nixploy.Podman.For_testing.parse_stats
      {|[{"CPU":"2.5%","MemUsage":"128.0MiB / 1GiB"}]|}
    |> assert_ok
  in
  [%test_eq: float option] (Some 2.5) stats.cpu_percent;
  [%test_eq: int64] 134_217_728L stats.memory_used_bytes

let%test_unit "runtime logs preserve timestamps and bound retained lines" =
  let input =
    List.init 501 ~f:(fun index ->
        sprintf "2026-08-09T12:00:00Z line-%03d" index)
    |> String.concat ~sep:"\n"
  in
  let snapshot = Nixploy.Podman.For_testing.bound_logs input in
  assert snapshot.truncated;
  [%test_eq: int] 500 (List.length snapshot.lines);
  let first = List.hd_exn snapshot.lines in
  [%test_eq: string option] (Some "2026-08-09T12:00:00Z") first.timestamp;
  [%test_eq: string] "line-001" first.text;
  let redacted =
    Nixploy.Podman.For_testing.bound_logs
      "2026-08-09T12:00:00Z token=super-secret password: hunter2"
  in
  [%test_eq: string] "token=[REDACTED] password: [REDACTED]"
    (List.hd_exn redacted.lines).text;
  let structured =
    Nixploy.Podman.For_testing.bound_logs
      {|{"token":"secret value","authorization":"Bearer abc.def"}|}
  in
  [%test_eq: string] {|{"token":"[REDACTED]","authorization":"[REDACTED]"}|}
    (List.hd_exn structured.lines).text

let%test_unit "remote host metrics parse capacities and CPU delta" =
  let metrics =
    Nixploy.Host_metrics.For_testing.parse
      {|NIXPLOY_CPU1
cpu 10 10 10 70 0 0 0 0
NIXPLOY_CPU2
cpu 30 20 30 120 0 0 0 0
NIXPLOY_MEMORY
MemTotal:       1000 kB
MemAvailable:    250 kB
NIXPLOY_LOAD
0.10 0.20 0.30 1/100 123
NIXPLOY_UPTIME
3600.50 1200.00
NIXPLOY_FILESYSTEM
   1000000 400000 600000
|}
    |> assert_ok
  in
  [%test_eq: float] 50. (Nixploy.Host_metrics.cpu_percent metrics);
  [%test_eq: int64] 1_024_000L (Nixploy.Host_metrics.memory_total_bytes metrics);
  [%test_eq: int64] 768_000L (Nixploy.Host_metrics.memory_used_bytes metrics);
  [%test_eq: int64] 400_000L
    (Nixploy.Host_metrics.filesystem_used_bytes metrics)
