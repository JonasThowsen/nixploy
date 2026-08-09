open Core

type t = string [@@deriving compare, equal, sexp]

let max_identity_part_length = 48

let sanitize value =
  let buffer = Buffer.create (String.length value) in
  let previous_was_separator = ref false in
  String.lowercase value
  |> String.iter ~f:(fun character ->
      let safe =
        Char.is_lowercase character
        || Char.is_digit character || Char.equal character '_'
        || Char.equal character '-'
      in
      if safe then (
        Buffer.add_char buffer character;
        previous_was_separator := false)
      else if not !previous_was_separator then (
        Buffer.add_char buffer '-';
        previous_was_separator := true));
  Buffer.contents buffer |> String.strip ~drop:(Char.equal '-') |> fun value ->
  String.prefix value (Int.min max_identity_part_length (String.length value))

let derive ~project ~target =
  let project_text = Project_name.to_string project in
  let target_text = Target_name.to_string target in
  let project_part = sanitize project_text in
  let target_part = sanitize target_text in
  if String.is_empty project_part || String.is_empty target_part then
    Or_error.error_string
      "project and target must contain a resource-safe character"
  else
    let digest =
      project_text ^ "\000" ^ target_text
      |> Digestif.SHA256.digest_string |> Digestif.SHA256.to_hex
      |> fun value -> String.prefix value 10
    in
    Ok
      (String.concat
         [ "nixploy-"; project_part; "-"; digest; "-"; target_part ])

let to_string t = t
