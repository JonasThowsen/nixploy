open Core
module U = Caml_unix

external peer_uid : U.file_descr -> int = "caml_nixploy_target_lease_peer_uid"

external mark_dirty : string -> string -> unit
  = "caml_nixploy_target_lease_mark_dirty"

external clear_dirty : string -> string -> unit
  = "caml_nixploy_target_lease_clear_dirty"

type configuration = {
  socket_path : string;
  state_directory : string;
  authority : Target_lease.uuid;
  scopes : Target_lease.uuid list;
  allowed_uids : int list;
}

type mode =
  | Awaiting_acquire
  | Holding of Target_lease.request * Target_lease.uuid
  | Released

type client = {
  fd : U.file_descr;
  uid : int;
  mutable input : string;
  mutable mode : mode;
  mutable closed : bool;
}

let marker_name scope = "scope-" ^ Target_lease.uuid_to_string scope ^ ".dirty"

let same_uuid left right =
  String.equal
    (Target_lease.uuid_to_string left)
    (Target_lease.uuid_to_string right)

let bounded_list ~name values =
  if List.is_empty values || List.length values > 32 then
    Or_error.errorf "%s must contain 1 to 32 entries" name
  else Or_error.return values

let resolve_user username =
  try Ok (U.getpwnam username).U.pw_uid
  with U.Unix_error _ ->
    Or_error.errorf "configured lease user %S does not exist" username

let validate_private_directory path =
  try
    let status = U.lstat path in
    if not (Poly.equal status.U.st_kind U.S_DIR) then
      Or_error.error_string "state directory is not a directory"
    else if status.U.st_uid <> U.geteuid () then
      Or_error.error_string "state directory is not owned by the broker"
    else if status.U.st_perm land 0o077 <> 0 then
      Or_error.error_string "state directory permits group or other access"
    else Ok ()
  with U.Unix_error (error, _, _) ->
    Or_error.errorf "cannot inspect state directory: %s" (U.error_message error)

let validate_socket_parent path =
  try
    let status = U.lstat (Filename.dirname path) in
    if not (Poly.equal status.U.st_kind U.S_DIR) then
      Or_error.error_string "socket parent is not a directory"
    else if status.U.st_perm land 0o022 <> 0 then
      Or_error.error_string "socket parent is writable by clients"
    else Ok ()
  with U.Unix_error (error, _, _) ->
    Or_error.errorf "cannot inspect socket parent: %s" (U.error_message error)

let create_configuration ~socket_path ~state_directory ~authority ~scopes
    ~allowed_users =
  let open Or_error.Let_syntax in
  let%bind authority = Target_lease.uuid_of_string authority in
  let%bind scopes =
    Or_error.all (List.map scopes ~f:Target_lease.uuid_of_string)
  in
  let%bind scopes = bounded_list ~name:"scopes" scopes in
  let%bind allowed_users = bounded_list ~name:"allowed users" allowed_users in
  let%bind allowed_uids =
    Or_error.all (List.map allowed_users ~f:resolve_user)
  in
  let%bind () = validate_private_directory state_directory in
  let%map () = validate_socket_parent socket_path in
  { socket_path; state_directory; authority; scopes; allowed_uids }

let remove_existing_socket path =
  try
    let status = U.lstat path in
    if not (Poly.equal status.U.st_kind U.S_SOCK) then
      Or_error.error_string "refusing to replace a non-socket path"
    else (
      U.unlink path;
      Ok ())
  with
  | U.Unix_error (U.ENOENT, _, _) -> Ok ()
  | U.Unix_error (error, _, _) ->
      Or_error.errorf "cannot remove old socket: %s" (U.error_message error)

let scope_is_configured configuration scope =
  List.exists configuration.scopes ~f:(same_uuid scope)

let uid_is_allowed configuration uid =
  List.mem configuration.allowed_uids uid ~equal:Int.equal

let marker_exists configuration scope =
  try
    ignore
      (U.lstat
         (Filename.concat configuration.state_directory (marker_name scope)));
    true
  with
  | U.Unix_error (U.ENOENT, _, _) -> false
  | U.Unix_error _ -> true

let emit client response =
  let line = Target_lease.render_response response ^ "\n" in
  try ignore (U.write_substring client.fd line 0 (String.length line) : int)
  with U.Unix_error _ -> ()

let close client =
  if not client.closed then (
    client.closed <- true;
    try U.close client.fd with U.Unix_error _ -> ())

let release client configuration operation receipt =
  match client.mode with
  | Holding (request, expected_receipt)
    when same_uuid request.operation operation
         && same_uuid expected_receipt receipt -> (
      try
        clear_dirty configuration.state_directory (marker_name request.scope);
        client.mode <- Released;
        emit client Target_lease.Released
      with U.Unix_error _ -> close client)
  | _ -> close client

let acquire client configuration (request : Target_lease.request) active_scopes
    =
  if not (uid_is_allowed configuration client.uid) then
    emit client Target_lease.Denied
  else if
    (not (same_uuid request.authority configuration.authority))
    || not (scope_is_configured configuration request.scope)
  then emit client Target_lease.Denied
  else if List.exists active_scopes ~f:(same_uuid request.scope) then
    emit client Target_lease.Busy
  else if marker_exists configuration request.scope then
    emit client Target_lease.Dirty
  else
    try
      (* The marker is durable before READY makes mutation eligible. *)
      mark_dirty configuration.state_directory (marker_name request.scope);
      client.mode <- Holding (request, request.operation);
      emit client (Target_lease.Ready request.operation)
    with U.Unix_error _ ->
      (* A pre-existing or unwriteable marker can never be treated as available. *)
      emit client Target_lease.Dirty;
      close client

let process_line client configuration active_scopes line =
  match Target_lease.parse_client_line line with
  | Error _ ->
      emit client Target_lease.Malformed;
      close client
  | Ok (Target_lease.Acquire request) -> (
      match client.mode with
      | Awaiting_acquire -> acquire client configuration request active_scopes
      | Holding _ | Released ->
          emit client Target_lease.Malformed;
          close client)
  | Ok (Target_lease.Release { operation; receipt }) ->
      release client configuration operation receipt

let active_scopes clients =
  List.filter_map clients ~f:(fun client ->
      match client.mode with
      | Holding (request, _) -> Some request.scope
      | Awaiting_acquire | Released -> None)

let receive client configuration clients =
  let bytes = Bytes.create 256 in
  try
    match U.read client.fd bytes 0 (Bytes.length bytes) with
    | 0 -> `Close
    | count -> (
        let input = client.input ^ Stdlib.Bytes.sub_string bytes 0 count in
        if String.length input > Target_lease.max_line_bytes then `Close
        else
          match String.lsplit2 input ~on:'\n' with
          | None ->
              client.input <- input;
              `Keep
          | Some (line, remainder) ->
              if String.is_empty remainder then (
                process_line client configuration (active_scopes clients) line;
                `Keep)
              else `Close)
  with
  | U.Unix_error ((U.EAGAIN | U.EWOULDBLOCK), _, _) -> `Keep
  | U.Unix_error _ -> `Close

let accept_one listener =
  try
    let fd, _ = U.accept listener in
    U.set_nonblock fd;
    Some
      {
        fd;
        uid = peer_uid fd;
        input = "";
        mode = Awaiting_acquire;
        closed = false;
      }
  with U.Unix_error _ -> None

let run configuration =
  let open Or_error.Let_syntax in
  let%bind () = remove_existing_socket configuration.socket_path in
  try
    let listener = U.socket U.PF_UNIX U.SOCK_STREAM 0 in
    U.bind listener (U.ADDR_UNIX configuration.socket_path);
    U.chmod configuration.socket_path 0o660;
    U.listen listener 32;
    U.set_nonblock listener;
    let clients = ref [] in
    while true do
      let readable, _, _ =
        U.select
          (listener :: List.map !clients ~f:(fun client -> client.fd))
          [] [] 1.0
      in
      if List.mem readable listener ~equal:Poly.equal then
        Option.iter (accept_one listener) ~f:(fun client ->
            clients := client :: !clients);
      let retained =
        List.filter !clients ~f:(fun client ->
            if List.mem readable client.fd ~equal:Poly.equal then (
              match receive client configuration !clients with
              | `Keep -> not client.closed
              | `Close ->
                  close client;
                  false)
            else not client.closed)
      in
      clients := retained
    done;
    assert false
  with U.Unix_error (error, _, _) ->
    Or_error.errorf "target-lease broker failed: %s" (U.error_message error)
