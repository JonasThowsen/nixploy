type t

val empty : t

val renewed :
  t ->
  capability_grant:string ->
  server_time_ms:int64 ->
  grant_expires_at_ms:int64 ->
  received_at_monotonic_ms:int64 ->
  t

val renewal_failed : t -> t
val reconnected : t -> t
val token_for_managed_rpc : t -> now_monotonic_ms:int64 -> string
