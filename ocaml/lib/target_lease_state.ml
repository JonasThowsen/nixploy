open Core
module U = Caml_unix

external inject_failure_after : int -> unit
  = "caml_nixploy_target_lease_inject_failure_after"

external clear_clean_receipt_stub : string -> string -> unit
  = "caml_nixploy_target_lease_clear_clean_receipt"

external mark_dirty_stub : string -> string -> string -> unit
  = "caml_nixploy_target_lease_mark_dirty"

external write_clean_receipt_stub : string -> string -> string -> unit
  = "caml_nixploy_target_lease_write_clean_receipt"

external retire_dirty_stub : string -> string -> string -> unit
  = "caml_nixploy_target_lease_retire_dirty"

(* Durable per-scope ownership evidence.

   State machine for one coordination scope:

     Absent --mark_dirty--> Dirty --write_clean_receipt--> Receipted
     Receipted --retire_dirty--> Clean

   Filesystem encoding inside the broker-private, 0700 state directory:

     scope-<scope>.dirty  contains exactly "dirty <generation>\n"
     scope-<scope>.clean  contains exactly "clean <generation>\n"

   Invariants:

   - The dirty marker is created before a lease is granted and is never
     removed or overwritten except by [retire_dirty] with the exact matching
     generation, after an independently durable clean receipt exists.
   - Every creation step is file-fsynced and directory-fsynced before the next
     step begins.  Any failure reports an error and leaves all existing files
     untouched; no path ever deletes or rewrites the only evidence of possibly
     unclean ownership.
   - After a crash the observable states are exactly:
       neither file        Unused (no lease was durably granted)
       dirty only          Dirty  (unclean owner; acquire is refused)
       clean only          Clean  (release completed durably)
       both files          Blocked(uncertain; the broker must refuse to start)
     A lost directory fsync can only converge between these states, and none
     of them misrepresents uncertainty as clean.
   - Startup must reject any other filename, any non-regular or foreign-owned
     entry, any malformed or partial contents, and any Blocked scope. *)

type scope_evidence =
  | Unused
  | Clean
  | Dirty of Target_lease.uuid (* generation *)
  | Blocked

let max_entry_bytes = 64
let marker_base scope = "scope-" ^ Target_lease.uuid_to_string scope
let dirty_marker_name scope = marker_base scope ^ ".dirty"
let clean_receipt_name scope = marker_base scope ^ ".clean"

type kind = Dirty_file | Clean_file

type pair = {
  dirty : Target_lease.uuid option;
  clean : Target_lease.uuid option;
}

(* Pure parser: returns the file kind and its generation UUID. *)
let parse_evidence_line line =
  let open Or_error.Let_syntax in
  if String.length line > max_entry_bytes then
    Or_error.error_string "state entry is too long"
  else if not (String.is_suffix line ~suffix:"\n") then
    Or_error.error_string "state entry is truncated"
  else
    match String.lsplit2 (String.drop_suffix line 1) ~on:' ' with
    | Some ("dirty", generation) ->
        let%map generation = Target_lease.uuid_of_string generation in
        (Dirty_file, generation)
    | Some ("clean", generation) ->
        let%map generation = Target_lease.uuid_of_string generation in
        (Clean_file, generation)
    | _ -> Or_error.error_string "malformed state entry contents"

(* Pure classification over optional validated generations. *)
let classify_scope ~dirty ~clean =
  match (dirty, clean) with
  | None, None -> Unused
  | Some generation, None -> Dirty generation
  | None, Some _ -> Clean
  | Some _, Some _ -> Blocked

let read_entry_contents path =
  try
    let status = U.lstat path in
    if not (Poly.equal status.U.st_kind U.S_REG) then
      Or_error.error_string "state entry is not a regular file"
    else if status.U.st_uid <> U.geteuid () then
      Or_error.error_string "state entry is not owned by the broker"
    else if status.U.st_size > max_entry_bytes then
      Or_error.error_string "state entry is too large"
    else
      try
        let ic = U.in_channel_of_descr (U.openfile path [ U.O_RDONLY ] 0) in
        Exn.protect
          ~f:(fun () ->
            let contents = In_channel.input_all ic in
            Ok contents)
          ~finally:(fun () -> In_channel.close ic)
      with U.Unix_error (error, _, _) ->
        Or_error.errorf "cannot read state entry: %s" (U.error_message error)
  with
  | U.Unix_error (U.ENOENT, _, _) ->
      Or_error.error_string "state entry disappeared"
  | U.Unix_error (error, _, _) ->
      Or_error.errorf "cannot inspect state entry: %s" (U.error_message error)

(* Parses one raw filename into (scope, kind), rejecting everything else. *)
let split_entry_name name =
  let uuid_of = function Ok uuid -> Some uuid | Error _ -> None in
  if
    String.is_prefix name ~prefix:"scope-"
    && String.is_suffix name ~suffix:".dirty"
  then
    Option.map
      ~f:(fun scope -> (scope, Dirty_file))
      (uuid_of
         (Target_lease.uuid_of_string
            (String.slice name 6 (String.length name - 6))))
  else if
    String.is_prefix name ~prefix:"scope-"
    && String.is_suffix name ~suffix:".clean"
  then
    Option.map
      ~f:(fun scope -> (scope, Clean_file))
      (uuid_of
         (Target_lease.uuid_of_string
            (String.slice name 6 (String.length name - 6))))
  else None

let scan_directory ~state_directory =
  let open Or_error.Let_syntax in
  let%bind names =
    try
      let handle = U.opendir state_directory in
      let rec collect acc =
        match U.readdir handle with
        | exception End_of_file -> List.rev acc
        | "." | ".." -> collect acc
        | name -> collect (name :: acc)
      in
      let names = collect [] in
      U.closedir handle;
      Ok names
    with U.Unix_error (error, _, _) ->
      Or_error.errorf "cannot read durable state directory: %s"
        (U.error_message error)
  in
  let%bind entries =
    Or_error.all
      (List.map names ~f:(fun name ->
           match split_entry_name name with
           | None -> Or_error.errorf "unexpected durable state entry %S" name
           | Some (scope, kind) ->
               let%bind contents =
                 read_entry_contents (Filename.concat state_directory name)
               in
               let%bind parsed_kind, generation =
                 parse_evidence_line contents
               in
               if Poly.equal parsed_kind kind then
                 Ok (Target_lease.uuid_to_string scope, (kind, generation))
               else
                 Or_error.errorf "state entry %S does not match its contents"
                   name))
  in
  let%map grouped =
    List.fold entries ~init:(Ok String.Map.empty)
      ~f:(fun accumulator (scope, (kind, generation)) ->
        let%bind map = accumulator in
        let existing =
          Option.value (Map.find map scope)
            ~default:{ dirty = None; clean = None }
        in
        let merged =
          match kind with
          | Dirty_file -> { existing with dirty = Some generation }
          | Clean_file -> { existing with clean = Some generation }
        in
        Ok (Map.set map ~key:scope ~data:merged))
  in
  Map.map grouped ~f:(fun pair ->
      classify_scope ~dirty:pair.dirty ~clean:pair.clean)

module Evidence_map = Map.Make (String)

let has_blocked evidence =
  Map.exists evidence ~f:(function Blocked -> true | _ -> false)

let dirty_scopes evidence =
  Map.filter evidence ~f:(function Dirty _ -> true | _ -> false)
  |> Map.keys
  |> List.map ~f:(fun scope ->
      Or_error.ok_exn (Target_lease.uuid_of_string scope))

(* Acquiring a scope first durably retires any stale clean receipt from the
   previous completed lease, so a fresh dirty marker can never coexist with old
   clean evidence. *)
let clear_clean_receipt ~state_directory ~scope =
  try Ok (clear_clean_receipt_stub state_directory (marker_base scope)) with
  | U.Unix_error (error, operation, _argument) ->
      Or_error.errorf "durable clean-retirement failed (%s): %s" operation
        (U.error_message error)
  | exn -> Or_error.of_exn exn

let dirty_marker_exists ~state_directory ~scope =
  match U.lstat (Filename.concat state_directory (dirty_marker_name scope)) with
  | status ->
      if Poly.equal status.U.st_kind U.S_REG then Ok true
      else Or_error.error_string "dirty marker is not a regular file"
  | exception U.Unix_error (U.ENOENT, _, _) -> Ok false
  | exception U.Unix_error (error, _, _) ->
      Or_error.errorf "cannot inspect dirty marker: %s" (U.error_message error)

let mark_dirty ~state_directory ~scope ~generation =
  try
    Ok
      (mark_dirty_stub state_directory (dirty_marker_name scope)
         (Target_lease.uuid_to_string generation))
  with
  | U.Unix_error (error, operation, _argument) ->
      Or_error.errorf "durable dirty marker failed (%s): %s" operation
        (U.error_message error)
  | exn -> Or_error.of_exn exn

let write_clean_receipt ~state_directory ~scope ~generation =
  try
    Ok
      (write_clean_receipt_stub state_directory (marker_base scope)
         (Target_lease.uuid_to_string generation))
  with
  | U.Unix_error (error, operation, _argument) ->
      Or_error.errorf "durable clean receipt failed (%s): %s" operation
        (U.error_message error)
  | exn -> Or_error.of_exn exn

let retire_dirty ~state_directory ~scope ~generation =
  try
    Ok
      (retire_dirty_stub state_directory (dirty_marker_name scope)
         (Target_lease.uuid_to_string generation))
  with
  | U.Unix_error (error, operation, _argument) ->
      Or_error.errorf "durable dirty retirement failed (%s): %s" operation
        (U.error_message error)
  | exn -> Or_error.of_exn exn
