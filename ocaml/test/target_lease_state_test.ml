open Core
module U = Caml_unix
module S = Nixploy.Target_lease_state

let scope = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
let generation = "01234567-89ab-4cde-8fab-0123456789ab"
let other_generation = "01234567-89ab-4cde-8fab-0123456789ac"
let scope_uuid = Or_error.ok_exn (Nixploy.Target_lease.uuid_of_string scope)
let gen_uuid = Or_error.ok_exn (Nixploy.Target_lease.uuid_of_string generation)

let other_gen_uuid =
  Or_error.ok_exn (Nixploy.Target_lease.uuid_of_string other_generation)

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let assert_error result =
  if Result.is_ok result then failwith "expected an error"

let counter = ref 0

let fresh_dir () =
  Int.incr counter;
  let path =
    Filename.concat "/tmp"
      (sprintf "nixploy-tl-state-test-%d-%d" (U.getpid ()) !counter)
  in
  ignore (U.mkdir path 0o700);
  path

let remove_dir path =
  ignore
    (U.system
       (sprintf "chmod -R u+w %s && rm -rf %s" (Filename.quote path)
          (Filename.quote path)))

(* Ok evidence for the test scope, Error when the directory fails closed. *)
let outcome path =
  match S.scan_directory ~state_directory:path with
  | Error _ -> `Fail_closed
  | Ok evidence -> (
      match Map.find evidence scope with
      | Some item -> `Evidence item
      | None -> `Evidence S.Unused)

(* Every injected failure must leave dirty, blocked, or fail-closed state:
   never a clean scope. *)
let expect_never_clean path description =
  match outcome path with
  | `Fail_closed -> ()
  | `Evidence (S.Dirty _) | `Evidence S.Blocked | `Evidence S.Unused -> ()
  | `Evidence S.Clean ->
      remove_dir path;
      failwith ("invariant violated: clean state observed after " ^ description)

let mark path =
  assert_ok
    (S.mark_dirty ~state_directory:path ~scope:scope_uuid ~generation:gen_uuid)

let receipt path =
  assert_ok
    (S.write_clean_receipt ~state_directory:path ~scope:scope_uuid
       ~generation:gen_uuid)

let retire path =
  assert_ok
    (S.retire_dirty ~state_directory:path ~scope:scope_uuid ~generation:gen_uuid)

(* Pure parser and classification coverage. *)
let () =
  assert (
    Poly.equal
      (Ok (S.Dirty_file, gen_uuid))
      (S.parse_evidence_line ("dirty " ^ generation ^ "\n")));
  assert (
    Poly.equal
      (Ok (S.Clean_file, gen_uuid))
      (S.parse_evidence_line ("clean " ^ generation ^ "\n")));
  assert_error (S.parse_evidence_line ("dirty " ^ generation));
  assert_error (S.parse_evidence_line ("dirty " ^ generation ^ "\n\n"));
  assert_error (S.parse_evidence_line ("DIRTY " ^ generation ^ "\n"));
  assert_error (S.parse_evidence_line "dirty\n");
  assert_error (S.parse_evidence_line "");
  assert_error (S.parse_evidence_line (String.make (S.max_entry_bytes + 1) 'x'));
  assert (Poly.equal S.Unused (S.classify_scope ~dirty:None ~clean:None));
  (match S.classify_scope ~dirty:(Some gen_uuid) ~clean:None with
  | S.Dirty g ->
      assert (String.equal (Nixploy.Target_lease.uuid_to_string g) generation)
  | _ -> failwith "expected Dirty");
  (match S.classify_scope ~dirty:None ~clean:(Some gen_uuid) with
  | S.Clean -> ()
  | _ -> failwith "expected Clean");
  match
    S.classify_scope ~dirty:(Some gen_uuid) ~clean:(Some other_gen_uuid)
  with
  | S.Blocked -> ()
  | _ -> failwith "expected Blocked"

(* Happy path: absent -> dirty -> receipted -> clean; re-release is idempotent. *)
let () =
  let path = fresh_dir () in
  assert (Poly.equal (`Evidence S.Unused) (outcome path));
  mark path;
  assert (
    match outcome path with
    | `Evidence (S.Dirty g) ->
        String.equal (Nixploy.Target_lease.uuid_to_string g) generation
    | _ -> false);
  receipt path;
  retire path;
  assert (Poly.equal (`Evidence S.Clean) (outcome path));
  mark path;
  receipt path;
  retire path;
  assert (Poly.equal (`Evidence S.Clean) (outcome path));
  remove_dir path

(* Fault injection during the initial dirty marker must never produce a clean
   scope and never delete partial evidence. *)
let () =
  List.iter [ 0; 1; 2 ] ~f:(fun fault_point ->
      let path = fresh_dir () in
      S.inject_failure_after fault_point;
      assert_error
        (S.mark_dirty ~state_directory:path ~scope:scope_uuid
           ~generation:gen_uuid);
      expect_never_clean path (sprintf "mark_dirty fault at %d" fault_point);
      remove_dir path)

(* Fault injection while writing the clean receipt keeps the dirty marker or
   produces blocked ambiguity - never a clean scope while retiring. *)
let () =
  List.iter [ 0; 1; 2 ] ~f:(fun fault_point ->
      let path = fresh_dir () in
      mark path;
      S.inject_failure_after fault_point;
      assert_error
        (S.write_clean_receipt ~state_directory:path ~scope:scope_uuid
           ~generation:gen_uuid);
      expect_never_clean path (sprintf "receipt fault at %d" fault_point);
      remove_dir path)

(* Once the receipt is durable, retirement can only end blocked or clean:
   losing the unlink or its fsync never resurrects unowned dirtiness and never
   destroys the only unclean evidence. *)
let () =
  (* Receipt durable, unlink fails: both files remain -> blocked ambiguity. *)
  let path = fresh_dir () in
  mark path;
  receipt path;
  S.inject_failure_after 0;
  assert_error
    (S.retire_dirty ~state_directory:path ~scope:scope_uuid ~generation:gen_uuid);
  assert (Poly.equal (`Evidence S.Blocked) (outcome path));
  remove_dir path

let () =
  (* Receipt durable, unlink succeeds but its directory fsync fails: on this
     live filesystem the unlink is visible, so the scope reads clean; after a
     crash it could equally read blocked.  Both are safe. *)
  let path = fresh_dir () in
  mark path;
  receipt path;
  S.inject_failure_after 1;
  assert_error
    (S.retire_dirty ~state_directory:path ~scope:scope_uuid ~generation:gen_uuid);
  match outcome path with
  | `Evidence S.Blocked | `Evidence S.Clean -> remove_dir path
  | `Evidence (S.Dirty _) | `Evidence S.Unused | `Fail_closed ->
      remove_dir path;
      failwith "retirement lost its durable receipt evidence"

(* A mismatched generation is foreign state and is never retired. *)
let () =
  let path = fresh_dir () in
  mark path;
  assert_error
    (S.retire_dirty ~state_directory:path ~scope:scope_uuid
       ~generation:other_gen_uuid);
  (match outcome path with
  | `Evidence (S.Dirty g) ->
      assert (String.equal (Nixploy.Target_lease.uuid_to_string g) generation)
  | _ -> failwith "mismatched-generation retire removed foreign evidence");
  remove_dir path

(* A dirty marker whose valid prefix is followed by trailing garbage is
   corrupt evidence: retirement must reject it, never match or remove it. *)
let () =
  let path = fresh_dir () in
  mark path;
  let oc =
    Out_channel.create
      (Filename.concat path (S.dirty_marker_name scope_uuid))
  in
  Out_channel.output_string oc ("dirty " ^ generation ^ "\ntrailing garbage");
  Out_channel.close oc;
  assert_error
    (S.retire_dirty ~state_directory:path ~scope:scope_uuid
       ~generation:gen_uuid);
  assert_error (S.scan_directory ~state_directory:path);
  ignore
    (U.lstat (Filename.concat path (S.dirty_marker_name scope_uuid)));
  remove_dir path

(* An oversize dirty marker cannot match any expected generation: retirement
   must fail closed rather than truncate-match the prefix. *)
let () =
  let path = fresh_dir () in
  let oc =
    Out_channel.create
      (Filename.concat path (S.dirty_marker_name scope_uuid))
  in
  Out_channel.output_string oc ("dirty " ^ generation ^ "\n");
  Out_channel.output_string oc (String.make (S.max_entry_bytes + 1) 'x');
  Out_channel.close oc;
  assert_error
    (S.retire_dirty ~state_directory:path ~scope:scope_uuid
       ~generation:gen_uuid);
  assert_error (S.scan_directory ~state_directory:path);
  remove_dir path

(* An existing clean receipt with trailing garbage is not byte-identical:
   the idempotent re-release path must report a conflict, not accept it. *)
let () =
  let path = fresh_dir () in
  receipt path;
  let oc =
    Out_channel.create
      (Filename.concat path (S.clean_receipt_name scope_uuid))
  in
  Out_channel.output_string oc ("clean " ^ generation ^ "\ntrailing");
  Out_channel.close oc;
  assert_error
    (S.write_clean_receipt ~state_directory:path ~scope:scope_uuid
       ~generation:gen_uuid);
  assert_error (S.scan_directory ~state_directory:path);
  remove_dir path

(* Corrupt, partial, and unexpected states fail closed. *)
let () =
  let corrupt_contents contents =
    let path = fresh_dir () in
    let oc =
      Out_channel.create (Filename.concat path (S.dirty_marker_name scope_uuid))
    in
    Out_channel.output_string oc contents;
    Out_channel.close oc;
    let result = S.scan_directory ~state_directory:path in
    remove_dir path;
    result
  in
  assert_error (corrupt_contents "garbage");
  assert_error (corrupt_contents "");
  assert_error (corrupt_contents ("dirty " ^ generation));
  assert_error (corrupt_contents "dirty not-a-uuid\n");
  let unexpected () =
    let path = fresh_dir () in
    let oc = Out_channel.create (Filename.concat path "unrelated.txt") in
    Out_channel.output_string oc "x";
    Out_channel.close oc;
    let result = S.scan_directory ~state_directory:path in
    remove_dir path;
    result
  in
  assert_error (unexpected ());
  let ambiguous () =
    let path = fresh_dir () in
    let write name contents =
      let oc = Out_channel.create (Filename.concat path name) in
      Out_channel.output_string oc contents;
      Out_channel.close oc
    in
    write (S.dirty_marker_name scope_uuid) ("dirty " ^ generation ^ "\n");
    write (S.clean_receipt_name scope_uuid) ("clean " ^ generation ^ "\n");
    let result = outcome path in
    remove_dir path;
    result
  in
  assert (Poly.equal (`Evidence S.Blocked) (ambiguous ()))

(* Injection is self-disabling afterwards: normal operations succeed. *)
let () =
  S.inject_failure_after (-1);
  let path = fresh_dir () in
  mark path;
  receipt path;
  retire path;
  assert (Poly.equal (`Evidence S.Clean) (outcome path));
  remove_dir path
