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

let decryption_env () =
  let identity =
    Option.first_some
      (Sys.getenv "NIXPLOY_SOPS_AGE_SSH_PRIVATE_KEY_FILE")
      (Sys.getenv "SOPS_AGE_SSH_PRIVATE_KEY_FILE")
  in
  match identity with
  | None -> Deferred.Or_error.return None
  | Some path ->
      if not (Filename.is_absolute path) then
        Deferred.Or_error.error_string
          "the SOPS SSH identity path must be absolute"
      else
        let open Deferred.Or_error.Let_syntax in
        let%bind identity =
          Process_runner.run_stdout ~timeout:(Time_ns.Span.of_sec 15.)
            ~max_output_bytes:65_536 ~prog:"ssh-to-age"
            ~args:[ "-private-key"; "-i"; path ]
            ()
        in
        let identity = String.strip identity in
        if String.is_empty identity then
          Deferred.Or_error.error_string "ssh-to-age returned an empty identity"
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
                  ]))

let load ~target =
  let references =
    Configuration.Target.secret_references target
    |> List.sort ~compare:(fun (left, _) (right, _) ->
        String.compare left right)
  in
  if List.is_empty references then Deferred.Or_error.return []
  else
    let open Deferred.Or_error.Let_syntax in
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
end
