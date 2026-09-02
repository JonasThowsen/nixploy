open Core
module Deploy_state = Nixploy_web_client_state.Deploy_state

let () =
  let idle = Deploy_state.Idle in
  let submitting = Deploy_state.start_submission idle ~key:"example" in
  assert ([%equal: Deploy_state.t] submitting (Submitting "example"));
  assert (Deploy_state.is_busy submitting);
  assert (Deploy_state.is_pending submitting);
  assert (Deploy_state.is_pending_for submitting ~key:"example");
  assert (
    [%equal: Deploy_state.t]
      (Deploy_state.start_submission submitting ~key:"other")
      submitting);
  assert (
    [%equal: Deploy_state.t]
      (Deploy_state.finish_submission submitting ~key:"other")
      submitting);
  assert (
    [%equal: Deploy_state.t]
      (Deploy_state.reset_for_route_change submitting)
      Idle);
  let accepted =
    Deploy_state.accept_submission submitting ~key:"example"
      ~operation_id:"operation-1"
  in
  assert (Deploy_state.is_busy accepted);
  assert (
    [%equal: Deploy_state.t]
      (Deploy_state.reset_for_route_change accepted)
      accepted);
  assert (Deploy_state.is_pending_for accepted ~key:"example");
  [%test_eq: (string * string) option]
    (Some ("example", "operation-1"))
    (Deploy_state.awaiting_operation accepted);
  assert (
    [%equal: Deploy_state.t]
      (Deploy_state.observe_operation accepted ~key:"other"
         ~operation_id:"operation-1")
      accepted);
  assert (
    [%equal: Deploy_state.t]
      (Deploy_state.observe_operation accepted ~key:"example"
         ~operation_id:"other")
      accepted);
  assert (
    [%equal: Deploy_state.t]
      (Deploy_state.observe_operation accepted ~key:"example"
         ~operation_id:"operation-1")
      Idle);
  assert (
    [%equal: Deploy_state.t]
      (Deploy_state.finish_submission submitting ~key:"example")
      Idle)
