open Core
module U = Caml_unix

external peer_uid : U.file_descr -> int = "caml_nixploy_target_lease_peer_uid"
external fd_is_selectable : U.file_descr -> bool = "caml_nixploy_target_lease_fd_is_selectable"
external mark_dirty : string -> string -> unit = "caml_nixploy_target_lease_mark_dirty"
external clear_dirty : string -> string -> unit = "caml_nixploy_target_lease_clear_dirty"
external random_uuid : unit -> string = "caml_nixploy_target_lease_random_uuid"
external ignore_sigpipe : unit -> unit = "caml_nixploy_target_lease_ignore_sigpipe"

type scope_acl = { scope : Target_lease.uuid; allowed_uids : int list }

type configuration = {
  socket_path : string;
  state_directory : string;
  authority : Target_lease.uuid;
  identity : Target_lease.uuid;
  scope_acls : scope_acl list;
}

type mode =
  | Awaiting_acquire
  | Holding of Target_lease.request * Target_lease.uuid
  | Released

type client = {
  fd : U.file_descr;
  uid : int;
  connected_at : float;
  mutable input : string;
  mutable mode : mode;
  mutable closed : bool;
}

type received = Keep | Close | Fatal of Error.t

let max_clients = 32
let max_clients_per_uid = 4
let acquire_timeout_seconds = 5.
let response_timeout_seconds = 2.

let marker_name scope = "scope-" ^ Target_lease.uuid_to_string scope ^ ".dirty"
let now () = U.gettimeofday ()

let same_uuid left right =
  String.equal (Target_lease.uuid_to_string left) (Target_lease.uuid_to_string right)

let unique ~name values ~equal =
  let rec loop seen = function
    | [] -> Ok ()
    | value :: remaining ->
        if List.exists seen ~f:(equal value) then Or_error.errorf "%s contains duplicates" name
        else loop (value :: seen) remaining
  in
  loop [] values

let bounded_list ~name values =
  if List.is_empty values || List.length values > 32 then
    Or_error.errorf "%s must contain 1 to 32 entries" name
  else Or_error.return values

let resolve_user username =
  try Ok (U.getpwnam username).U.pw_uid
  with U.Unix_error _ -> Or_error.errorf "configured lease user %S does not exist" username

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

let create_scope_acl broker_uid (scope, users) =
  let open Or_error.Let_syntax in
  let%bind scope = Target_lease.uuid_of_string scope in
  let%bind users = bounded_list ~name:"scope users" users in
  let%bind () = unique ~name:"scope users" users ~equal:String.equal in
  let%bind allowed_uids = Or_error.all (List.map users ~f:resolve_user) in
  let%bind () = unique ~name:"resolved scope user UIDs" allowed_uids ~equal:Int.equal in
  if List.exists allowed_uids ~f:(fun uid -> uid = 0 || uid = broker_uid) then
    Or_error.error_string "a lease peer resolves to root or the broker identity"
  else Ok { scope; allowed_uids }

let create_configuration ~socket_path ~state_directory ~authority ~identity ~scope_users =
  let open Or_error.Let_syntax in
  if U.geteuid () = 0 then Or_error.error_string "target-lease broker must not run as root"
  else
    let%bind authority = Target_lease.uuid_of_string authority in
    let%bind identity = Target_lease.uuid_of_string identity in
    let%bind scope_users = bounded_list ~name:"scopes" scope_users in
    let%bind scope_acls = Or_error.all (List.map scope_users ~f:(create_scope_acl (U.geteuid ()))) in
    let%bind () =
      unique ~name:"scopes" scope_acls ~equal:(fun left right -> same_uuid left.scope right.scope)
    in
    let%bind () = validate_private_directory state_directory in
    let%map () = validate_socket_parent socket_path in
    { socket_path; state_directory; authority; identity; scope_acls }

let remove_existing_socket path =
  let rec unlink () =
    try U.unlink path; Ok () with
    | U.Unix_error (U.EINTR, _, _) -> unlink ()
    | U.Unix_error (error, _, _) -> Or_error.errorf "cannot remove old socket: %s" (U.error_message error)
  in
  try
    let status = U.lstat path in
    if not (Poly.equal status.U.st_kind U.S_SOCK) then
      Or_error.error_string "refusing to replace a non-socket path"
    else unlink ()
  with
  | U.Unix_error (U.ENOENT, _, _) -> Ok ()
  | U.Unix_error (error, _, _) -> Or_error.errorf "cannot inspect old socket: %s" (U.error_message error)

let scope_acl configuration scope =
  List.find configuration.scope_acls ~f:(fun acl -> same_uuid acl.scope scope)

let marker_exists configuration scope =
  try
    ignore (U.lstat (Filename.concat configuration.state_directory (marker_name scope)));
    true
  with
  | U.Unix_error (U.ENOENT, _, _) -> false
  | U.Unix_error _ -> true

let close client =
  if not client.closed then (
    client.closed <- true;
    try U.close client.fd with U.Unix_error _ -> ())

let rec wait_writable fd remaining =
  try
    let _, writable, _ = U.select [] [ fd ] [] remaining in
    not (List.is_empty writable)
  with U.Unix_error (U.EINTR, _, _) -> wait_writable fd remaining

let emit client response =
  let line = Target_lease.render_response response ^ "\n" in
  let deadline = now () +. response_timeout_seconds in
  let rec write offset =
    if offset = String.length line then true
    else
      try
        let count = U.write_substring client.fd line offset (String.length line - offset) in
        if count > 0 then write (offset + count) else false
      with
      | U.Unix_error (U.EINTR, _, _) -> write offset
      | U.Unix_error ((U.EAGAIN | U.EWOULDBLOCK), _, _) ->
          let remaining = deadline -. now () in
          if Float.(remaining <= 0.) || not (wait_writable client.fd remaining) then false else write offset
      | U.Unix_error _ -> false
  in
  write 0

let terminal client response =
  ignore (emit client response : bool);
  close client

let release client configuration operation receipt =
  match client.mode with
  | Holding (request, expected_receipt)
    when same_uuid request.operation operation && same_uuid expected_receipt receipt ->
      (try
         clear_dirty configuration.state_directory (marker_name request.scope);
         client.mode <- Released;
         ignore (emit client Target_lease.Released : bool);
         close client;
         Close
       with U.Unix_error (error, _, _) ->
         close client;
         Fatal (Error.createf "fatal durable clear failure: %s" (U.error_message error)))
  | _ ->
      terminal client Target_lease.Malformed;
      Close

let acquire client configuration (request : Target_lease.request) active_scopes =
  match scope_acl configuration request.scope with
  | None ->
      terminal client Target_lease.Denied;
      Close
  | Some acl when not (List.mem acl.allowed_uids client.uid ~equal:Int.equal) ->
      terminal client Target_lease.Denied;
      Close
  | Some _ when not (same_uuid request.authority configuration.authority) ->
      terminal client Target_lease.Denied;
      Close
  | Some _ when List.exists active_scopes ~f:(same_uuid request.scope) ->
      terminal client Target_lease.Busy;
      Close
  | Some _ when marker_exists configuration request.scope ->
      terminal client Target_lease.Dirty;
      Close
  | Some _ ->
      (try
         let receipt = random_uuid () |> Target_lease.uuid_of_string |> Or_error.ok_exn in
         mark_dirty configuration.state_directory (marker_name request.scope);
         client.mode <- Holding (request, receipt);
         let ready =
           Target_lease.Ready
             { authority = configuration.authority; scope = request.scope; operation = request.operation; receipt; identity = configuration.identity }
         in
         if emit client ready then Keep else (close client; Close)
       with U.Unix_error _ ->
         (* An uncertain mark is always treated as dirty and the session is terminal. *)
         terminal client Target_lease.Dirty;
         Close)

let process_line client configuration active_scopes line =
  match Target_lease.parse_client_line line with
  | Error _ ->
      terminal client Target_lease.Malformed;
      Close
  | Ok (Target_lease.Acquire request) ->
      (match client.mode with
      | Awaiting_acquire -> acquire client configuration request active_scopes
      | Holding _ | Released ->
          terminal client Target_lease.Malformed;
          Close)
  | Ok (Target_lease.Release { operation; receipt }) -> release client configuration operation receipt

let active_scopes clients =
  List.filter_map clients ~f:(fun client ->
      match client.mode with Holding (request, _) -> Some request.scope | Awaiting_acquire | Released -> None)

let receive client configuration clients =
  let bytes = Bytes.create 256 in
  try
    match U.read client.fd bytes 0 (Bytes.length bytes) with
    | 0 -> Close
    | count ->
        let input = client.input ^ Stdlib.Bytes.sub_string bytes 0 count in
        let rec consume input =
          match String.lsplit2 input ~on:'\n' with
          | None ->
              if String.length input > Target_lease.max_line_bytes then (
                terminal client Target_lease.Malformed;
                Close)
              else (
                client.input <- input;
                Keep)
          | Some (line, remainder) ->
              if String.length line > Target_lease.max_line_bytes then (
                terminal client Target_lease.Malformed;
                Close)
              else
                match process_line client configuration (active_scopes clients) line with
                | Keep when not client.closed -> consume remainder
                | result -> result
        in
        consume input
  with
  | U.Unix_error (U.EINTR, _, _) -> Keep
  | U.Unix_error ((U.EAGAIN | U.EWOULDBLOCK), _, _) -> Keep
  | U.Unix_error _ -> Close

let accept_one listener =
  try
    let fd, _ = U.accept listener in
    try
      U.set_nonblock fd;
      if not (fd_is_selectable fd) then (U.close fd; None)
      else
        Some { fd; uid = peer_uid fd; connected_at = now (); input = ""; mode = Awaiting_acquire; closed = false }
    with U.Unix_error _ ->
      (try U.close fd with U.Unix_error _ -> ());
      None
  with
  | U.Unix_error ((U.EAGAIN | U.EWOULDBLOCK), _, _) -> None
  | U.Unix_error (U.EINTR, _, _) -> None
  | U.Unix_error _ -> None

let accept_available listener clients =
  let rec accept clients =
    match accept_one listener with
    | None -> clients
    | Some client ->
        if List.length clients >= max_clients
           || List.count clients ~f:(fun existing -> existing.uid = client.uid) >= max_clients_per_uid
        then (close client; accept clients)
        else accept (client :: clients)
  in
  accept clients

let rec select_readable fds timeout =
  try U.select fds [] [] timeout with U.Unix_error (U.EINTR, _, _) -> select_readable fds timeout

let run configuration =
  let open Or_error.Let_syntax in
  let%bind () = remove_existing_socket configuration.socket_path in
  try
    ignore_sigpipe ();
    let listener = U.socket U.PF_UNIX U.SOCK_STREAM 0 in
    U.bind listener (U.ADDR_UNIX configuration.socket_path);
    U.chmod configuration.socket_path 0o660;
    U.listen listener max_clients;
    U.set_nonblock listener;
    if not (fd_is_selectable listener) then failwith "listener exceeds select fd limit";
    let clients = ref [] in
    let fatal = ref None in
    while Option.is_none !fatal do
      let readable, _, _ =
        select_readable (listener :: List.map !clients ~f:(fun client -> client.fd)) 1.0
      in
      if List.mem readable listener ~equal:Poly.equal then clients := accept_available listener !clients;
      let current_time = now () in
      clients :=
        List.filter !clients ~f:(fun client ->
            if (match client.mode with Awaiting_acquire -> Float.(current_time -. client.connected_at >= acquire_timeout_seconds) | Holding _ | Released -> false)
            then (close client; false)
            else if List.mem readable client.fd ~equal:Poly.equal then
              match receive client configuration !clients with
              | Keep -> not client.closed
              | Close -> close client; false
              | Fatal error -> fatal := Some error; false
            else not client.closed)
    done;
    List.iter !clients ~f:close;
    U.close listener;
    Error (Option.value_exn !fatal)
  with
  | U.Unix_error (error, _, _) -> Or_error.errorf "target-lease broker failed: %s" (U.error_message error)
  | exn -> Or_error.of_exn exn
