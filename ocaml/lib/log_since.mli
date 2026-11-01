open Core

(** The instant [nixploy logs --since] reads from. *)

type t

val of_string : string -> t Or_error.t
(** Accepts an RFC 3339 date-time with seconds and a zone, such as
    [2026-11-01T10:00:00Z] or [2026-11-01T12:00:00.5+02:00], between the years
    1970 and 2100. Anything else, including durations and bare dates, is
    refused. *)

val to_string : t -> string
(** The same instant in UTC, as [2026-11-01T10:00:00Z], with fractional seconds
    only when the input had a nonzero fraction. This is what Podman is given. *)
