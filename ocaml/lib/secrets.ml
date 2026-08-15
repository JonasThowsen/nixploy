open Async
open Core

type t = { name : string; value : string }

let name t = t.name
let value t = t.value
let max_decrypted_bytes = 65_536
let max_diagnostic_bytes = 16_384
let max_secrets = 256

let valid_name name =
  let valid_first = function
    | 'A' .. 'Z' | 'a' .. 'z' | '_' -> true
    | _ -> false
  in
  let valid_rest character = valid_first character || Char.is_digit character in
  (not (String.is_empty name))
  && valid_first name.[0]
  && String.for_all name ~f:valid_rest

let unescape_double_quoted value =
  let buffer = Buffer.create (String.length value) in
  let rec loop index =
    if index >= String.length value then Buffer.contents buffer
    else if Char.equal value.[index] '\\' && index + 1 < String.length value
    then (
      let character =
        match value.[index + 1] with
        | 'n' -> '\n'
        | 'r' -> '\r'
        | 't' -> '\t'
        | '\\' -> '\\'
        | '"' -> '"'
        | character -> character
      in
      Buffer.add_char buffer character;
      loop (index + 2))
    else (
      Buffer.add_char buffer value.[index];
      loop (index + 1))
  in
  loop 0

let unquote value =
  let length = String.length value in
  if
    length >= 2 && Char.equal value.[0] '"' && Char.equal value.[length - 1] '"'
  then String.sub value ~pos:1 ~len:(length - 2) |> unescape_double_quoted
  else if
    length >= 2
    && Char.equal value.[0] '\''
    && Char.equal value.[length - 1] '\''
  then String.sub value ~pos:1 ~len:(length - 2)
  else
    match String.substr_index value ~pattern:" #" with
    | Some index -> String.prefix value index |> String.rstrip
    | None -> value

let parse_dotenv content =
  let open Or_error.Let_syntax in
  let%bind secrets =
    String.split_lines content
    |> List.fold_result ~init:[] ~f:(fun secrets raw_line ->
        let line = String.strip raw_line in
        if String.is_empty line || String.is_prefix line ~prefix:"#" then
          Ok secrets
        else
          let line =
            if String.is_prefix line ~prefix:"export " then
              String.drop_prefix line 7 |> String.lstrip
            else line
          in
          match String.lsplit2 line ~on:'=' with
          | None ->
              Or_error.error_string "decrypted dotenv contains an invalid line"
          | Some (name, value) ->
              let name = String.strip name in
              let value = String.strip value |> unquote in
              if not (valid_name name) then
                Or_error.errorf "decrypted dotenv contains invalid variable %s"
                  name
              else if String.mem value '\000' then
                Or_error.errorf
                  "decrypted dotenv variable %s contains a NUL byte" name
              else if
                List.exists secrets ~f:(fun secret ->
                    String.equal secret.name name)
              then
                Or_error.errorf
                  "decrypted dotenv contains duplicate variable %s" name
              else Ok ({ name; value } :: secrets))
  in
  let secrets = List.rev secrets in
  if List.length secrets > max_secrets then
    Or_error.errorf "decrypted dotenv exceeds %d variables" max_secrets
  else Ok secrets

let redacted_value = "[REDACTED]"

let redact secrets text =
  secrets
  |> List.filter ~f:(fun secret -> not (String.is_empty secret.value))
  |> List.sort ~compare:(fun left right ->
      Int.compare (String.length right.value) (String.length left.value))
  |> List.fold ~init:text ~f:(fun text secret ->
      String.substr_replace_all text ~pattern:secret.value ~with_:redacted_value)

let validate_private_identity_file path =
  let open Or_error.Let_syntax in
  if not (Filename.is_absolute path) then
    Or_error.error_string "private identity file path must be absolute"
  else
    let components =
      String.split path ~on:'/' |> List.filter ~f:(Fn.non String.is_empty)
    in
    let%bind final_stats =
      List.fold_result components ~init:("/", None)
        ~f:(fun (parent, _previous) component ->
          let current = Filename.concat parent component in
          match Or_error.try_with (fun () -> Core_unix.lstat current) with
          | Error _ ->
              Or_error.error_string "private identity file cannot be inspected"
          | Ok { st_kind = S_LNK; _ } ->
              Or_error.error_string
                "private identity file path must not contain symbolic links"
          | Ok stats -> Ok (current, Some stats))
      |> Or_error.map ~f:snd
    in
    let%bind stats =
      Option.value_map final_stats
        ~default:
          (Or_error.error_string "private identity file must name a file")
        ~f:Or_error.return
    in
    if
      match stats.st_kind with
      | S_REG -> false
      | S_DIR | S_CHR | S_BLK | S_LNK | S_FIFO | S_SOCK -> true
    then Or_error.error_string "private identity must be a regular file"
    else if stats.st_perm land 0o077 <> 0 then
      Or_error.error_string
        "private identity file must not grant group or other permissions"
    else
      let euid = Core_unix.geteuid () in
      if Int.equal stats.st_uid euid then Ok ()
      else if Int.equal stats.st_uid 0 && stats.st_perm land 0o200 = 0 then
        Ok ()
      else
        Or_error.error_string "private identity file ownership is not permitted"

let decryption_env () =
  let open Deferred.Or_error.Let_syntax in
  let%bind () =
    match Sys.getenv "SOPS_AGE_KEY_FILE" with
    | None -> Deferred.Or_error.return ()
    | Some path -> Deferred.return (validate_private_identity_file path)
  in
  let identity =
    Option.first_some
      (Sys.getenv "NIXPLOY_SOPS_AGE_SSH_PRIVATE_KEY_FILE")
      (Sys.getenv "SOPS_AGE_SSH_PRIVATE_KEY_FILE")
  in
  match identity with
  | None -> Deferred.Or_error.return None
  | Some path -> (
      let%bind () = Deferred.return (validate_private_identity_file path) in
      let%bind converted =
        Process_runner.run ~timeout:(Time_ns.Span.of_sec 15.)
          ~max_output_bytes:65_536 ~prog:"ssh-to-age"
          ~args:[ "-private-key"; "-i"; path ]
          ()
      in
      match converted.exit_status with
      | Error _ ->
          Deferred.Or_error.error_string
            "ssh-to-age could not load the private identity"
      | Ok () ->
          let identity = String.strip converted.stdout in
          if String.is_empty identity then
            Deferred.Or_error.error_string
              "ssh-to-age returned an empty identity"
          else
            Deferred.Or_error.return
              (Some
                 (`Override
                    [
                      ("SOPS_AGE_KEY", Some identity);
                      ("SOPS_AGE_KEY_CMD", None);
                      ("SOPS_AGE_KEY_FILE", None);
                      ("SOPS_AGE_SSH_PRIVATE_KEY_CMD", None);
                      ("SOPS_AGE_SSH_PRIVATE_KEY_FILE", None);
                    ])))

let resolve_reference ~source_root path =
  if Filename.is_absolute path then Ok path
  else if String.split path ~on:'/' |> List.exists ~f:(String.equal "..") then
    Or_error.error_string "relative secret path must not contain .."
  else
    Or_error.try_with (fun () ->
        let canonical_root = Filename_unix.realpath source_root in
        let resolved =
          Filename.concat canonical_root path |> Filename_unix.realpath
        in
        let beneath_root =
          String.equal canonical_root "/"
          || String.equal resolved canonical_root
          || String.is_prefix resolved ~prefix:(canonical_root ^ "/")
        in
        if beneath_root then resolved
        else
          failwith
            "relative secret path resolves outside the canonical source root")
    |> Or_error.tag ~tag:"invalid relative secret path"

let load ~source_root ~target =
  let references =
    Configuration.Target.secret_references target
    |> List.sort ~compare:(fun (left, _) (right, _) ->
        String.compare left right)
  in
  if List.is_empty references then Deferred.Or_error.return []
  else
    let open Deferred.Or_error.Let_syntax in
    let%bind references =
      List.map references ~f:(fun (label, path) ->
          resolve_reference ~source_root path
          |> Or_error.map ~f:(fun path -> (label, path)))
      |> Or_error.all |> Deferred.return
    in
    let%bind env = decryption_env () in
    let rec decrypt loaded = function
      | [] -> Deferred.Or_error.return (List.rev loaded)
      | (label, path) :: remaining -> (
          let%bind result =
            Process_runner.run ?env ~timeout:(Time_ns.Span.of_min 2.)
              ~max_output_bytes:max_decrypted_bytes ~prog:"sops"
              ~args:
                [
                  "--decrypt";
                  "--input-type";
                  "dotenv";
                  "--output-type";
                  "dotenv";
                  path;
                ]
              ()
          in
          match result.exit_status with
          | Error failure ->
              Deferred.Or_error.errorf
                "could not decrypt secret set %s (%s): %s" label
                (Core_unix.Exit_or_signal.to_string_hum (Error failure))
                (String.prefix result.stderr max_diagnostic_bytes
                |> String.strip)
          | Ok () -> (
              let%bind parsed = Deferred.return (parse_dotenv result.stdout) in
              let duplicate =
                List.find parsed ~f:(fun secret ->
                    List.exists loaded ~f:(fun existing ->
                        String.equal secret.name existing.name))
              in
              match duplicate with
              | Some secret ->
                  Deferred.Or_error.errorf
                    "secret variable %s occurs in more than one configured set"
                    secret.name
              | None -> decrypt (List.rev_append parsed loaded) remaining))
    in
    decrypt [] references

module For_testing = struct
  let parse_dotenv = parse_dotenv
  let resolve_reference = resolve_reference
  let validate_private_identity_file = validate_private_identity_file
end
