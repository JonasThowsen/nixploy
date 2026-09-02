open Core

type identity = Tailscale_login of string [@@deriving compare, equal, sexp]

type t = {
  token : string;
  identity : identity;
  capabilities : String.Set.t;
  package_revision : string;
  protocol_major : int;
  protocol_minor : int;
  expires_at_ms : int64;
}

type factory = {
  now_ms : unit -> int64;
  random_bytes : int -> string Or_error.t;
  ttl_ms : int64;
}

let token_bytes = 32
let token_length = 43
let default_ttl_ms = Int64.of_int (5 * 60 * 1000)

external getrandom : int -> string = "nixploy_capability_grant_getrandom"

let system_factory () =
  {
    now_ms = (fun () -> Caml_unix.gettimeofday () *. 1000. |> Int64.of_float);
    random_bytes = (fun length -> Or_error.try_with (fun () -> getrandom length));
    ttl_ms = default_ttl_ms;
  }

let token grant = grant.token
let expires_at_ms grant = grant.expires_at_ms

let valid_capability capability =
  not (String.is_empty capability)
  && String.length capability <= 64
  && String.equal capability (String.strip capability)
  && not (String.exists capability ~f:Char.is_whitespace)

let create factory ~identity ~capabilities ~package_revision ~protocol_major
    ~protocol_minor =
  if Int64.(factory.ttl_ms <= 0L) then Or_error.error_string "capability grant TTL must be positive"
  else if not (List.for_all capabilities ~f:valid_capability) then
    Or_error.error_string "capability grant contains an invalid capability"
  else
    let open Or_error.Let_syntax in
    let%bind entropy = factory.random_bytes token_bytes in
    if String.length entropy <> token_bytes then
      Or_error.error_string "capability grant entropy source returned an invalid length"
    else
      let token =
        Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet entropy
      in
      if String.length token <> token_length then
        Or_error.error_string "capability grant token encoding failed"
      else
        Ok
          {
            token;
            identity;
            capabilities = String.Set.of_list capabilities;
            package_revision;
            protocol_major;
            protocol_minor;
            expires_at_ms = Int64.(factory.now_ms () + factory.ttl_ms);
          }

let constant_time_equal left right =
  let length = String.length left in
  if length <> String.length right then false
  else
    let difference = ref 0 in
    for index = 0 to length - 1 do
      difference := !difference lor (Char.to_int left.[index] lxor Char.to_int right.[index])
    done;
    Int.equal !difference 0

let valid_token_shape token =
  String.length token = token_length
  && String.for_all token ~f:(function
       | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' -> true
       | _ -> false)

let rejected () =
  Or_error.error_string "NIXPLOY_CAPABILITY_GRANT_REJECTED: capability grant is invalid"

let validate grant ~token ~identity ~package_revision ~protocol_major
    ~protocol_minor ~capability ~now_ms =
  if not (valid_token_shape token) then rejected ()
  else if Int64.(now_ms >= grant.expires_at_ms) then
    Or_error.error_string "NIXPLOY_CAPABILITY_GRANT_EXPIRED: capability grant has expired"
  else if
    not (constant_time_equal token grant.token)
    || not (equal_identity identity grant.identity)
    || not (String.equal package_revision grant.package_revision)
    || not (Int.equal protocol_major grant.protocol_major)
    || not (Int.equal protocol_minor grant.protocol_minor)
  then rejected ()
  else if not (Set.mem grant.capabilities capability) then
    rejected ()
  else Ok ()
