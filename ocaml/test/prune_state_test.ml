module Prune_state = Nixploy_web_client_state.Prune_state

let () =
  let confirming = Prune_state.confirm Idle ~key:"example" in
  assert (
    [%equal: Prune_state.t] confirming
      (Confirming { key = "example"; error = None }));
  assert (
    [%equal: Prune_state.t]
      (Prune_state.confirm confirming ~key:"other")
      confirming);
  let pending = Prune_state.start confirming ~key:"example" in
  assert ([%equal: Prune_state.t] pending (Pending "example"));
  assert (Prune_state.is_pending pending);
  assert (
    [%equal: Prune_state.t] (Prune_state.succeed pending ~key:"other") pending);
  let failed = Prune_state.fail pending ~key:"example" ~error:"try again" in
  assert (
    [%equal: Prune_state.t] failed
      (Confirming { key = "example"; error = Some "try again" }));
  assert ([%equal: Prune_state.t] (Prune_state.keep failed ~key:"other") failed);
  assert ([%equal: Prune_state.t] (Prune_state.keep failed ~key:"example") Idle);
  assert (
    [%equal: Prune_state.t] (Prune_state.succeed pending ~key:"example") Idle)
