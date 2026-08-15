open Core
module Application = Nixploy.Application
module Deployment_output = Nixploy_cli_mapping.Deployment_output
module Deployment_start = Nixploy_rpc_mapping.Deployment_start

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
