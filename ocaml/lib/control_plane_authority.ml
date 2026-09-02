open Core

type t = {
  alias : string;
  uri : Uri.t;
  pinned_server_spki_sha256 : string;
  trusted_proxy_authority : Uri.t;
}

let alias t = t.alias
let uri t = t.uri
let pinned_server_spki_sha256 t = t.pinned_server_spki_sha256
let trusted_proxy_authority t = t.trusted_proxy_authority
let authority_file = "/etc/nixploy/control-plane-authorities.sexp"
let maximum_file_bytes = 65_536
let maximum_authorities = 32

let errorf format =
  Printf.ksprintf
    (fun message ->
      Or_error.error_string
        ("NIXPLOY_CONTROL_PLANE_AUTHORITY_INVALID: " ^ message))
    format

let valid_alias value =
  let valid_character = function
    | 'a' .. 'z' | '0' .. '9' | '-' | '_' -> true
    | _ -> false
  in
  (not (String.is_empty value))
  && String.length value <= 63
  && String.equal value (String.lowercase value)
  && String.for_all value ~f:valid_character

let canonical_https_authority ~field value =
  let open Or_error.Let_syntax in
  let uri = Uri.of_string value in
  let%bind scheme =
    Uri.scheme uri
    |> Or_error.of_option
         ~error:(Error.of_string (field ^ " must have an HTTPS scheme"))
  in
  let%bind host =
    Uri.host uri
    |> Or_error.of_option ~error:(Error.of_string (field ^ " must have a host"))
  in
  if not (String.equal scheme "https") then errorf "%s must use https" field
  else if Option.is_some (Uri.userinfo uri) then
    errorf "%s must not contain user information" field
  else if
    (not (String.is_empty (Uri.path uri) || String.equal (Uri.path uri) "/"))
    || (not (List.is_empty (Uri.query uri)))
    || Option.is_some (Uri.fragment uri)
  then errorf "%s must contain only an authority" field
  else
    let%map host = Endpoint_identity.host host in
    Uri.make ~scheme ~host ?port:(Uri.port uri) ()

let valid_base64_character = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '+' | '/' -> true
  | _ -> false

let valid_spki_pin value =
  String.length value = 44
  && Char.equal value.[43] '='
  && String.for_all (String.prefix value 43) ~f:valid_base64_character

let field = function
  | Sexp.List [ Sexp.Atom name; value ] -> Some (name, value)
  | _ -> None

let parse_fields ~context values =
  let rec collect collected = function
    | [] -> Ok (List.rev collected)
    | value :: remaining -> (
        match field value with
        | None -> errorf "%s must contain only (name value) fields" context
        | Some value -> collect (value :: collected) remaining)
  in
  match collect [] values with
  | Error _ as error -> error
  | Ok fields ->
      if List.contains_dup (List.map fields ~f:fst) ~compare:String.compare then
        errorf "%s contains a duplicate field" context
      else Ok fields

let required_atom fields name =
  match List.Assoc.find fields ~equal:String.equal name with
  | Some (Sexp.Atom value) when not (String.is_empty value) -> Ok value
  | _ -> errorf "field %s must be a non-empty atom" name

let no_unknown_fields ~context ~allowed fields =
  match
    List.find fields ~f:(fun (name, _) ->
        not (List.mem allowed name ~equal:String.equal))
  with
  | None -> Ok ()
  | Some (name, _) -> errorf "%s contains unknown field %s" context name

let parse_authority sexp =
  let open Or_error.Let_syntax in
  let%bind fields =
    match sexp with
    | Sexp.List values -> parse_fields ~context:"authority" values
    | Sexp.Atom _ -> errorf "authority must be a field list"
  in
  let%bind () =
    no_unknown_fields ~context:"authority"
      ~allowed:
        [
          "alias"; "uri"; "pinned_server_spki_sha256"; "trusted_proxy_authority";
        ]
      fields
  in
  let%bind alias = required_atom fields "alias" in
  let%bind () =
    if valid_alias alias then Ok ()
    else
      errorf
        "authority alias must use lowercase letters, digits, dashes, or \
         underscores"
  in
  let%bind uri =
    required_atom fields "uri" >>= canonical_https_authority ~field:"uri"
  in
  let%bind pinned_server_spki_sha256 =
    required_atom fields "pinned_server_spki_sha256"
  in
  let%bind () =
    if valid_spki_pin pinned_server_spki_sha256 then Ok ()
    else errorf "pinned_server_spki_sha256 must be a base64 SHA-256 digest"
  in
  let%map trusted_proxy_authority =
    required_atom fields "trusted_proxy_authority"
    >>= canonical_https_authority ~field:"trusted_proxy_authority"
  in
  { alias; uri; pinned_server_spki_sha256; trusted_proxy_authority }

let parse input =
  let open Or_error.Let_syntax in
  let%bind sexp = Or_error.try_with (fun () -> Sexp.of_string input) in
  let%bind fields =
    match sexp with
    | Sexp.List values ->
        parse_fields ~context:"control-plane authority record" values
    | Sexp.Atom _ ->
        errorf "control-plane authority record must be a field list"
  in
  let%bind () =
    no_unknown_fields ~context:"control-plane authority record"
      ~allowed:[ "version"; "authorities" ]
      fields
  in
  let%bind version = required_atom fields "version" in
  let%bind () =
    if String.equal version "1" then Ok ()
    else errorf "unsupported authority record version %s" version
  in
  let%bind authorities =
    match List.Assoc.find fields ~equal:String.equal "authorities" with
    | Some (Sexp.List values) -> Ok values
    | _ -> errorf "field authorities must be a list"
  in
  let%bind () =
    if List.length authorities <= maximum_authorities then Ok ()
    else
      errorf "authority record may contain at most %d authorities"
        maximum_authorities
  in
  let%bind parsed = Or_error.all (List.map authorities ~f:parse_authority) in
  if List.contains_dup (List.map parsed ~f:alias) ~compare:String.compare then
    errorf "authority record contains duplicate aliases"
  else
    Ok
      (List.sort parsed ~compare:(fun left right ->
           String.compare left.alias right.alias))

let find authorities ~alias =
  match
    List.find authorities ~f:(fun authority ->
        String.equal authority.alias alias)
  with
  | Some authority -> Ok authority
  | None ->
      Or_error.errorf
        "NIXPLOY_UNTRUSTED_CONTROL_PLANE: authority alias %s is not configured"
        alias

let validate_file_metadata ~uid ~perm ~regular =
  if not regular then errorf "authority record must be a regular file"
  else if not (Int.equal uid 0) then
    errorf "authority record must be root-owned"
  else if not (Int.equal (perm land 0o022) 0) then
    errorf "authority record must not be group or world writable"
  else Ok ()

type metadata = {
  uid : int;
  perm : int;
  regular : bool;
  directory : bool;
  device : int;
  inode : int;
  size : int;
  modified_at : float;
}

type filesystem = {
  lstat : string -> metadata Or_error.t;
  read : string -> (metadata * string * metadata) Or_error.t;
}

let rec validate_directory filesystem directory =
  let open Or_error.Let_syntax in
  let%bind stats = filesystem.lstat directory in
  if
    stats.directory && Int.equal stats.uid 0
    && Int.equal (stats.perm land 0o022) 0
  then
    let parent = Filename.dirname directory in
    if String.equal parent directory then Ok ()
    else validate_directory filesystem parent
  else
    errorf
      "authority directory %s must be root-owned and not group or world \
       writable"
      directory

let same_file left right =
  Int.equal left.device right.device
  && Int.equal left.inode right.inode
  && Int.equal left.size right.size
  && Float.equal left.modified_at right.modified_at

let load_with filesystem ~path =
  let open Or_error.Let_syntax in
  let%bind () = validate_directory filesystem (Filename.dirname path) in
  let%bind link_stats = filesystem.lstat path in
  let%bind () =
    validate_file_metadata ~uid:link_stats.uid ~perm:link_stats.perm
      ~regular:link_stats.regular
  in
  let%bind before, contents, after = filesystem.read path in
  let%bind () =
    validate_file_metadata ~uid:before.uid ~perm:before.perm ~regular:before.regular
  in
  let%bind () =
    if before.size <= maximum_file_bytes then Ok ()
    else errorf "authority record exceeds %d bytes" maximum_file_bytes
  in
  let%bind () =
    if Int.equal (String.length contents) before.size then Ok ()
    else errorf "authority record changed while being read"
  in
  let%bind () =
    if same_file before after then Ok ()
    else errorf "authority record changed while being read"
  in
  parse contents

let metadata_of_stats stats =
  {
    uid = stats.Caml_unix.st_uid;
    perm = stats.st_perm;
    regular = Poly.equal stats.st_kind Caml_unix.S_REG;
    directory = Poly.equal stats.st_kind Caml_unix.S_DIR;
    device = stats.st_dev;
    inode = stats.st_ino;
    size = stats.st_size;
    modified_at = stats.st_mtime;
  }

let system_lstat path =
  Or_error.try_with (fun () -> Caml_unix.lstat path |> metadata_of_stats)

let system_read path =
  Or_error.try_with_join (fun () ->
      let descriptor =
        Caml_unix.openfile path [ Caml_unix.O_RDONLY; Caml_unix.O_CLOEXEC ] 0
      in
      Exn.protect
        ~finally:(fun () -> Caml_unix.close descriptor)
        ~f:(fun () ->
          let before = Caml_unix.fstat descriptor |> metadata_of_stats in
          let open Or_error.Let_syntax in
          let%bind () =
            if before.size <= maximum_file_bytes then Ok ()
            else errorf "authority record exceeds %d bytes" maximum_file_bytes
          in
          let bytes = Bytes.create before.size in
          let rec read_all offset =
            if offset < before.size then
              let count =
                Caml_unix.read descriptor bytes offset (before.size - offset)
              in
              if Int.equal count 0 then
                failwith "unexpected EOF while reading authority record"
              else read_all (offset + count)
          in
          read_all 0;
          let after = Caml_unix.fstat descriptor |> metadata_of_stats in
          Ok (before, Bytes.to_string bytes, after)))

let load () =
  load_with { lstat = system_lstat; read = system_read } ~path:authority_file
  |> Result.map_error ~f:(fun error ->
      Error.tag error ~tag:"NIXPLOY_UNTRUSTED_CONTROL_PLANE")

module For_testing = struct
  type nonrec metadata = metadata = {
    uid : int;
    perm : int;
    regular : bool;
    directory : bool;
    device : int;
    inode : int;
    size : int;
    modified_at : float;
  }

  type nonrec filesystem = filesystem = {
    lstat : string -> metadata Or_error.t;
    read : string -> (metadata * string * metadata) Or_error.t;
  }

  let parse = parse
  let validate_file_metadata = validate_file_metadata
  let load filesystem ~path = load_with filesystem ~path
end
