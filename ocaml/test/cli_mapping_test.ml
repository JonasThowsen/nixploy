open Core
module Application = Nixploy.Application
module Deployment_output = Nixploy_cli_mapping.Deployment_output
module Inspection_output = Nixploy_cli_mapping.Inspection_output

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
          Deployment_output.Incomplete));
  let rendered_history = Inspection_output.history [ failed ] in
  assert (String.is_substring rendered_history ~substring:"operation-123");
  assert (String.is_substring rendered_history ~substring:"failed")

let () =
  [%test_eq: string option] (Some "NIXPLOY_SSH_FAILED")
    (Inspection_output.error_code
       "NIXPLOY_SSH_FAILED: cannot run a command. Set \
        NIXPLOY_SSH_IDENTITY_FILE.");
  [%test_eq: string option] (Some "NIXPLOY_MUTATION_UNCERTAIN")
    (Inspection_output.error_code
       "(\"NIXPLOY_MUTATION_UNCERTAIN: evidence retained\" \"inner\")");
  [%test_eq: string option] None
    (Inspection_output.error_code
       "no usable key; set NIXPLOY_SSH_IDENTITY_FILE or NIXPLOY_STATE_DB");
  let json = Yojson.Safe.from_string (Inspection_output.error_json "boom") in
  [%test_eq: string] {|{"error":{"code":null,"message":"boom"}}|}
    (Yojson.Safe.to_string json)
