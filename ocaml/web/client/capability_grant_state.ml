open Core

type t = { capability_grant : string; grant_expires_at_ms : int64 }

let empty = { capability_grant = ""; grant_expires_at_ms = 0L }

let renewed _ ~capability_grant ~grant_expires_at_ms =
  { capability_grant; grant_expires_at_ms }

let renewal_failed _ = empty
let reconnected _ = empty

let token_for_managed_rpc { capability_grant; grant_expires_at_ms } ~now_ms =
  if String.is_empty capability_grant || Int64.(now_ms >= grant_expires_at_ms)
  then ""
  else capability_grant
