open Core
module U = Caml_unix

(** Bounded, deadline-driven Unix-socket operations shared by the target-lease
    broker and its client. All timeouts are single absolute CLOCK_MONOTONIC
    deadlines; every EINTR/EAGAIN retry recomputes the remaining time from the
    same deadline. *)

type deadline = float

val now : unit -> float
val remaining : deadline -> float
val connect : U.file_descr -> U.sockaddr -> deadline:deadline -> unit Or_error.t

val send_all :
  U.file_descr -> data:string -> deadline:deadline -> unit Or_error.t

val recv_line :
  U.file_descr -> limit:int -> deadline:deadline -> string Or_error.t
