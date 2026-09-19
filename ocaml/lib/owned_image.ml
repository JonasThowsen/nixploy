open Core

let repository resource_key =
  (* Resource keys may contain '_' next to '-', which a repository path
     component rejects. The key's digest keeps the result unique. *)
  let component =
    Resource_key.to_string resource_key
    |> String.map ~f:(fun character ->
        if Char.is_lowercase character || Char.is_digit character then character
        else '-')
    |> String.split ~on:'-'
    |> List.filter ~f:(Fn.non String.is_empty)
    |> String.concat ~sep:"-"
  in
  "localhost/nixploy/" ^ component

let reference resource_key ~loaded_at ~revision =
  let revision =
    String.filter (String.lowercase revision) ~f:(fun character ->
        Char.is_lowercase character || Char.is_digit character)
  in
  let revision =
    if String.is_empty revision then "unknown"
    else String.prefix revision (Int.min 12 (String.length revision))
  in
  let time =
    let date, ofday =
      Time_float.to_date_ofday loaded_at ~zone:Time_float.Zone.utc
    in
    let parts = Time_float.Ofday.to_parts ofday in
    sprintf "%04d%02d%02dT%02d%02d%02dZ" (Date.year date)
      (Month.to_int (Date.month date))
      (Date.day date) parts.hr parts.min parts.sec
  in
  sprintf "%s:%s-%s" (repository resource_key) time revision

let tag ~repository reference =
  match String.chop_prefix reference ~prefix:(repository ^ ":") with
  | Some tag when (not (String.is_empty tag)) && not (String.mem tag '/') ->
      Some tag
  | Some _ | None -> None
