open Async
open Core
module Application = Nixploy.Application
module Deployment_output = Nixploy_cli_mapping.Deployment_output
module Consumer_response = Nixploy_rpc_mapping.Consumer_response
module Deployment_start = Nixploy_rpc_mapping.Deployment_start
module Prune_response = Nixploy_rpc_mapping.Prune_response
module Resource_state_response = Nixploy_rpc_mapping.Resource_state_response
module Inspection_output = Nixploy_cli_mapping.Inspection_output

let deployment state =
  Application.For_testing.deployment ~id:"operation-123" ~state
    ~revision:(String.make 40 'c') ~container_name:"example-production-green"
    ~error:"candidate failed" ()

let run_tests () =
  let open Deferred.Let_syntax in
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
    Nixploy.Resource_key.derive ~project ~target
      ~repository_identity:"git@example.invalid:example.git"
    |> Or_error.ok_exn
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
          Deployment_output.Incomplete));
  let protocol =
    Consumer_response.deployment ~now_ms:100L ~can_cancel:false failed
  in
  assert (String.equal protocol.id "operation-123");
  assert ([%equal: Protocol.Deployment.State.t] protocol.state Failed);
  assert (not protocol.can_cancel);
  let status =
    Consumer_response.application managed_application
      ~resource_state:Application.Present ~deployment:(Some protocol)
  in
  assert (String.equal status.key "example");
  assert ([%equal: Protocol.Resource_state.t] status.resource_state Present);
  let recent =
    Consumer_response.recent_deployment ~application:managed_application
      ~deployment:protocol
  in
  assert (String.equal recent.application "example");
  Consumer_response.cancellation Application.Cancellation_requested;
  let snapshot =
    Consumer_response.log_snapshot ~application:"example"
      {
        Application.container_name = "example-production";
        revision = Some (String.make 40 'c');
        observed_at_ms = 5L;
        lines = [ { timestamp = None; text = "ready" } ];
        truncated = false;
      }
  in
  assert (String.equal snapshot.application "example");
  assert (String.equal (List.hd_exn snapshot.lines).text "ready");
  let rendered_history = Inspection_output.history [ failed ] in
  assert (String.is_substring rendered_history ~substring:"operation-123");
  assert (String.is_substring rendered_history ~substring:"failed");
  let applications =
    List.init 8 ~f:(fun index ->
        Nixploy.Managed_application.all_of_json
          (sprintf
             {|{"app-%d":{"project":"example","target":"target-%d","repository":"/srv/example-%d"}}|}
             index index index)
        |> Or_error.ok_exn |> List.hd_exn)
  in
  let active = ref 0 in
  let maximum_active = ref 0 in
  let observe application =
    Int.incr active;
    maximum_active := Int.max !maximum_active !active;
    let%map () = Clock_ns.after (Time_ns.Span.of_ms 5.) in
    Int.decr active;
    {
      Application.target =
        Nixploy.Managed_application.target application
        |> Nixploy.Target_name.to_string;
      host = "shared-host";
      observed_at_ms = 1L;
      freshness = Application.Fresh;
      error = None;
      cpu_percent = None;
      memory_used_bytes = None;
      memory_total_bytes = None;
      filesystem_used_bytes = None;
      filesystem_total_bytes = None;
      load_1 = None;
      load_5 = None;
      load_15 = None;
      uptime_seconds = None;
      applications =
        [
          {
            Application.application =
              Nixploy.Managed_application.key application;
            container_name = None;
            health = Unavailable "not configured";
            error = None;
            cpu_percent = None;
            memory_used_bytes = None;
            memory_host_percent = None;
            uptime_seconds = None;
          };
        ];
    }
  in
  let%map metrics = Consumer_response.collect_metrics applications ~observe in
  [%test_eq: int] Consumer_response.max_concurrent_metrics !maximum_active;
  [%test_eq: int] 1 (List.length metrics);
  [%test_eq: int] 8 (List.length (List.hd_exn metrics).applications)

let () =
  don't_wait_for
    ( Monitor.try_with run_tests >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1 );
  never_returns (Scheduler.go ())
