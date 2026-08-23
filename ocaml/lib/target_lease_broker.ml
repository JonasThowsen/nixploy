open Core
module U = Caml_unix

external peer_uid : U.file_descr -> int = "caml_nixploy_target_lease_peer_uid"

external fd_is_selectable : U.file_descr -> bool
  = "caml_nixploy_target_lease_fd_is_selectable"

external random_uuid : unit -> string = "caml_nixploy_target_lease_random_uuid"

external ignore_sigpipe : unit -> unit
  = "caml_nixploy_target_lease_ignore_sigpipe"

type scope_acl = { scope : Target_lease.uuid; allowed_uids : int list }

type configuration = {
  socket_path : string;
  state_directory : string;
  authority : Target_lease.uuid;
  identity : Target_lease.uuid;
  broker_uid : int;
  scope_acls : scope_acl list;
  stop : bool ref;
}

type mode =
  | Awaiting_acquire
  | Holding of
      Target_lease.request
      * Target_lease.uuid (* receipt *)
      * Target_lease.uuid (* generation *)
  | Released

type client = {
  fd : U.file_descr;
  uid : int;
  connected_at : float; (* CLOCK_MONOTONIC *)
  mutable input : string;
  mutable mode : mode;
  mutable closed : bool;
}

type received = Keep | Close | Fatal of Error.t

let max_clients = 32
let max_clients_per_uid = 4
let acquire_timeout_seconds = 5.
let response_timeout_seconds = 2.

(* Fixed per-iteration accept budget so a connection flood cannot starve
   existing clients, timeout sweeps, or fatal-durability handling. *)
let accept_budget_per_cycle = 8
let now () = Target_lease_socket.now ()
let deadline_in seconds = seconds +. now ()

let same_uuid left right =
  String.equal
    (Target_lease.uuid_to_string left)
    (Target_lease.uuid_to_string right)

let unique ~name values ~equal =
  let rec loop seen = function
    | [] -> Ok ()
    | value :: remaining ->
        if List.exists seen ~f:(equal value) then
          Or_error.errorf "%s contains duplicates" name
        else loop (value :: seen) remaining
  in
  loop [] values

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

let create_scope_acl broker_uid (scope, users) =
  let open Or_error.Let_syntax in
  let%bind scope = Target_lease.uuid_of_string scope in
  let%bind users = bounded_list ~name:"scope users" users in
  let%bind () = unique ~name:"scope users" users ~equal:String.equal in
  let%bind allowed_uids = Or_error.all (List.map users ~f:resolve_user) in
  let%bind () =
    unique ~name:"resolved scope user UIDs" allowed_uids ~equal:Int.equal
  in
  if List.exists allowed_uids ~f:(fun uid -> uid = 0 || uid = broker_uid) then
    Or_error.error_string "a lease peer resolves to root or the broker identity"
  else Ok { scope; allowed_uids }

let create_configuration ~broker_uid ~socket_path ~state_directory ~authority
    ~identity ~scope_users =
  let stop = ref false in
  let open Or_error.Let_syntax in
  if broker_uid = 0 || U.geteuid () = 0 then
    Or_error.error_string "target-lease broker must not run as root"
  else if
    List.exists scope_users ~f:(fun (_, users) ->
        List.exists users ~f:(fun user -> String.equal user "root"))
  then Or_error.error_string "a configured lease peer resolves to UID 0"
  else
    let%bind authority = Target_lease.uuid_of_string authority in
    let%bind identity = Target_lease.uuid_of_string identity in
    let%bind scope_users = bounded_list ~name:"scopes" scope_users in
    let%bind scope_acls =
      Or_error.all (List.map scope_users ~f:(create_scope_acl broker_uid))
    in
    let%bind () =
      unique ~name:"scopes" scope_acls ~equal:(fun left right ->
          same_uuid left.scope right.scope)
    in
    let%bind () = validate_private_directory state_directory in
    let%map () = validate_socket_parent socket_path in
    {
      socket_path;
      state_directory;
      authority;
      identity;
      broker_uid;
      scope_acls;
      stop;
    }

let stop_flag configuration = configuration.stop

let remove_existing_socket path =
  let rec unlink () =
    try
      U.unlink path;
      Ok ()
    with
    | U.Unix_error (U.EINTR, _, _) -> unlink ()
    | U.Unix_error (error, _, _) ->
        Or_error.errorf "cannot remove old socket: %s" (U.error_message error)
  in
  try
    let status = U.lstat path in
    if not (Poly.equal status.U.st_kind U.S_SOCK) then
      Or_error.error_string "refusing to replace a non-socket path"
    else unlink ()
  with
  | U.Unix_error (U.ENOENT, _, _) -> Ok ()
  | U.Unix_error (error, _, _) ->
      Or_error.errorf "cannot inspect old socket: %s" (U.error_message error)

let scope_acl configuration scope =
  List.find configuration.scope_acls ~f:(fun acl -> same_uuid acl.scope scope)

let close client =
  if not client.closed then (
    client.closed <- true;
    try U.close client.fd with U.Unix_error _ -> ())

let emit client response =
  let line = Target_lease.render_response response ^ "\n" in
  Target_lease_socket.send_all client.fd ~data:line
    ~deadline:(deadline_in response_timeout_seconds)

let terminal client response =
  ignore (emit client response : unit Or_error.t);
  close client

(* Releases one held lease.  The clean receipt is made independently durable
   before the dirty marker is retired; any failure is fatal for the process and
   never removes unclean evidence. *)
let release client configuration operation receipt =
  match client.mode with
  | Holding (request, expected_receipt, generation)
    when same_uuid request.operation operation
         && same_uuid expected_receipt receipt -> (
      let result =
        let open Or_error.Let_syntax in
        let%bind () =
          Target_lease_state.write_clean_receipt
            ~state_directory:configuration.state_directory ~scope:request.scope
            ~generation
        in
        Target_lease_state.retire_dirty
          ~state_directory:configuration.state_directory ~scope:request.scope
          ~generation
      in
      match result with
      | Ok () ->
          client.mode <- Released;
          ignore (emit client Target_lease.Released : unit Or_error.t);
          close client;
          Close
      | Error error ->
          close client;
          Fatal
            (Error.of_string
               ("fatal durable release failure; lease evidence is preserved: "
              ^ Error.to_string_hum error)))
  | _ ->
      terminal client Target_lease.Malformed;
      Close

(* A scope is blocked by startup evidence or by any dirty marker that appeared
   after startup (for example when a holder died without releasing).  An
   inspection error is fail-closed fatal. *)
let blocked_by_evidence configuration scope dirty_scopes =
  Set.mem dirty_scopes (Target_lease.uuid_to_string scope)
  ||
  match
    Target_lease_state.dirty_marker_exists
      ~state_directory:configuration.state_directory ~scope
  with
  | Ok exists -> exists
  | Error error ->
      raise_s
        [%message "cannot inspect durable lease evidence" (error : Error.t)]

let acquire client configuration (request : Target_lease.request) dirty_scopes
    ~holding_scopes =
  let busy =
    List.exists holding_scopes ~f:(fun scope -> same_uuid scope request.scope)
  in
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
  | Some _ when busy ->
      terminal client Target_lease.Busy;
      Close
  | Some _ when blocked_by_evidence configuration request.scope dirty_scopes ->
      (* Durable evidence of an unclean owner blocks every later acquire. *)
      terminal client Target_lease.Dirty;
      Close
  | Some _ -> (
      let open Or_error.Let_syntax in
      let result =
        let%bind generation =
          random_uuid () |> Target_lease.uuid_of_string
          |> Result.map_error ~f:(fun e ->
              Error.of_string
                ("random lease generation failed: " ^ Error.to_string_hum e))
        in
        let receipt =
          random_uuid () |> Target_lease.uuid_of_string
          |> Result.map_error ~f:(fun e ->
              Error.of_string
                ("random lease receipt failed: " ^ Error.to_string_hum e))
        in
        let%bind receipt = receipt in
        (* Retire any stale receipt from a prior completed lease before the
           new dirty marker exists. *)
        let%bind () =
          Target_lease_state.clear_clean_receipt
            ~state_directory:configuration.state_directory ~scope:request.scope
        in
        let%bind () =
          Target_lease_state.mark_dirty
            ~state_directory:configuration.state_directory ~scope:request.scope
            ~generation
        in
        Ok (receipt, generation)
      in
      match result with
      | Error error ->
          close client;
          Fatal
            (Error.of_string
               ("fatal durable acquisition failure; lease evidence is \
                 preserved: " ^ Error.to_string_hum error))
      | Ok (receipt, generation) -> (
          client.mode <- Holding (request, receipt, generation);
          let ready =
            Target_lease.Ready
              {
                authority = configuration.authority;
                scope = request.scope;
                operation = request.operation;
                receipt;
                identity = configuration.identity;
              }
          in
          match emit client ready with
          | Ok () -> Keep
          | Error _ ->
              close client;
              Close))

let process_line client configuration dirty_scopes holding_scopes line =
  match Target_lease.parse_client_line line with
  | Error _ ->
      terminal client Target_lease.Malformed;
      Close
  | Ok (Target_lease.Acquire request) -> (
      match client.mode with
      | Awaiting_acquire ->
          acquire client configuration request dirty_scopes ~holding_scopes
      | Holding _ | Released ->
          terminal client Target_lease.Malformed;
          Close)
  | Ok (Target_lease.Release { operation; receipt }) ->
      release client configuration operation receipt

let holding_scopes clients =
  List.filter_map clients ~f:(fun client ->
      match client.mode with
      | Holding ({ scope; _ }, _, _) -> Some scope
      | Awaiting_acquire | Released -> None)

let receive client configuration dirty_scopes holding_scopes =
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
          | Some (line, remainder) -> (
              if String.length line > Target_lease.max_line_bytes then (
                terminal client Target_lease.Malformed;
                Close)
              else
                match
                  process_line client configuration dirty_scopes holding_scopes
                    line
                with
                | Keep when not client.closed -> consume remainder
                | result -> result)
        in
        consume input
  with
  | U.Unix_error (U.EINTR, _, _) -> Keep
  | U.Unix_error ((U.EAGAIN | U.EWOULDBLOCK), _, _) -> Keep
  | U.Unix_error _ -> Close

(* Admits at most one pending connection.  Root peers are refused outright. *)
let accept_one configuration listener =
  match U.accept listener with
  | fd, _ -> (
      try
        U.set_nonblock fd;
        if not (fd_is_selectable fd) then (
          U.close fd;
          None)
        else
          let uid = peer_uid fd in
          if uid = 0 || uid = configuration.broker_uid then (
            U.close fd;
            None)
          else
            Some
              {
                fd;
                uid;
                connected_at = now ();
                input = "";
                mode = Awaiting_acquire;
                closed = false;
              }
      with U.Unix_error _ ->
        (try U.close fd with U.Unix_error _ -> ());
        None)
  | exception U.Unix_error ((U.EAGAIN | U.EWOULDBLOCK), _, _) -> None
  | exception U.Unix_error (U.EINTR, _, _) -> None
  | exception U.Unix_error _ -> None

let select_readable fds timeout = U.select fds [] [] timeout

(* [select] may return fresh descriptors whose polymorphic equality is
   unreliable; compare underlying integers instead. *)
let same_fd left right =
  Int.equal
    (Core_unix.File_descr.to_int left)
    (Core_unix.File_descr.to_int right)

let fd_in fds fd = List.exists fds ~f:(same_fd fd)
let same_client left right = same_fd left.fd right.fd

(* Admits pending connections up to a fixed per-cycle budget and the global /
   per-UID connection caps. *)
let accept_bounded configuration listener clients =
  let rec loop budget =
    if budget <= 0 then ()
    else
      match accept_one configuration listener with
      | None -> ()
      | Some new_client ->
          if
            List.length !clients >= max_clients
            || List.count !clients ~f:(fun existing ->
                   existing.uid = new_client.uid)
               >= max_clients_per_uid
          then close new_client
          else clients := new_client :: !clients;
          loop (budget - 1)
  in
  loop accept_budget_per_cycle

(* Runs until an operational or durable-state failure.  Startup refuses to
   serve at all when durable evidence is corrupt, ambiguous (dirty marker and
   clean receipt both present), or otherwise fails closed.  Any durability
   error while serving is process-fatal in the same select-loop cycle: no
   further accepts or dispatch happen before exit. *)
exception Stop_normal

let run configuration =
  let open Or_error.Let_syntax in
  let%bind evidence =
    Target_lease_state.scan_directory
      ~state_directory:configuration.state_directory
  in
  let%bind () =
    if Target_lease_state.has_blocked evidence then
      Or_error.error_string
        "refusing to start: ambiguous durable ownership evidence (dirty marker \
         and clean receipt both present)"
    else Ok ()
  in
  let dirty_scopes =
    Set.of_list
      (module String)
      (List.map ~f:Target_lease.uuid_to_string
         (Target_lease_state.dirty_scopes evidence))
  in
  let%bind () = remove_existing_socket configuration.socket_path in
  ignore_sigpipe ();
  let listener = ref None in
  try
    let listening_socket = U.socket U.PF_UNIX U.SOCK_STREAM 0 in
    listener := Some listening_socket;
    U.bind listening_socket (U.ADDR_UNIX configuration.socket_path);
    U.chmod configuration.socket_path 0o660;
    U.listen listening_socket max_clients;
    U.set_nonblock listening_socket;
    if not (fd_is_selectable listening_socket) then
      failwith "listener exceeds select fd limit";
    let clients = ref [] in
    let fatal = ref None in
    let rec cycle () =
      if !(configuration.stop) then raise Stop_normal
      else if Option.is_some !fatal then ()
      else begin
        let readable, _, _ =
          select_readable
            (listening_socket :: List.map !clients ~f:(fun client -> client.fd))
            1.0
        in
        (* Bounded accepts per cycle; a connection flood waits in the backlog
           instead of starving existing clients, timers, or fatal handling. *)
        if fd_in readable listening_socket then
          accept_bounded configuration listening_socket clients;
        (* Timeout sweep first so idle sessions cannot starve behind dispatch. *)
        let current_time = now () in
        clients :=
          List.filter !clients ~f:(fun client ->
              let expired =
                match client.mode with
                | Awaiting_acquire ->
                    Float.(
                      current_time -. client.connected_at
                      >= acquire_timeout_seconds)
                | Holding _ | Released -> false
              in
              if expired || client.closed then (
                close client;
                false)
              else true);
        (* One dispatch pass; a fatal durability error aborts the rest of this
           cycle immediately. *)
        List.iter !clients ~f:(fun client ->
            if
              (not client.closed) && fd_in readable client.fd
              && Option.is_none !fatal
            then
              match
                receive client configuration dirty_scopes
                  (holding_scopes !clients)
              with
              | Keep -> ()
              | Close ->
                  clients :=
                    List.filter !clients ~f:(fun other ->
                        not (same_client other client));
                  close client
              | Fatal error ->
                  clients :=
                    List.filter !clients ~f:(fun other ->
                        not (same_client other client));
                  close client;
                  fatal := Some error);
        cycle ()
      end
    in
    try
      cycle ();
      Error (Option.value_exn !fatal)
    with
    | Stop_normal ->
        List.iter !clients ~f:close;
        (match !listener with
        | Some fd -> ( try U.close fd with U.Unix_error _ -> ())
        | None -> ());
        Ok ()
    | exn ->
        (match !fatal with
        | None -> fatal := Some (Error.of_exn ~backtrace:`Get exn)
        | Some _ -> ());
        List.iter !clients ~f:close;
        (match !listener with
        | Some fd -> ( try U.close fd with U.Unix_error _ -> ())
        | None -> ());
        Error (Option.value_exn !fatal)
  with
  | U.Unix_error (error, _, _) ->
      (match !listener with
      | Some fd -> ( try U.close fd with U.Unix_error _ -> ())
      | None -> ());
      Or_error.errorf "target-lease broker failed: %s" (U.error_message error)
  | exn ->
      (match !listener with
      | Some fd -> ( try U.close fd with U.Unix_error _ -> ())
      | None -> ());
      Or_error.of_exn exn
