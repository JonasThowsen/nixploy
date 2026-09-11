val status : Nixploy.Application.status -> string
val history : Nixploy.Application.deployment list -> string
val status_json : Nixploy.Application.status -> string
val history_json : Nixploy.Application.deployment list -> string
val deployment_json : Nixploy.Application.deployment -> string
val logs_json : Nixploy.Application.log_snapshot -> string
