open Core

let has_unsafe_character value =
  String.exists value ~f:(fun character ->
      Char.is_whitespace character
      || Char.to_int character < 0x20
      || Char.to_int character = 0x7f
      || Char.equal character '/' || Char.equal character '@')

let normalized_ascii ~field ~valid_character value =
  if String.is_empty value then Or_error.errorf "%s must not be empty" field
  else if not (String.equal value (String.strip value)) then
    Or_error.errorf "%s must not contain surrounding whitespace" field
  else
    let value = String.lowercase value in
    if
      has_unsafe_character value
      || not (String.for_all value ~f:valid_character)
    then Or_error.errorf "%s contains an unsafe character" field
    else Ok value

let dns_character = function
  | 'a' .. 'z' | '0' .. '9' | '.' | '-' -> true
  | _ -> false

let scope_character = function
  | 'a' .. 'z' | '0' .. '9' | '.' | '-' | '_' | ':' -> true
  | _ -> false

let canonical_dns ~field value =
  let open Or_error.Let_syntax in
  let%bind value =
    normalized_ascii ~field ~valid_character:dns_character value
  in
  if String.is_suffix value ~suffix:".." then
    Or_error.errorf "%s must contain at most one trailing DNS root dot" field
  else Ok (Option.value (String.chop_suffix value ~suffix:".") ~default:value)

let canonical_ipv4 value =
  let open Or_error.Let_syntax in
  match String.split value ~on:'.' with
  | [ _; _; _; _ ] as octets ->
      let%map octets =
        Or_error.all
          (List.map octets ~f:(fun octet ->
               if
                 String.is_empty octet
                 || not (String.for_all octet ~f:Char.is_digit)
               then Or_error.error_string "IPv4 address is malformed"
               else
                 Or_error.try_with (fun () -> Int.of_string octet)
                 >>= fun number ->
                 if number > 255 then
                   Or_error.error_string "IPv4 address octet exceeds 255"
                 else Ok (Int.to_string number)))
      in
      String.concat ~sep:"." octets
  | _ -> Or_error.error_string "IPv4 address must contain four octets"

let canonical_ipv6 value =
  if String.mem value '%' then
    Or_error.error_string "scoped IPv6 addresses are not supported"
  else
    Or_error.try_with (fun () -> Caml_unix.inet_addr_of_string value)
    |> Or_error.bind ~f:(fun address ->
        let rendered = Caml_unix.string_of_inet_addr address in
        if String.mem rendered ':' then Ok (String.lowercase rendered)
        else Or_error.error_string "SSH host is not an IPv6 address")

let host value =
  let open Or_error.Let_syntax in
  if not (String.equal value (String.strip value)) then
    Or_error.error_string "SSH host must not contain surrounding whitespace"
  else
    let%bind value =
      match
        (String.is_prefix value ~prefix:"[", String.is_suffix value ~suffix:"]")
      with
      | true, true -> Ok (String.slice value 1 (-1))
      | false, false -> Ok value
      | true, false | false, true ->
          Or_error.error_string "SSH host has mismatched IPv6 brackets"
    in
    if String.mem value ':' then canonical_ipv6 value
    else if
      String.for_all value ~f:(fun character ->
          Char.is_digit character || Char.equal character '.')
    then canonical_ipv4 value
    else canonical_dns ~field:"SSH host" value

let domain = canonical_dns ~field:"web domain"

let coordination_scope value =
  normalized_ascii ~field:"coordination scope" ~valid_character:scope_character
    value
