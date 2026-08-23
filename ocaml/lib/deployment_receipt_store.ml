open Core
module U = Caml_unix

type 'a entry = {
  receipt : string;
  application_key : string;
  expires_at : float;
  sequence : int;
  payload : 'a;
}

type 'a t = {
  capacity : int;
  ttl_seconds : float;
  now : unit -> float;
  random_bytes : int -> string Or_error.t;
  mutable next_sequence : int;
  mutable entries : 'a entry list;
}

let secure_random_bytes length =
  Or_error.try_with (fun () ->
      let descriptor =
        U.openfile "/dev/urandom" [ U.O_RDONLY; U.O_CLOEXEC ] 0
      in
      Exn.protect
        ~f:(fun () ->
          let bytes = Bytes.create length in
          let rec read_all offset =
            if offset < length then
              let count = U.read descriptor bytes offset (length - offset) in
              if Int.equal count 0 then
                failwith "unexpected EOF from /dev/urandom"
              else read_all (offset + count)
          in
          read_all 0;
          Bytes.to_string bytes)
        ~finally:(fun () -> U.close descriptor))

let create ?(capacity = 64) ?(ttl_seconds = 300.)
    ?(now = Target_lease_socket.now) ?(random_bytes = secure_random_bytes) () =
  if capacity < 1 || capacity > 256 then
    Or_error.error_string
      "deployment receipt capacity must be between 1 and 256"
  else if Float.(ttl_seconds <= 0. || ttl_seconds > 900.) then
    Or_error.error_string
      "deployment receipt TTL must be greater than 0 and at most 900 seconds"
  else
    Ok
      {
        capacity;
        ttl_seconds;
        now;
        random_bytes;
        next_sequence = 0;
        entries = [];
      }

let constant_time_equal left right =
  let left_length = String.length left in
  let right_length = String.length right in
  let length = Int.max left_length right_length in
  let difference = ref (left_length lxor right_length) in
  for index = 0 to length - 1 do
    let left_byte =
      if index < left_length then Char.to_int left.[index] else 0
    in
    let right_byte =
      if index < right_length then Char.to_int right.[index] else 0
    in
    difference := !difference lor (left_byte lxor right_byte)
  done;
  Int.equal !difference 0

let purge_expired t now =
  t.entries <-
    List.filter t.entries ~f:(fun entry -> Float.(now < entry.expires_at))

let evict_oldest t =
  if List.length t.entries >= t.capacity then
    match
      List.min_elt t.entries ~compare:(fun left right ->
          Int.compare left.sequence right.sequence)
    with
    | None -> ()
    | Some oldest ->
        t.entries <-
          List.filter t.entries ~f:(fun entry ->
              not (Int.equal entry.sequence oldest.sequence))

let hex_of_bytes bytes =
  String.concat_map bytes ~f:(fun byte -> sprintf "%02x" (Char.to_int byte))

let issue t ~application_key payload =
  let open Or_error.Let_syntax in
  let now = t.now () in
  purge_expired t now;
  evict_oldest t;
  let%bind bytes = t.random_bytes 32 in
  let receipt = hex_of_bytes bytes in
  if String.length bytes <> 32 then
    Or_error.error_string "deployment receipt CSPRNG returned the wrong length"
  else if
    List.exists t.entries ~f:(fun entry ->
        constant_time_equal entry.receipt receipt)
  then Or_error.error_string "deployment receipt CSPRNG collision"
  else
    let sequence = t.next_sequence in
    t.next_sequence <- t.next_sequence + 1;
    t.entries <-
      {
        receipt;
        application_key;
        expires_at = now +. t.ttl_seconds;
        sequence;
        payload;
      }
      :: t.entries;
    Ok receipt

let consume t ~application_key ~receipt =
  let now = t.now () in
  purge_expired t now;
  let matched =
    List.fold t.entries ~init:None ~f:(fun matched entry ->
        if constant_time_equal entry.receipt receipt then Some entry
        else matched)
  in
  Option.iter matched ~f:(fun matched ->
      t.entries <-
        List.filter t.entries ~f:(fun entry ->
            not (Int.equal entry.sequence matched.sequence)));
  match matched with
  | Some entry when String.equal entry.application_key application_key ->
      Ok entry.payload
  | Some _ | None ->
      Or_error.error_string
        "deployment preview receipt is missing, expired, evicted, replayed, or \
         mismatched"
