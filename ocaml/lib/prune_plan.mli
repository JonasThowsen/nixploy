type t

val create : resource_key:Resource_key.t -> t
val container_names : t -> string list
val select_secret_names : t -> string list -> string list
