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
    (Nixploy.Nix_command.evaluation_args ~offline:false ~flake:"."
       ~output:"nixploy");
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

let%test_unit
    "deployment requests prepare once and bind exactly one history operation" =
  let commit =
    Nixploy.Source.For_testing.commit ~revision:(String.make 40 'a')
      ~subject:"request" ~timestamp_ms:1L
    |> assert_ok
  in
  let request =
    Nixploy.Deployment_request.create ~working_directory:"."
      ~source:(Nixploy.Source.immutable commit)
      ~target:(Nixploy.Target_name.of_string "test" |> assert_ok)
      ()
    |> assert_ok
  in
  assert (
    Result.is_error
      (Nixploy.Deployment_request.bind_operation request ~operation_id:"first"));
  assert_ok (Nixploy.Deployment_request.claim request);
  assert (Result.is_error (Nixploy.Deployment_request.claim request));
  assert_ok
    (Nixploy.Deployment_request.bind_operation request ~operation_id:"first");
  assert (
    Result.is_error
      (Nixploy.Deployment_request.bind_operation request ~operation_id:"second"));
  assert_ok
    (Nixploy.Deployment_request.validate_operation request ~operation_id:"first");
  assert (
    Result.is_error
      (Nixploy.Deployment_request.validate_operation request
         ~operation_id:"second"))

let%test_unit "target names are bounded to 255 bytes" =
  let maximum_length = String.make 255 'a' in
  let too_long = String.make 256 'a' in
  assert (Result.is_ok (Nixploy.Target_name.of_string maximum_length));
  assert_error_containing "at most 255 bytes"
    (Nixploy.Target_name.of_string too_long)

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

let%test_unit "destination identity rejects legacy numeric aliases" =
  let host value = Nixploy.Endpoint_identity.host value |> assert_ok in
  [%test_eq: string] "192.168.1.10" (host "192.168.1.10");
  [%test_eq: string] "2001:db8::1" (host "2001:0DB8:0:0:0:0:0:1");
  [%test_eq: string] "2001:db8::1" (host "[2001:db8::1]");
  [%test_eq: string] "host.example.invalid" (host "HOST.EXAMPLE.INVALID.");
  [%test_eq: string] "app.example.invalid"
    (Nixploy.Endpoint_identity.domain "APP.EXAMPLE.INVALID." |> assert_ok);
  [%test_eq: string] "sample:production"
    (Nixploy.Endpoint_identity.coordination_scope "Sample:PRODUCTION"
    |> assert_ok);
  assert (not (String.equal (host "2001:db8::1") (host "2001:db8::2")));
  [%test_eq: string] "0x7f.example.invalid" (host "0x7f.example.invalid");
  [%test_eq: string] "0x7f.example.invalid"
    (Nixploy.Endpoint_identity.domain "0x7f.example.invalid" |> assert_ok);
  List.iter
    [
      "[2001:db8::1";
      "2001:db8::1]";
      "fe80::1%eth0";
      "999.1.1.1";
      "192.168.001.010";
      "0177.0.0.1";
      "0x7f000001";
      "0X7F000001";
      "0x7f.1";
      "127.1";
      "127.0.1";
    ] ~f:(fun value ->
      assert (Result.is_error (Nixploy.Endpoint_identity.host value)));
  [%test_eq: string] "127.0.0.1"
    (Nixploy.Endpoint_identity.domain "127.0.0.1" |> assert_ok);
  List.iter [ "0x7f000001"; "0x7f.1" ] ~f:(fun value ->
      assert (Result.is_error (Nixploy.Endpoint_identity.domain value)));
  assert (
    Result.is_error (Nixploy.Endpoint_identity.domain "app.example.invalid.."));
  assert (
    Result.is_error
      (Nixploy.Endpoint_identity.coordination_scope " shared-scope"))

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
  List.iter [ "v0.1"; "v0.6" ] ~f:(fun schema ->
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
      ~port:(Some 8080) ~revision:None
      ~secret_args:[ "--secret"; "typed-secret" ]
      ~image_reference:"image"
    |> List.hd_exn
  in
  let runtime =
    Nixploy.Podman.For_testing.runtime_argv ~connection:"connection"
      ~name:"owned" ~run ~port:(Some 8080) ~revision:None
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
      ~name:"owned" ~run ~port:None ~revision:None ~secret_args:[] ~labels:[]
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
      "--restart";
      "always";
      "-e";
      "EMPTY=";
      "image";
      "/app/worker";
      "";
    ]
    argv

let%test_unit
    "deployment configuration renders source revision and selected slot port" =
  let configuration =
    Nixploy.Configuration.of_json
      {|{
        "__schema":"v0.3",
        "project":"sample",
        "targets":{
          "production":{
            "image":"docker",
            "ip":"host",
            "run":{"environment":{"PORT":"{port}","RELEASE":"{revision}","IDENTITY":"{revision}:{port}","URL":"http://0.0.0.0:{port}"}},
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
  let revision = "0123456789abcdef0123456789abcdef01234567" in
  [%test_eq: (string * string) list]
    [
      ("PORT", "8081");
      ("RELEASE", revision);
      ("IDENTITY", revision ^ ":8081");
      ("URL", "http://0.0.0.0:8081");
    ]
    (Nixploy.Configuration.Run.rendered_environment
       (Nixploy.Configuration.Target.run target)
       ~port:(Some 8081) ~revision:(Some revision));
  [%test_eq: (string * string) list]
    [
      ("PORT", "{port}");
      ("RELEASE", "{revision}");
      ("IDENTITY", "{revision}:{port}");
      ("URL", "http://0.0.0.0:{port}");
    ]
    (Nixploy.Configuration.Run.rendered_environment
       (Nixploy.Configuration.Target.run target)
       ~port:None ~revision:None)

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

let%test_unit "status workload readback requires complete modern ownership" =
  let project = Nixploy.Project_name.of_string "shared" |> assert_ok in
  let target = Nixploy.Target_name.of_string "production" |> assert_ok in
  let repository_identity = "git@example.invalid:requested.git" in
  let resource_key =
    Nixploy.Resource_key.derive ~project ~target ~repository_identity
    |> assert_ok
  in
  let name = Nixploy.Resource_key.to_string resource_key in
  let parse labels =
    Nixploy.Workload.all_owned_of_json ~project ~target ~resource_key
      ~repository_identity ~expected_names:[ name ]
      (sprintf {|[{"Names":["%s"],"Labels":%s}]|} name labels)
  in
  let valid =
    sprintf
      {|{"io.nixploy.managed":"true","io.nixploy.project":"shared","io.nixploy.target":"production","io.nixploy.resource_key":"%s","io.nixploy.repository_identity":"%s"}|}
      name repository_identity
  in
  [%test_eq: int] 1 (parse valid |> assert_ok |> List.length);
  List.iter
    [
      ( "legacy-only",
        sprintf
          {|{"nixploy.project":"shared","nixploy.target":"production","nixploy.resource_key":"%s","nixploy.repository":"%s"}|}
          name repository_identity );
      ( "mixed",
        sprintf
          {|{"io.nixploy.managed":"true","io.nixploy.project":"shared","nixploy.target":"production","nixploy.resource_key":"%s","io.nixploy.repository_identity":"%s"}|}
          name repository_identity );
      ( "partial",
        sprintf
          {|{"io.nixploy.managed":"true","io.nixploy.project":"shared","io.nixploy.target":"production","io.nixploy.repository_identity":"%s"}|}
          repository_identity );
      ( "wrong-resource-key",
        sprintf
          {|{"io.nixploy.managed":"true","io.nixploy.project":"shared","io.nixploy.target":"production","io.nixploy.resource_key":"wrong","io.nixploy.repository_identity":"%s"}|}
          repository_identity );
      ( "legacy-repository",
        sprintf
          {|{"io.nixploy.managed":"true","io.nixploy.project":"shared","io.nixploy.target":"production","io.nixploy.resource_key":"%s","nixploy.repository":"%s"}|}
          name repository_identity );
    ]
    ~f:(fun (case, labels) ->
      if Result.is_ok (parse labels) then
        failwithf "status accepted %s ownership labels" case ())

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
  let project = Nixploy.Project_name.of_string "jomat" |> assert_ok in
  let target = Nixploy.Target_name.of_string "production" |> assert_ok in
  let keys =
    Nixploy.Podman.For_testing.resource_keys_of_containers
      {|[
        {"Labels":{"io.nixploy.managed":"true","io.nixploy.project":"jomat","io.nixploy.target":"production","io.nixploy.resource_key":"nixploy-jomat-legacy-production"}},
        {"Labels":{"io.nixploy.managed":"true","io.nixploy.project":"jomat","io.nixploy.target":"production","io.nixploy.resource_key":"nixploy-jomat-legacy-production"}},
        {"Labels":{"io.nixploy.resource_key":"ignored-partial"}},
        {"Labels":{"nixploy.project":"jomat","nixploy.target":"production","nixploy.resource_key":"ignored-legacy"}}
      ]|}
      ~project ~target
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

let%test_unit "container collision requires complete modern ownership" =
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
  let resource_key_text = Nixploy.Resource_key.to_string resource_key in
  let owned labels =
    Nixploy.Podman.For_testing.owned_candidate_collision
      (sprintf {|[{"Config":{"Labels":%s}}]|} labels)
      ~project ~target ~resource_key
    |> assert_ok
  in
  assert (
    owned
      (sprintf
         {|{"io.nixploy.managed":"true","io.nixploy.project":"sample","io.nixploy.target":"worker","io.nixploy.resource_key":"%s"}|}
         resource_key_text));
  List.iter
    [
      ( "legacy-only",
        sprintf
          {|{"nixploy.project":"sample","nixploy.target":"worker","nixploy.resource_key":"%s"}|}
          resource_key_text );
      ( "mixed",
        sprintf
          {|{"io.nixploy.managed":"true","io.nixploy.project":"sample","nixploy.target":"worker","nixploy.resource_key":"%s"}|}
          resource_key_text );
      ( "partial",
        {|{"io.nixploy.managed":"true","io.nixploy.project":"sample","io.nixploy.target":"worker"}|}
      );
      ( "wrong-resource-key",
        {|{"io.nixploy.managed":"true","io.nixploy.project":"sample","io.nixploy.target":"worker","io.nixploy.resource_key":"wrong"}|}
      );
    ]
    ~f:(fun (case, labels) ->
      if owned labels then failwithf "collision accepted %s labels" case ())

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
    (Nixploy.Configuration.Run.rendered_environment run ~port:None
       ~revision:None);
  let secret_args = [ "--secret"; "source=owned-db,type=env,target=DB" ] in
  let pre_start =
    Nixploy.Podman.For_testing.pre_start_argvs ~connection:"connection" ~run
      ~port:None ~revision:None ~secret_args
      ~image_reference:"loaded@sha256:immutable"
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
      ~name:"nixploy-sample-owned-worker" ~run ~port:None ~revision:None
      ~secret_args
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
      "--restart";
      "always";
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

let%test_unit "Podman secret names parse bounded line-oriented output" =
  let parse = Nixploy.Podman.For_testing.secret_names_of_output in
  [%test_eq: string list]
    [ "nixploy-app-api"; "nixploy-app-DB_PASSWORD" ]
    (parse "nixploy-app-api\nnixploy-app-DB_PASSWORD\n" |> assert_ok);
  [%test_eq: string list] [] (parse "" |> assert_ok);
  parse {|[{"Name":"nixploy-app-api"}]|}
  |> assert_error_containing "invalid character";
  parse "nixploy-app-api\n\n" |> assert_error_containing "empty name";
  parse "nixploy-app-api\r\n" |> assert_error_containing "invalid character";
  parse (String.make 254 'a') |> assert_error_containing "exceeds 253 bytes"

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

let%test_module "host reboot readiness" =
  (module struct
    module Readiness = Nixploy.Host_readiness

    let probe ?(exit_status = Ok ()) ?(stderr = "") stdout =
      Ok { Nixploy.Process_runner.stdout; stderr; exit_status }

    let states readiness =
      Readiness.checks readiness
      |> List.map ~f:(fun (check : Readiness.check) -> check.state)

    let skipped = Or_error.error_string "not probed"

    let%test_unit "rootless host needs linger and the user restart unit" =
      let ready =
        Readiness.For_testing.assess ~user:"nixploy" ~web:false
          ~uid:(probe "1001\n") ~linger:(probe "yes\n")
          ~restart_unit:(probe "enabled\n") ~caddy_exec_start:skipped
      in
      [%test_eq: Readiness.state list] [ Ready; Ready ] (states ready);
      [%test_eq: string list] [] (Readiness.warnings ready);
      let not_ready =
        Readiness.For_testing.assess ~user:"nixploy" ~web:false
          ~uid:(probe "1001\n") ~linger:(probe "no\n")
          ~restart_unit:
            (probe ~exit_status:(Error (`Exit_non_zero 1)) "disabled\n")
          ~caddy_exec_start:skipped
      in
      [%test_eq: Readiness.state list] [ Not_ready; Not_ready ]
        (states not_ready);
      let warnings = Readiness.warnings not_ready in
      [%test_eq: int] 2 (List.length warnings);
      assert (
        List.exists warnings
          ~f:(String.is_substring ~substring:"users.users.nixploy.linger"))

    let%test_unit "root host checks only the system restart unit" =
      let readiness =
        Readiness.For_testing.assess ~user:"root" ~web:false ~uid:(probe "0")
          ~linger:skipped
          ~restart_unit:
            (probe
               ~exit_status:(Error (`Exit_non_zero 1))
               ~stderr:"Failed to get unit file state: No such file" "")
          ~caddy_exec_start:skipped
      in
      [%test_eq: Readiness.state list] [ Not_ready ] (states readiness);
      assert (
        List.exists
          (Readiness.warnings readiness)
          ~f:(String.is_substring ~substring:"multi-user.target"));
      (* NixOS reports package units that no wantedBy enables as linked. *)
      let nixos_linked =
        Readiness.For_testing.assess ~user:"root" ~web:false ~uid:(probe "0")
          ~linger:skipped
          ~restart_unit:
            (probe ~exit_status:(Error (`Exit_non_zero 1)) "linked\n")
          ~caddy_exec_start:skipped
      in
      [%test_eq: Readiness.state list] [ Not_ready ] (states nixos_linked)

    let%test_unit "web targets require Caddy to resume API routes" =
      let assess exec_start =
        Readiness.For_testing.assess ~user:"root" ~web:true ~uid:(probe "0")
          ~linger:skipped ~restart_unit:(probe "enabled")
          ~caddy_exec_start:exec_start
        |> states
      in
      [%test_eq: Readiness.state list] [ Ready; Ready ]
        (assess
           (probe
              "{ path=/nix/store/x-caddy/bin/caddy ; argv[]=caddy run --resume \
               ; }"));
      [%test_eq: Readiness.state list] [ Ready; Not_ready ]
        (assess (probe "{ argv[]=caddy run --config /etc/caddy ; }"));
      [%test_eq: Readiness.state list]
        [ Ready; Unknown "caddy.service was not found" ]
        (assess (probe ""))

    let%test_unit "unreachable probes are unknown, never ready" =
      let readiness =
        Readiness.For_testing.assess ~user:"nixploy" ~web:false
          ~uid:(Or_error.error_string "ssh: connection refused")
          ~linger:skipped ~restart_unit:skipped ~caddy_exec_start:skipped
      in
      match states readiness with
      | [ Unknown reason ] ->
          assert (String.is_substring reason ~substring:"connection refused")
      | _ -> failwith "expected one unknown check"
  end)

let%test_module "status parsing and issues" =
  (module struct
    module Podman = Nixploy.Podman.For_testing
    module Status = Nixploy.Status

    let%test_unit "named stats keep memory limits and pids" =
      let stats =
        Podman.parse_named_stats
          {|[{"id":"a1022dc58e97","name":"owned-blue","cpu_percent":"0.08%","mem_usage":"1.688MB / 33.65GB","pids":"3"},
             {"id":"b1022dc58e97","name":"owned-green","cpu_percent":"--","mem_usage":"12KiB / 512MiB","pids":"1"}]|}
        |> assert_ok
      in
      let blue = List.Assoc.find_exn stats ~equal:String.equal "owned-blue" in
      [%test_eq: float option] (Some 0.08) blue.cpu_percent;
      [%test_eq: int64] 1_688_000L blue.memory_used_bytes;
      [%test_eq: int64 option] (Some 33_650_000_000L) blue.memory_limit_bytes;
      [%test_eq: int option] (Some 3) blue.pids;
      let green = List.Assoc.find_exn stats ~equal:String.equal "owned-green" in
      [%test_eq: float option] None green.cpu_percent;
      [%test_eq: int64 option] (Some 536_870_912L) green.memory_limit_bytes

    let%test_unit "inspect restart policies are keyed by container name" =
      [%test_eq: (string * string option) list]
        [ ("owned-blue", Some "always"); ("owned-green", None) ]
        (Podman.parse_restart_policies
           {|[{"Name":"owned-blue","HostConfig":{"RestartPolicy":{"Name":"always","MaximumRetryCount":0}}},
              {"Name":"/owned-green","HostConfig":{"RestartPolicy":{"Name":""}}}]|}
        |> assert_ok)

    let%test_unit "system df and info expose host-wide storage and capacity" =
      let storage =
        Podman.parse_storage_usage
          {|[{"Type":"Images","Total":1,"RawSize":8709729,"RawReclaimable":1024},
             {"Type":"Containers","Total":1,"RawSize":11292,"RawReclaimable":0},
             {"Type":"Local Volumes","Total":0,"RawSize":0,"RawReclaimable":0}]|}
        |> assert_ok
      in
      [%test_eq: int64] 8_709_729L storage.images_bytes;
      [%test_eq: int64] 1024L storage.images_reclaimable_bytes;
      [%test_eq: int64] 11_292L storage.containers_bytes;
      let host =
        Podman.parse_host_info
          {|{"host":{"cpus":4,"memTotal":8000000000,"memFree":1000000000},
             "store":{"graphRoot":"/home/nixploy/.local/share/containers/storage"}}|}
        |> assert_ok
      in
      [%test_eq: int option] (Some 4) host.cpus;
      [%test_eq: string option]
        (Some "/home/nixploy/.local/share/containers/storage") host.graph_root;
      let disk =
        Status.For_testing.parse_disk ~path:"/storage"
          "Filesystem     1024-blocks     Used Available Capacity Mounted on\n\
           /dev/sda1         40000000 36000000   4000000      90% /\n"
        |> assert_ok
      in
      [%test_eq: int64] 4_096_000_000L disk.available_bytes;
      assert (
        Result.is_error (Status.For_testing.parse_disk ~path:"/" "Filesystem\n"))

    let web_target =
      let configuration =
        Nixploy.Configuration.of_json
          {|{"__schema":"v0.3","project":"sample","targets":{"production":{
              "image":"docker","ip":"host",
              "web":{"domain":"app.example.com","slots":{"blue":8080,"green":8081}}}}}|}
        |> assert_ok
      in
      Nixploy.Configuration.find_target configuration
        (Nixploy.Target_name.of_string "production" |> assert_ok)
      |> assert_ok

    let resource_key =
      Nixploy.Resource_key.derive_current
        ~project:(Nixploy.Project_name.of_string "sample" |> assert_ok)
        ~target:(Nixploy.Target_name.of_string "production" |> assert_ok)
      |> assert_ok

    let container ?(state = "running") ?(restarts = 0) ?(policy = Some "always")
        ~role slot =
      let name =
        Nixploy.Deployment_plan.web_container_name ~resource_key slot
      in
      let workload =
        Nixploy.Workload.all_of_json
          (sprintf {|[{"Names":["%s"],"State":"%s","Restarts":%d}]|} name state
             restarts)
        |> assert_ok |> List.hd_exn
      in
      { Status.workload; role; restart_policy = policy; stats = None }

    let status ?(guard = Ok Nixploy.Mutation_guard.Absent) ?disk ~route
        containers =
      Status.For_testing.create
        ~project:(Nixploy.Project_name.of_string "sample" |> assert_ok)
        ~target:web_target ~resource_key ~containers ~route ~secrets:(Ok [])
        ~disk:(Option.value disk ~default:(Or_error.error_string "unobserved"))
        ~guard
        ~readiness:
          (Nixploy.Host_readiness.For_testing.assess ~user:"root" ~web:false
             ~uid:(Ok { stdout = "0"; stderr = ""; exit_status = Ok () })
             ~linger:(Or_error.error_string "skipped")
             ~restart_unit:
               (Ok { stdout = "enabled"; stderr = ""; exit_status = Ok () })
             ~caddy_exec_start:(Or_error.error_string "skipped"))

    let has issues substring =
      List.exists issues ~f:(String.is_substring ~substring)

    let%test_unit "a healthy routed slot has no issues" =
      let routed =
        Ok
          (Status.Routed
             { domain = "app.example.com"; port = 8080; slot = Some Blue })
      in
      [%test_eq: string list] []
        (Status.issues (status ~route:routed [ container ~role:Active Blue ]))

    let%test_unit "a lost route, stale slot, crash loop and marker are issues" =
      let issues =
        status ~route:(Ok Status.Missing)
          ~guard:(Ok (Nixploy.Mutation_guard.Present ".nixploy-mutations/x"))
          [ container ~role:Unrouted ~state:"exited" Blue ]
        |> Status.issues
      in
      assert (has issues "the Caddy route is missing");
      assert (has issues "is not served by the route");
      assert (has issues "mutation marker .nixploy-mutations/x is present");
      let issues =
        status
          ~route:
            (Ok
               (Status.Routed
                  { domain = "app.example.com"; port = 8081; slot = Some Green }))
          ~disk:
            (Ok
               {
                 Status.total_bytes = 100_000L;
                 available_bytes = 5_000L;
                 path = "/";
               })
          [
            container ~role:Active ~state:"exited" ~restarts:4 ~policy:None
              Green;
          ]
        |> Status.issues
      in
      assert (has issues "is exited");
      assert (has issues "has restarted 4 times");
      assert (has issues "has no restart policy; redeploy");
      assert (has issues "is free on /")

    let%test_unit "a stopped target is reported once, as stopped" =
      let stopped =
        status ~route:(Ok Status.Missing)
          [ container ~role:Unrouted ~state:"exited" ~policy:(Some "no") Blue ]
      in
      assert (Status.stopped stopped);
      (match Status.issues stopped with
      | [ issue ] -> assert (String.is_substring issue ~substring:"is stopped")
      | issues ->
          failwiths ~here:[%here] "issues" issues [%sexp_of: string list]);
      let crashed =
        status ~route:(Ok Status.Missing)
          [ container ~role:Unrouted ~state:"exited" Blue ]
      in
      assert (not (Status.stopped crashed))

    let%test_unit "a route to a slot without a container is reported" =
      let issues =
        status
          ~route:
            (Ok
               (Status.Routed
                  { domain = "app.example.com"; port = 8081; slot = Some Green }))
          []
        |> Status.issues
      in
      assert (has issues "serves the green slot, but no owned container")
  end)

let%test_module "owned images and stale cleanup planning" =
  (module struct
    module Plan = Nixploy.Stale_plan

    let resource_key =
      Nixploy.Resource_key.derive_current
        ~project:(Nixploy.Project_name.of_string "My_App" |> assert_ok)
        ~target:(Nixploy.Target_name.of_string "prod_" |> assert_ok)
      |> assert_ok

    let%test_unit "owned references use a valid, exact repository" =
      let repository = Nixploy.Owned_image.repository resource_key in
      assert (String.is_prefix repository ~prefix:"localhost/nixploy/");
      assert (
        String.for_all (String.drop_prefix repository 18) ~f:(fun c ->
            Char.is_lowercase c || Char.is_digit c || Char.equal c '-'));
      assert (not (String.is_suffix repository ~suffix:"-"));
      let reference =
        Nixploy.Owned_image.reference resource_key
          ~loaded_at:
            (Time_float.of_date_ofday ~zone:Time_float.Zone.utc
               (Date.of_string "2026-09-19")
               (Time_float.Ofday.create ~hr:10 ~min:15 ~sec:0 ()))
          ~revision:"ABCDEF0123456789abcdef"
      in
      [%test_eq: string]
        (repository ^ ":20260919T101500Z-abcdef012345")
        reference;
      [%test_eq: string option] (Some "20260919T101500Z-abcdef012345")
        (Nixploy.Owned_image.tag ~repository reference);
      [%test_eq: string option] None
        (Nixploy.Owned_image.tag ~repository (repository ^ "-2:tag"));
      let listed =
        Nixploy.Podman.For_testing.owned_images_of_listing ~repository
          (sprintf
             {|[{"Id":"a","Names":["%s:t2","other:latest"],"Size":10,"Containers":1},
                {"Id":"a","Names":["%s:t2","other:latest"],"Size":10,"Containers":1},
                {"Id":"b","Names":["%s-2:t1"],"Size":20,"Containers":0}]|}
             repository repository repository)
        |> assert_ok
      in
      [%test_eq: string list] [ "a" ]
        (List.map listed ~f:(fun (image : Nixploy.Podman.owned_image) ->
             image.image_id));
      [%test_eq: string list]
        [ repository ^ ":t2" ]
        (List.hd_exn listed).references

    let slot slot = Nixploy.Deployment_plan.Web_slot { slot; port = 0 }

    let container ?(secrets = Some []) ?image name placement =
      {
        Plan.name;
        placement;
        running = true;
        secret_names = secrets;
        image_id = image;
      }

    let image ?(containers = 0) id tag =
      {
        Plan.image_id = id;
        references = [ "localhost/nixploy/key:" ^ tag ];
        size_bytes = Some 100L;
        containers;
      }

    let names containers =
      List.map containers ~f:(fun (container : Plan.container) ->
          container.name)

    let image_ids images =
      List.map images ~f:(fun (image : Plan.image) -> image.image_id)

    let%test_unit "the routed slot, its secrets and newest images stay" =
      let plan =
        Plan.create ~route:(Routed (Some Green))
          ~containers:
            [
              container "blue" (slot Blue) ~secrets:(Some [ "key-OLD" ])
                ~image:"old";
              container "green" (slot Green) ~secrets:(Some [ "key-DB" ])
                ~image:"current";
              container "single" Single_container;
            ]
          ~owned_secrets:[ "key-DB"; "key-OLD"; "key-UNUSED" ]
          ~images:
            [
              image "oldest" "20260101T000000Z-a";
              image "old" "20260201T000000Z-b" ~containers:1;
              image "previous" "20260301T000000Z-c";
              image "current" "20260401T000000Z-d" ~containers:1;
            ]
          ~keep:2
        |> assert_ok
      in
      [%test_eq: string list] [ "blue"; "single" ]
        (names plan.remove_containers);
      [%test_eq: string list] [ "key-OLD"; "key-UNUSED" ] plan.remove_secrets;
      [%test_eq: string list] [ "oldest"; "old" ] (image_ids plan.remove_images);
      [%test_eq: string list] [] plan.notes

    let%test_unit "images used by other containers are kept" =
      let plan =
        Plan.create ~route:Non_web
          ~containers:[ container "app" Single_container ~image:"current" ]
          ~owned_secrets:[]
          ~images:
            [
              image "shared" "20260101T000000Z-a" ~containers:1;
              image "current" "20260401T000000Z-d" ~containers:1;
            ]
          ~keep:1
        |> assert_ok
      in
      [%test_eq: string list] [] (image_ids plan.remove_images)

    let%test_unit "an unknown live slot keeps every container" =
      List.iter [ Plan.Missing; Routed None; Routed (Some Blue) ]
        ~f:(fun route ->
          let plan =
            Plan.create ~route
              ~containers:[ container "green" (slot Green) ]
              ~owned_secrets:[] ~images:[] ~keep:1
            |> assert_ok
          in
          [%test_eq: string list] [] (names plan.remove_containers);
          [%test_eq: int] 1 (List.length plan.notes))

    let%test_unit "untracked secrets and invalid keep are conservative" =
      let plan =
        Plan.create ~route:Non_web
          ~containers:[ container "app" Single_container ~secrets:None ]
          ~owned_secrets:[ "key-DB" ] ~images:[] ~keep:1
        |> assert_ok
      in
      [%test_eq: string list] [] plan.remove_secrets;
      assert (
        List.exists plan.notes ~f:(String.is_substring ~substring:"predates"));
      assert (
        Result.is_error
          (Plan.create ~route:Non_web ~containers:[] ~owned_secrets:[]
             ~images:[] ~keep:0))
  end)

let%test_module "host inventory grouping" =
  (module struct
    module Inventory = Nixploy.Inventory

    let project = Nixploy.Project_name.of_string "shop" |> assert_ok
    let name value = Nixploy.Target_name.of_string value |> assert_ok

    let key target =
      Nixploy.Resource_key.derive ~project ~target:(name target)
        ~repository_identity:"git@example.invalid:shop.git"
      |> assert_ok

    let labels ?(project = "shop")
        ?(repository = "git@example.invalid:shop.git") target =
      [
        ("io.nixploy.managed", "true");
        ("io.nixploy.project", project);
        ("io.nixploy.target", target);
        ( "io.nixploy.resource_key",
          if String.equal project "shop" then
            Nixploy.Resource_key.to_string (key target)
          else "nixploy-" ^ project ^ "-0123456789-" ^ target );
        ("io.nixploy.repository_identity", repository);
      ]

    let resource ?(labels = []) ?(state = Some "running") id resource_name =
      {
        Nixploy.Podman.Labelled.id;
        name = resource_name;
        state;
        status = None;
        labels;
      }

    let%test_unit "resources are grouped and classified against the flake" =
      let old_key = Nixploy.Resource_key.to_string (key "staging-old") in
      let old_repository = Nixploy.Owned_image.repository (key "staging-old") in
      let marker =
        Nixploy.Resource_key.derive_current ~project
          ~target:(name "staging-old")
        |> assert_ok |> Nixploy.Resource_key.to_string
      in
      let groups, unattributed_images, legacy, unattributed_markers =
        Inventory.For_testing.build ~project
          ~declared:[ name "production"; name "staging" ]
          ~current_key:(key "production")
          ~containers:
            [
              resource "c1" "prod" ~labels:(labels "production");
              resource "c2" "staging" ~labels:(labels "staging");
              resource "c3" "old" ~labels:(labels "staging-old")
                ~state:(Some "exited");
              resource "c4" "blog" ~labels:(labels ~project:"blog" "web");
              resource "c5" "mixed"
                ~labels:
                  (List.Assoc.add (labels "gone") ~equal:String.equal
                     "io.nixploy.resource_key" "nixploy-shop-conflict-gone");
            ]
          ~secrets:
            [
              resource "s1" (old_key ^ "-DB") ~labels:(labels "staging-old");
              resource "s2" "nixploy-legacy-DB";
              resource "s3" "nixploy-shop-conflict-gone-DB"
                ~labels:
                  (List.Assoc.add
                     (labels ~repository:"git@example.invalid:fork.git" "gone")
                     ~equal:String.equal "io.nixploy.resource_key"
                     "nixploy-shop-conflict-gone");
            ]
          ~images:
            [
              {
                image_id = "i1";
                references = [ old_repository ^ ":20260101T000000Z-a" ];
                size_bytes = Some 10L;
                containers = 0;
              };
              {
                image_id = "i2";
                references = [ "localhost/nixploy/unknown:t" ];
                size_bytes = Some 5L;
                containers = 0;
              };
            ]
          ~route_keys:[ old_key; "not a key" ]
          ~markers:[ marker; "nixploy-stray-0000000000-x" ]
      in
      let classification target =
        (List.find_exn groups ~f:(fun (group : Inventory.group) ->
             Option.equal String.equal group.target (Some target)))
          .classification
      in
      [%test_eq: Inventory.classification] Current (classification "production");
      [%test_eq: Inventory.classification] Declared (classification "staging");
      [%test_eq: Inventory.classification] Orphaned
        (classification "staging-old");
      [%test_eq: Inventory.classification] Other_project (classification "web");
      let old =
        List.find_exn groups ~f:(fun (group : Inventory.group) ->
            String.equal group.resource_key old_key)
      in
      [%test_eq: int] 1 (List.length old.containers);
      [%test_eq: int] 1 (List.length old.secrets);
      [%test_eq: string list] [ "i1" ]
        (List.map old.images ~f:(fun image -> image.image_id));
      assert old.route;
      [%test_eq: string option] (Some marker) old.marker;
      let conflict =
        List.find_exn groups ~f:(fun (group : Inventory.group) ->
            String.equal group.resource_key "nixploy-shop-conflict-gone")
      in
      assert (
        List.exists conflict.problems
          ~f:(String.is_substring ~substring:"conflicting repository"));
      [%test_eq: string list] [ "i2" ]
        (List.map unattributed_images ~f:(fun image -> image.image_id));
      [%test_eq: string list] [ "nixploy-legacy-DB" ] legacy;
      [%test_eq: string list]
        [ "nixploy-stray-0000000000-x" ]
        unattributed_markers;
      [%test_eq: Inventory.classification] Current
        (List.hd_exn groups).classification
  end)
