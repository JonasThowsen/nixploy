open Core
module U = Caml_unix

external socket_error_number : U.file_descr -> int
  = "caml_nixploy_target_lease_socket_error"

external monotonic_clock : unit -> float
  = "caml_nixploy_target_lease_monotonic_clock"

(** Absolute CLOCK_MONOTONIC deadlines for bounded socket operations. Every
    retry recomputes the remaining time from the same absolute deadline, so
    bursts of EINTR/EAGAIN events cannot extend any operation beyond its bound.
*)

type deadline = float

let now () = monotonic_clock ()
let remaining (deadline : deadline) : float = deadline -. now ()

(* Waits until [fd] is readable and/or writable.  Returns None only when the
   absolute deadline has passed. *)
let rec wait fd ~(read : bool) ~(write : bool) ~(deadline : deadline) :
    (bool * bool) option =
  let timeout = remaining deadline in
  if Float.(timeout <= 0.) then None
  else
    try
      let readable, writable, _ =
        U.select
          (if read then [ fd ] else [])
          (if write then [ fd ] else [])
          [] timeout
      in
      Some (not (List.is_empty readable), not (List.is_empty writable))
    with U.Unix_error (U.EINTR, _, _) -> wait fd ~read ~write ~deadline

(** Nonblocking connect against an absolute deadline: sets the descriptor
    nonblocking first, waits for writability, and verifies SO_ERROR before
    reporting success. *)
let rec connect fd address ~(deadline : deadline) : unit Or_error.t =
  U.set_nonblock fd;
  match U.connect fd address with
  | () -> Ok ()
  | exception U.Unix_error ((U.EINPROGRESS | U.EAGAIN | U.EWOULDBLOCK), _, _) ->
      let poll () =
        match wait fd ~read:false ~write:true ~deadline with
        | None | Some (_, false) ->
            Or_error.error_string "broker connection timed out"
        | Some (_, true) -> (
            match socket_error_number fd with
            | 0 -> Ok ()
            | errno ->
                Or_error.errorf "broker connection failed (errno %d)" errno)
      in
      poll ()
  | exception U.Unix_error (U.EINTR, _, _) -> connect fd address ~deadline
  | exception U.Unix_error (error, _, _) ->
      Or_error.errorf "broker connection failed: %s" (U.error_message error)

(** Writes every byte of [data] or fails by the absolute deadline. *)
let send_all fd ~(data : string) ~(deadline : deadline) : unit Or_error.t =
  let length = String.length data in
  let out_of_time () =
    Or_error.error_string "broker socket operation timed out"
  in
  let rec write offset =
    if offset = length then Ok ()
    else if Float.(remaining deadline <= 0.) then out_of_time ()
    else
      match
        try Ok (U.write_substring fd data offset (length - offset)) with
        | U.Unix_error (U.EINTR, _, _) -> Ok 0
        | U.Unix_error ((U.EAGAIN | U.EWOULDBLOCK), _, _) -> Ok (-1)
        | U.Unix_error (error, _, _) -> Error (U.error_message error)
      with
      | Error message ->
          Or_error.errorf "broker socket write failed: %s" message
      | Ok count when count > 0 -> write (offset + count)
      | Ok count when count = -1 -> (
          match wait fd ~read:false ~write:true ~deadline with
          | Some (_, true) -> write offset
          | _ -> out_of_time ())
      | Ok _ -> out_of_time ()
  in
  write 0

(** Reads one newline-terminated line up to [limit] bytes, or fails by the
    absolute deadline. Extra bytes after the first line are an error. *)
let recv_line fd ~(limit : int) ~(deadline : deadline) : string Or_error.t =
  let buffer = Buffer.create limit in
  let bytes = Bytes.create 64 in
  let rec read () =
    match String.lsplit2 (Buffer.contents buffer) ~on:'\n' with
    | Some (line, "") -> Ok line
    | Some _ -> Or_error.error_string "peer sent extra bytes after one line"
    | None -> (
        if Buffer.length buffer > limit then
          Or_error.error_string "peer exceeded the line bound"
        else if Float.(remaining deadline <= 0.) then
          Or_error.error_string "broker response timed out"
        else
          match
            try
              Ok
                (U.read fd bytes 0
                   (Int.min (Bytes.length bytes)
                      (limit + 1 - Buffer.length buffer)))
            with
            | U.Unix_error (U.EINTR, _, _) -> Ok (-1)
            | U.Unix_error ((U.EAGAIN | U.EWOULDBLOCK), _, _) -> Ok (-1)
            | U.Unix_error (error, _, _) -> Error (U.error_message error)
          with
          | Error message ->
              Or_error.errorf "broker socket read failed: %s" message
          | Ok count when count > 0 ->
              Buffer.add_subbytes buffer bytes ~pos:0 ~len:count;
              read ()
          | Ok 0 ->
              Or_error.error_string "peer closed without completing a line"
          | Ok _ -> (
              match wait fd ~read:true ~write:false ~deadline with
              | Some (true, _) -> read ()
              | _ -> Or_error.error_string "broker response timed out"))
  in
  read ()
