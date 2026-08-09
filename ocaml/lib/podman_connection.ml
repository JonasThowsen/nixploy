open Core

type t = { name : string; uri : Uri.t; identity : string option }

let name t = t.name
let identity t = t.identity

let required_string fields name =
  match List.Assoc.find fields ~equal:String.equal name with
  | Some (`String value) when not (String.is_empty value) -> Ok value
  | Some _ ->
      Or_error.errorf "Podman connection %s must be a non-empty string" name
  | None -> Or_error.errorf "Podman connection is missing %s" name

let optional_string fields name =
  match List.Assoc.find fields ~equal:String.equal name with
  | Some (`String value) when not (String.is_empty value) -> Ok (Some value)
  | Some (`String _) | Some `Null | None -> Ok None
  | Some _ -> Or_error.errorf "Podman connection %s must be a string" name

let of_json = function
  | `Assoc fields ->
      let open Or_error.Let_syntax in
      let%bind name = required_string fields "Name" in
      let%bind uri = required_string fields "URI" in
      let%map identity = optional_string fields "Identity" in
      { name; uri = Uri.of_string uri; identity }
  | _ -> Or_error.error_string "Podman connection must be an object"

let all_of_json input =
  let open Or_error.Let_syntax in
  let%bind json = Or_error.try_with (fun () -> Yojson.Safe.from_string input) in
  match json with
  | `List connections -> Or_error.all (List.map connections ~f:of_json)
  | _ -> Or_error.error_string "Podman connection list must be a JSON array"

let matches_target connection target =
  String.Caseless.equal
    (Uri.scheme connection.uri |> Option.value ~default:"")
    "ssh"
  && Option.value_map (Uri.user connection.uri) ~default:false ~f:(fun user ->
      String.equal user (Configuration.Target.user target))
  && Option.value_map (Uri.host connection.uri) ~default:false ~f:(fun host ->
      String.Caseless.equal host (Configuration.Target.host target))
  && Int.equal
       (Uri.port connection.uri |> Option.value ~default:22)
       (Configuration.Target.port target)

let matches_identity connection identity =
  Option.equal String.equal connection.identity identity

let find_by_name connections name =
  List.find connections ~f:(fun connection -> String.equal connection.name name)

let find_for_target connections target =
  match
    connections
    |> List.filter ~f:(fun connection -> matches_target connection target)
    |> List.sort ~compare:(fun left right ->
        String.compare left.name right.name)
  with
  | connection :: _ -> Ok connection
  | [] ->
      Or_error.errorf "no Podman connection matches %s@%s:%d"
        (Configuration.Target.user target)
        (Configuration.Target.host target)
        (Configuration.Target.port target)
