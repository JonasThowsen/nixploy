open Core
open Async
module U = Caml_unix

let authority = "11111111-2222-3333-4444-555555555555"
let identity = "12345678-1234-4234-9234-123456789abc"
let scope = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
let other_scope = "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee"
let operation = "99999999-8888-7777-6666-555555555551"
let other_operation = "99999999-8888-7777-6666-555555555552"
let other_authority = "21111111-2222-3333-4444-555555555555"
let other_identity = "22345678-1234-4234-9234-123456789abc"
let other_receipt = "31234567-1234-4234-9234-123456789abc"

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let assert_error_prefix prefix = function
  | Ok _ -> failwith ("expected " ^ prefix)
  | Error error ->
      if not (String.is_prefix (Error.to_string_hum error) ~prefix) then
        failwith (Error.to_string_hum error)

let assert_ok_deferred deferred = Deferred.map deferred ~f:assert_ok

let assert_error_prefix_deferred prefix deferred =
  Deferred.map deferred ~f:(assert_error_prefix prefix)

let counter = ref 0

type paths = { base : string; state_directory : string; socket_path : string }

let fresh_paths () =
  Int.incr counter;
  let base =
    sprintf "/tmp/nixploy-target-lease-client-%d-%d" (U.getpid ()) !counter
  in
  assert_ok (Or_error.try_with (fun () -> U.mkdir base 0o700));
  let state_directory = Filename.concat base "state" in
  assert_ok (Or_error.try_with (fun () -> U.mkdir state_directory 0o700));
  { base; state_directory; socket_path = Filename.concat base "broker.sock" }

let remove_tree path =
  ignore
    (U.system
       (sprintf "chmod -R u+w %s && rm -rf %s" (Filename.quote path)
          (Filename.quote path)))

let own_username =
  lazy
    (let passwd = U.getpwuid (U.geteuid ()) in
     if String.is_empty passwd.U.pw_name then failwith "missing test username"
     else passwd.U.pw_name)

let start_broker paths =
  let configuration =
    assert_ok
      (Nixploy.Target_lease_broker.create_configuration ~broker_uid:4242
         ~socket_path:paths.socket_path ~state_directory:paths.state_directory
         ~authority ~identity ~scope_users:[ (scope, [ Lazy.force own_username ]) ])
  in
  let result = ref None in
  let thread =
    Caml_threads.Thread.create
      (fun () ->
        result :=
          Some
            (try Nixploy.Target_lease_broker.run configuration
             with error -> Error (Error.of_exn error)))
      ()
  in
  let rec wait_socket attempts =
    if attempts = 0 then failwith "broker socket did not appear"
    else
      match U.lstat paths.socket_path with
      | _ -> ()
      | exception U.Unix_error _ ->
          Caml_threads.Thread.delay 0.02;
          wait_socket (attempts - 1)
  in
  wait_socket 100;
  ( thread,
    fun () ->
      Nixploy.Target_lease_broker.stop_flag configuration := true;
      Caml_threads.Thread.join thread )

let configuration paths ?(authority_value = authority) ?(scope_value = scope)
    ?(identity_value = identity) () =
  Nixploy.Target_lease_client.For_testing.configuration ~socket_path:paths.socket_path
    ~authority:authority_value ~scope:scope_value ~identity:identity_value
  |> assert_ok

let stop_broker paths stop =
  In_thread.run (fun () ->
      stop ();
      remove_tree paths.base)

let with_broker test =
  let paths = fresh_paths () in
  let _thread, stop = start_broker paths in
  Monitor.protect (fun () -> test paths) ~finally:(fun () -> stop_broker paths stop)

let unavailable_socket_path_test () =
  let paths = fresh_paths () in
  Monitor.protect
    (fun () ->
      let%bind () =
        assert_error_prefix_deferred "broker connection failed"
          (Nixploy.Target_lease_client.acquire (configuration paths ()) ~operation)
      in
      let _thread, stop = start_broker paths in
      Monitor.protect
        (fun () ->
          let%bind lease =
            assert_ok_deferred
              (Nixploy.Target_lease_client.acquire (configuration paths ())
                 ~operation)
          in
          assert_ok_deferred (Nixploy.Target_lease_client.release lease))
        ~finally:(fun () -> In_thread.run stop))
    ~finally:(fun () -> In_thread.run (fun () -> remove_tree paths.base))

let main () =
  let%bind () =
    with_broker (fun paths ->
        let%bind lease =
          assert_ok_deferred
            (Nixploy.Target_lease_client.acquire (configuration paths ()) ~operation)
        in
        assert_ok_deferred (Nixploy.Target_lease_client.release lease))
  in
  let%bind () =
    with_broker (fun paths ->
        assert_error_prefix_deferred "NIXPLOY_TARGET_LEASE_V1 DENIED"
          (Nixploy.Target_lease_client.acquire
             (configuration paths ~authority_value:other_authority ()) ~operation))
  in
  let%bind () =
    with_broker (fun paths ->
        assert_error_prefix_deferred "NIXPLOY_TARGET_LEASE_V1 DENIED"
          (Nixploy.Target_lease_client.acquire
             (configuration paths ~scope_value:other_scope ()) ~operation))
  in
  let%bind () =
    with_broker (fun paths ->
        assert_error_prefix_deferred "NIXPLOY_TARGET_LEASE_READY_MISMATCH"
          (Nixploy.Target_lease_client.acquire
             (configuration paths ~identity_value:other_identity ()) ~operation))
  in
  let%bind () =
    with_broker (fun paths ->
        let%bind lease =
          assert_ok_deferred
            (Nixploy.Target_lease_client.acquire (configuration paths ()) ~operation)
        in
        let%bind () =
          assert_error_prefix_deferred "NIXPLOY_TARGET_LEASE_V1 MALFORMED"
            (Nixploy.Target_lease_client.For_testing.release_with_receipt lease
               ~receipt:other_receipt)
        in
        assert_error_prefix_deferred "NIXPLOY_TARGET_LEASE_ALREADY_CLOSED"
          (Nixploy.Target_lease_client.release lease))
  in
  let%bind () =
    with_broker (fun paths ->
        let%bind first =
          assert_ok_deferred
            (Nixploy.Target_lease_client.acquire (configuration paths ()) ~operation)
        in
        let%bind () =
          assert_error_prefix_deferred "NIXPLOY_TARGET_LEASE_V1 BUSY"
            (Nixploy.Target_lease_client.acquire (configuration paths ())
               ~operation:other_operation)
        in
        assert_ok_deferred (Nixploy.Target_lease_client.release first))
  in
  unavailable_socket_path_test ()

let () =
  don't_wait_for (main ());
  never_returns (Scheduler.go ())
