open Core

type t = { capability_grant : string; expires_at_monotonic_ms : int64 }

let empty = { capability_grant = ""; expires_at_monotonic_ms = 0L }

(* The server issues five-minute grants.  This bound prevents a malformed
   capability response from retaining a token indefinitely. *)
let maximum_grant_lifetime_ms = Int64.of_int (5 * 60 * 1000)

let renewed _ ~capability_grant ~server_time_ms ~grant_expires_at_ms
    ~received_at_monotonic_ms =
  if
    String.is_empty capability_grant
    || Int64.(server_time_ms < 0L)
    || Int64.(received_at_monotonic_ms < 0L)
    || Int64.(grant_expires_at_ms <= server_time_ms)
  then empty
  else
    let lifetime_ms = Int64.(grant_expires_at_ms - server_time_ms) in
    if
      Int64.(lifetime_ms > maximum_grant_lifetime_ms)
      || Int64.(received_at_monotonic_ms > max_value - lifetime_ms)
    then empty
    else
      {
        capability_grant;
        expires_at_monotonic_ms = Int64.(received_at_monotonic_ms + lifetime_ms);
      }

let renewal_failed _ = empty
let reconnected _ = empty

let token_for_managed_rpc { capability_grant; expires_at_monotonic_ms }
    ~now_monotonic_ms =
  if
    String.is_empty capability_grant
    || Int64.(now_monotonic_ms < 0L)
    || Int64.(now_monotonic_ms >= expires_at_monotonic_ms)
  then ""
  else capability_grant
