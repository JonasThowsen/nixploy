open Core
module U = Caml_unix
module S = Nixploy.Target_lease_socket

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let assert_error result =
  if Result.is_ok result then failwith "expected an error"

let close_quietly fd = try U.close fd with U.Unix_error _ -> ()

(* A listener that never accepts: connections complete via the backlog, but no
   response ever arrives. *)
let () =
  let listener = U.socket U.PF_UNIX U.SOCK_STREAM 0 in
  let path = sprintf "/tmp/nixploy-tl-socket-test-%d" (U.getpid ()) in
  (try U.unlink path with U.Unix_error _ -> ());
  Exn.protect
    ~f:(fun () ->
      U.bind listener (U.ADDR_UNIX path);
      U.listen listener 4;
      let client = U.socket U.PF_UNIX U.SOCK_STREAM 0 in
      (* Connect to a path that does not exist fails promptly and boundedly. *)
      let missing = path ^ "-missing" in
      assert_error
        (S.connect client (U.ADDR_UNIX missing) ~deadline:(S.now () +. 1.));
      (* Nonblocking connect against the live listener succeeds within one
         absolute deadline and verifies SO_ERROR. *)
      S.connect client (U.ADDR_UNIX path) ~deadline:(S.now () +. 2.)
      |> assert_ok;
      (* A small write completes; a read from a silent peer hits the absolute
         deadline instead of blocking forever. *)
      S.send_all client ~data:"V1 PING\n" ~deadline:(S.now () +. 2.)
      |> assert_ok;
      let started = S.now () in
      let result = S.recv_line client ~limit:256 ~deadline:(started +. 0.5) in
      let elapsed = S.now () -. started in
      assert_error result;
      assert (Float.(elapsed >= 0.45) && Float.(elapsed <= 3.0));
      close_quietly client)
    ~finally:(fun () ->
      close_quietly listener;
      try U.unlink path with U.Unix_error _ -> ())

(* Connected sockets exchange exactly one bounded line; extra bytes are an
   error. *)
let () =
  let a, b = U.socketpair U.PF_UNIX U.SOCK_STREAM 0 in
  S.send_all a ~data:"V1 BUSY\n" ~deadline:(S.now () +. 2.) |> assert_ok;
  assert (
    String.equal "V1 BUSY"
      (assert_ok (S.recv_line b ~limit:256 ~deadline:(S.now () +. 2.))));
  S.send_all a ~data:"V1 BUSY\ntrailing" ~deadline:(S.now () +. 2.) |> assert_ok;
  assert_error (S.recv_line b ~limit:256 ~deadline:(S.now () +. 2.));
  (* Over-long lines exceed the bound even when newline-terminated. *)
  S.send_all a ~data:(String.make 300 'x' ^ "\n") ~deadline:(S.now () +. 2.)
  |> assert_ok;
  assert_error (S.recv_line b ~limit:256 ~deadline:(S.now () +. 2.));
  close_quietly a;
  close_quietly b;
  (* EOF without a completed line is an explicit error, not a hang. *)
  let c, d = U.socketpair U.PF_UNIX U.SOCK_STREAM 0 in
  S.send_all c ~data:"half lin" ~deadline:(S.now () +. 2.) |> assert_ok;
  close_quietly c;
  assert_error (S.recv_line d ~limit:256 ~deadline:(S.now () +. 2.));
  close_quietly d

(* An expired absolute deadline rejects work immediately rather than waiting a
   fresh relative timeout. *)
let () =
  let a, b = U.socketpair U.PF_UNIX U.SOCK_STREAM 0 in
  let expired = S.now () -. 1. in
  let started = S.now () in
  assert_error (S.send_all a ~data:"late\n" ~deadline:expired);
  assert_error (S.recv_line b ~limit:256 ~deadline:expired);
  assert (Float.(S.now () -. started < 0.5));
  close_quietly a;
  close_quietly b
