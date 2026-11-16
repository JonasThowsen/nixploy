open Core

type t = { name : string; uri : Uri.t }

let name t = t.name

let required_string fields name =
  match List.Assoc.find fields ~equal:String.equal name with
  | Some (`String value) when not (String.is_empty value) -> Ok value
  | Some _ ->
      Or_error.errorf "Podman connection %s must be a non-empty string" name
  | None -> Or_error.errorf "Podman connection is missing %s" name

let of_json = function
  | `Assoc fields ->
      let open Or_error.Let_syntax in
      let%bind name = required_string fields "Name" in
      let%map uri = required_string fields "URI" in
      { name; uri = Uri.of_string uri }
  | _ -> Or_error.error_string "Podman connection must be an object"

let all_of_json input =
  let open Or_error.Let_syntax in
  let%bind json = Or_error.try_with (fun () -> Yojson.Safe.from_string input) in
  match json with
  | `List connections -> Or_error.all (List.map connections ~f:of_json)
  | _ -> Or_error.error_string "Podman connection list must be a JSON array"

let serves_socket connection path =
  String.Caseless.equal
    (Uri.scheme connection.uri |> Option.value ~default:"")
    "unix"
  && String.equal (Uri.path connection.uri) path

let find_by_name connections name =
  List.find connections ~f:(fun connection -> String.equal connection.name name)
