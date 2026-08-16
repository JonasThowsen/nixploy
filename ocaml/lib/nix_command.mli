val evaluation_args : flake:string -> output:string -> string list
(** Evaluate an output from the Git-aware flake rooted at the process working
    directory without changing its lock file. *)

val build_args : flake:string -> output:string -> string list
(** Build an output from the same Git-aware flake and print its one output path
    without creating a result link. *)
