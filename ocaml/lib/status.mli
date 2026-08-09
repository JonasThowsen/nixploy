open Async

type t

val load :
  working_directory:string -> target:Target_name.t -> t Deferred.Or_error.t

val project : t -> Project_name.t
val target : t -> Configuration.Target.t
val resource_key : t -> Resource_key.t
val workloads : t -> Workload.t list
