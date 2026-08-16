module Deploy_state = Nixploy_web_client_state.Deploy_state

let () =
  let previewing = Deploy_state.start_preview Idle ~key:"example" in
  assert ([%equal: Deploy_state.t] previewing (Previewing "example"));
  assert (Deploy_state.is_busy previewing);
  assert (Deploy_state.is_previewing previewing ~key:"example");
  assert (
    [%equal: Deploy_state.t]
      (Deploy_state.start_submission previewing ~key:"other")
      previewing);
  assert (
    [%equal: Deploy_state.t]
      (Deploy_state.finish_preview previewing ~key:"other")
      previewing);
  let idle = Deploy_state.finish_preview previewing ~key:"example" in
  assert ([%equal: Deploy_state.t] idle Idle);
  let submitting = Deploy_state.start_submission idle ~key:"example" in
  assert ([%equal: Deploy_state.t] submitting (Submitting "example"));
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
      (Deploy_state.finish_submission submitting ~key:"example")
      Idle)
