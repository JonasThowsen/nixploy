/// Return one only for the exact remote-control-plane deploy boundary.
/// The host maps canonical JSON fields to these closed integer enums before
/// invocation, so the component receives no filesystem, network, clock, or
/// environment capabilities.
pub fn decide(
  operation : Int,
  runtime_mode : Int,
  source_kind : Int,
  resource_key_valid : Int,
  immutable_identity_valid : Int,
) -> Int {
  if (operation == 1 || operation == 2) &&
    runtime_mode == 1 &&
    source_kind == 1 &&
    resource_key_valid == 1 &&
    immutable_identity_valid == 1 {
    1
  } else {
    0
  }
}

fn main {
  println("{\"schema\":\"nixploy.policy/v1\",\"ready\":true}")
}
