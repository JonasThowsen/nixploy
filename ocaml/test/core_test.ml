open Core

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

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
      let actual = Nixploy.Resource_key.derive ~project ~target |> assert_ok in
      [%test_eq: string] expected (Nixploy.Resource_key.to_string actual))

let%test_unit "resource identity bounds both readable parts" =
  let project =
    Nixploy.Project_name.of_string (String.make 80 'A') |> assert_ok
  in
  let target =
    Nixploy.Target_name.of_string (String.make 80 'B') |> assert_ok
  in
  let key =
    Nixploy.Resource_key.derive ~project ~target
    |> assert_ok |> Nixploy.Resource_key.to_string
  in
  let expected = "nixploy-" ^ String.make 48 'a' ^ "-" in
  assert (String.is_prefix key ~prefix:expected);
  assert (String.is_suffix key ~suffix:("-" ^ String.make 48 'b'))

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
       ~port:8081)

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
  let first =
    Nixploy.Deployment_plan.create ~web ~active_port:None |> assert_ok
  in
  let after_blue =
    Nixploy.Deployment_plan.create ~web ~active_port:(Some 8080) |> assert_ok
  in
  [%test_eq: Nixploy.Deployment_plan.slot] Nixploy.Deployment_plan.Blue
    (Nixploy.Deployment_plan.candidate_slot first);
  [%test_eq: Nixploy.Deployment_plan.slot option] None
    (Nixploy.Deployment_plan.active_slot first);
  [%test_eq: Nixploy.Deployment_plan.slot] Nixploy.Deployment_plan.Green
    (Nixploy.Deployment_plan.candidate_slot after_blue);
  [%test_eq: Nixploy.Deployment_plan.slot option]
    (Some Nixploy.Deployment_plan.Blue)
    (Nixploy.Deployment_plan.active_slot after_blue)

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
