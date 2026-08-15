open Core
module Application = Nixploy.Application
module Deployment_output = Nixploy_cli_mapping.Deployment_output
module Deployment_start = Nixploy_rpc_mapping.Deployment_start
module Prune_response = Nixploy_rpc_mapping.Prune_response
module Resource_state_response = Nixploy_rpc_mapping.Resource_state_response

let deployment state =
  Application.For_testing.deployment ~id:"operation-123" ~state
    ~revision:(String.make 40 'c') ~container_name:"example-production-green"
    ~error:"candidate failed" ()

let () =
  let failed = deployment Application.Failed in
  let output = Deployment_output.of_deployment failed in
  assert (String.equal "operation-123" (Deployment_output.id output));
  assert (String.equal "failed" (Deployment_output.state_name output));
  assert (
    Option.equal String.equal
      (Some (String.make 40 'c'))
      (Deployment_output.revision output));
  assert (
    Option.equal String.equal (Some "example-production-green")
      (Deployment_output.container_name output));
  assert (
    [%equal: Deployment_output.terminal_state]
      (Deployment_output.terminal_state output)
      (Deployment_output.Failed (Some "candidate failed")));
  assert (String.equal "operation-123" (Deployment_start.operation_id failed));
  let managed_application =
    Nixploy.Managed_application.all_of_json
      {|{"example":{"project":"example","target":"production","repository":"/srv/example"}}|}
    |> Or_error.ok_exn |> List.hd_exn
  in
  let project = Nixploy.Project_name.of_string "example" |> Or_error.ok_exn in
  assert (
    Nixploy.Project_name.equal
      (Deployment_start.expected_project managed_application)
      project);
  let target = Nixploy.Target_name.of_string "production" |> Or_error.ok_exn in
  let resource_key =
    Nixploy.Resource_key.derive ~project ~target |> Or_error.ok_exn
  in
  let prune route =
    Application.For_testing.prune_result ~project ~target ~resource_key
      ~containers_removed:2 ~secrets_removed:3 ~route
    |> Prune_response.of_application
  in
  let removed = prune Application.Removed in
  assert (String.equal removed.project "example");
  assert (String.equal removed.target "production");
  assert (
    String.equal removed.resource_key
      (Nixploy.Resource_key.to_string resource_key));
  assert (Int.equal removed.containers_removed 2);
  assert (Int.equal removed.secrets_removed 3);
  assert ([%equal: Protocol.Prune_result.Route.t] removed.route Removed);
  assert (
    [%equal: Protocol.Prune_result.Route.t] (prune Application.Missing).route
      Missing);
  assert (
    [%equal: Protocol.Prune_result.Route.t]
      (prune Application.Not_configured).route Not_configured);
  assert (
    [%equal: Protocol.Resource_state.t]
      (Resource_state_response.of_application Application.Unknown)
      Unknown);
  assert (
    [%equal: Protocol.Resource_state.t]
      (Resource_state_response.of_application Application.Present)
      Present);
  assert (
    [%equal: Protocol.Resource_state.t]
      (Resource_state_response.of_application Application.Absent)
      Absent);
  assert (
    [%equal: Deployment_output.terminal_state]
      (Deployment_output.of_deployment (deployment Application.Succeeded)
      |> Deployment_output.terminal_state)
      Deployment_output.Succeeded);
  assert (
    [%equal: Deployment_output.terminal_state]
      (Deployment_output.of_deployment (deployment Application.Cancelled)
      |> Deployment_output.terminal_state)
      Deployment_output.Cancelled);
  List.iter [ Application.Requested; Application.Running ] ~f:(fun state ->
      assert (
        [%equal: Deployment_output.terminal_state]
          (Deployment_output.of_deployment (deployment state)
          |> Deployment_output.terminal_state)
          Deployment_output.Incomplete))
