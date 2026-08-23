open Core
module U = Caml_unix
module S = Nixploy.Target_lease_socket
module T = Nixploy.Target_lease_state

let authority = "11111111-2222-3333-4444-555555555555"
let identity = "12345678-1234-4234-9234-123456789abc"
let scope = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
let operation_one = "99999999-8888-7777-6666-555555555551"
let operation_two = "99999999-8888-7777-6666-555555555552"

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let assert_error result =
  if Result.is_ok result then failwith "expected an error"

let counter = ref 0

type paths = { base : string; state_directory : string; socket_path : string }

let fresh_paths () =
  Int.incr counter;
  let base =
    sprintf "/tmp/nixploy-tl-broker-test-%d-%d" (U.getpid ()) !counter
  in
  ignore (U.mkdir base 0o700);
  let state_directory = Filename.concat base "state" in
  ignore (U.mkdir state_directory 0o700);
  { base; state_directory; socket_path = Filename.concat base "broker.sock" }

let remove_tree path =
  ignore
    (U.system
       (sprintf "chmod -R u+w %s && rm -rf %s" (Filename.quote path)
          (Filename.quote path)))

(* The in-process client runs as this process's UID, so the ACL must admit it. *)
let own_username =
  lazy
    (let passwd = U.getpwuid (U.geteuid ()) in
     if String.is_empty passwd.U.pw_name then
       failwith "cannot resolve the current user for the ACL"
     else passwd.U.pw_name)

let configuration ?(scope_users = [ (scope, [ Lazy.force own_username ]) ])
    paths =
  (* The test client shares this process's UID, so the simulated broker runs
     under a distinct fake identity. *)
  assert_ok
    (Nixploy.Target_lease_broker.create_configuration ~broker_uid:4242
       ~socket_path:paths.socket_path ~state_directory:paths.state_directory
       ~authority ~identity ~scope_users)

let start_broker paths =
  let config = configuration paths in
  let result = ref None in
  let thread =
    Caml_threads.Thread.create
      (fun () ->
        match Nixploy.Target_lease_broker.run config with
        | r -> result := Some r
        | exception e -> result := Some (Error (Error.of_exn e)))
      ()
  in
  let rec wait_socket attempts =
    if attempts = 0 then ()
    else
      match U.lstat paths.socket_path with
      | _ -> ()
      | exception U.Unix_error _ ->
          Caml_threads.Thread.delay 0.02;
          wait_socket (attempts - 1)
  in
  wait_socket 100;
  let stop () = Nixploy.Target_lease_broker.stop_flag config := true in
  (thread, result, stop)

type session = { fd : U.file_descr }

let exchange_deadline () = S.now () +. 2.

let connect paths =
  let fd = U.socket U.PF_UNIX U.SOCK_STREAM 0 in
  S.connect fd (U.ADDR_UNIX paths.socket_path) ~deadline:(S.now () +. 2.)
  |> assert_ok;
  { fd }

let exchange session message =
  S.send_all session.fd
    ~data:(Nixploy.Target_lease.render_client_message message ^ "\n")
    ~deadline:(exchange_deadline ())
  |> assert_ok;
  let line =
    assert_ok
      (S.recv_line session.fd ~limit:257 ~deadline:(exchange_deadline ()))
  in
  assert_ok (Nixploy.Target_lease.parse_response_line line)

let request_of operation =
  assert_ok
    (Nixploy.Target_lease.request_of_strings ~authority ~scope ~operation)

let acquire session operation =
  exchange session (Nixploy.Target_lease.Acquire (request_of operation))

let close_session session = try U.close session.fd with U.Unix_error _ -> ()

(* Happy round trip: exact READY binding, then clean RELEASED. *)
let () =
  let paths = fresh_paths () in
  let thread, _result, stop = start_broker paths in
  let session = connect paths in
  (match acquire session operation_one with
  | Nixploy.Target_lease.Ready ready ->
      assert (
        String.equal (Nixploy.Target_lease.uuid_to_string ready.scope) scope);
      assert (
        String.equal
          (Nixploy.Target_lease.uuid_to_string ready.operation)
          operation_one);
      assert (
        String.equal
          (Nixploy.Target_lease.uuid_to_string ready.identity)
          identity);
      assert (
        String.equal
          (Nixploy.Target_lease.uuid_to_string ready.authority)
          authority);
      assert (
        not
          (String.equal
             (Nixploy.Target_lease.uuid_to_string ready.receipt)
             operation_one));
      let released =
        exchange session
          (Nixploy.Target_lease.Release
             {
               operation = (request_of operation_one).operation;
               receipt = ready.receipt;
             })
      in
      assert (Poly.equal Nixploy.Target_lease.Released released)
  | response ->
      failwith
        ("expected READY, got " ^ Nixploy.Target_lease.render_response response));
  close_session session;
  stop ();
  Caml_threads.Thread.join thread;
  remove_tree paths.base

(* A held session can still release cleanly after a long idle period. *)
let () =
  let paths = fresh_paths () in
  let thread, _result, stop = start_broker paths in
  let session = connect paths in
  let ready =
    match acquire session operation_one with
    | Nixploy.Target_lease.Ready ready -> ready
    | response ->
        failwith
          ("expected READY, got "
          ^ Nixploy.Target_lease.render_response response)
  in
  Caml_threads.Thread.delay 3.;
  let released =
    exchange session
      (Nixploy.Target_lease.Release
         {
           operation = (request_of operation_one).operation;
           receipt = ready.receipt;
         })
  in
  assert (Poly.equal Nixploy.Target_lease.Released released);
  close_session session;
  stop ();
  Caml_threads.Thread.join thread;
  remove_tree paths.base

(* A second concurrent holder is told the scope is busy. *)
let () =
  let paths = fresh_paths () in
  let thread, _result, stop = start_broker paths in
  let first = connect paths in
  let second = connect paths in
  (match acquire first operation_one with
  | Nixploy.Target_lease.Ready _ -> ()
  | response ->
      failwith
        ("expected READY, got " ^ Nixploy.Target_lease.render_response response));
  (match acquire second operation_two with
  | Nixploy.Target_lease.Busy -> ()
  | response ->
      failwith
        ("expected BUSY, got " ^ Nixploy.Target_lease.render_response response));
  close_session first;
  close_session second;
  stop ();
  Caml_threads.Thread.join thread;
  remove_tree paths.base

(* Durable dirty evidence blocks acquisition even for an allowed peer. *)
let () =
  let paths = fresh_paths () in
  let scope_uuid = assert_ok (Nixploy.Target_lease.uuid_of_string scope) in
  let generation =
    assert_ok
      (Nixploy.Target_lease.uuid_of_string
         "01234567-89ab-4cde-8fab-0123456789ab")
  in
  assert_ok
    (T.mark_dirty ~state_directory:paths.state_directory ~scope:scope_uuid
       ~generation);
  let thread, _result, stop = start_broker paths in
  let session = connect paths in
  (match acquire session operation_one with
  | Nixploy.Target_lease.Dirty -> ()
  | response ->
      failwith
        ("expected DIRTY, got " ^ Nixploy.Target_lease.render_response response));
  close_session session;
  stop ();
  Caml_threads.Thread.join thread;
  remove_tree paths.base

(* An injected durability failure during release is process-fatal: the client
   is cut off and the broker exits with an error instead of serving uncertain
   state. *)
let () =
  let paths = fresh_paths () in
  let thread, result, _stop = start_broker paths in
  let session = connect paths in
  let ready =
    match acquire session operation_one with
    | Nixploy.Target_lease.Ready ready -> ready
    | response ->
        failwith
          ("expected READY, got "
          ^ Nixploy.Target_lease.render_response response)
  in
  T.inject_failure_after 0;
  (* The broker hits the injected failure while processing the release and
     closes the connection instead of serving uncertain state. *)
  (try
     ignore
       (exchange session
          (Nixploy.Target_lease.Release
             {
               operation = (request_of operation_one).operation;
               receipt = ready.receipt;
             }))
   with U.Unix_error _ | Failure _ -> ());
  Caml_threads.Thread.join thread;
  (match !result with
  | Some (Error error) ->
      assert (
        String.is_substring
          (Error.to_string_hum error)
          ~substring:"fatal durable release failure")
  | _ -> failwith "release failure was not fatal");
  (* The interrupted release must leave fail-closed evidence: dirty, ambiguous,
     or a scan error - never clean-only. *)
  (match T.scan_directory ~state_directory:paths.state_directory with
  | Error _ -> ()
  | Ok evidence -> (
      match Map.find evidence scope with
      | Some (T.Dirty _) | Some T.Blocked -> ()
      | Some T.Clean | Some T.Unused | None ->
          remove_tree paths.base;
          failwith "failed release produced clean evidence"));
  remove_tree paths.base

(* Ambiguous durable evidence refuses startup entirely. *)
let () =
  let paths = fresh_paths () in
  let scope_uuid = assert_ok (Nixploy.Target_lease.uuid_of_string scope) in
  let generation =
    assert_ok
      (Nixploy.Target_lease.uuid_of_string
         "01234567-89ab-4cde-8fab-0123456789ab")
  in
  assert_ok
    (T.mark_dirty ~state_directory:paths.state_directory ~scope:scope_uuid
       ~generation);
  assert_ok
    (T.write_clean_receipt ~state_directory:paths.state_directory
       ~scope:scope_uuid ~generation);
  let thread, result, _stop = start_broker paths in
  Caml_threads.Thread.join thread;
  (match !result with
  | Some (Error error) ->
      assert (
        String.is_substring
          (Error.to_string_hum error)
          ~substring:"refusing to start")
  | _ -> failwith "ambiguous evidence did not refuse startup");
  remove_tree paths.base

(* Root and already-configured peers are rejected at configuration time. *)
let () =
  let paths = fresh_paths () in
  assert_error
    (Nixploy.Target_lease_broker.create_configuration ~broker_uid:4242
       ~socket_path:paths.socket_path ~state_directory:paths.state_directory
       ~authority ~identity
       ~scope_users:[ (scope, [ "root" ]) ]);
  assert_error
    (Nixploy.Target_lease_broker.create_configuration ~broker_uid:(U.geteuid ())
       ~socket_path:paths.socket_path ~state_directory:paths.state_directory
       ~authority ~identity
       ~scope_users:[ (scope, [ Lazy.force own_username ]) ]);
  remove_tree paths.base
