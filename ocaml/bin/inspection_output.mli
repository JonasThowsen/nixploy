val status : Nixploy.Application.status -> string
val history : Nixploy.Application.deployment list -> string
val status_json : Nixploy.Application.status -> string
val history_json : Nixploy.Application.deployment list -> string
val deployment_json : Nixploy.Application.deployment -> string
val logs_json : Nixploy.Application.log_snapshot -> string
val prune : Nixploy.Application.prune_result -> string
val prune_json : Nixploy.Application.prune_result -> string
val resources : Nixploy.Inventory.t -> string
val resources_json : Nixploy.Inventory.t -> string
val orphan_prune : Nixploy.Orphan_prune.t -> string
val orphan_prune_json : Nixploy.Orphan_prune.t -> string
val stop : Nixploy.Stop.t -> string
val stop_json : Nixploy.Stop.t -> string
val orphan_stop : Nixploy.Orphan_prune.stopped -> string
val orphan_stop_json : Nixploy.Orphan_prune.stopped -> string
