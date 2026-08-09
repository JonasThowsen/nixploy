open Core

type t = {
  name : string;
  image : string option;
  state : string option;
  status : string option;
  revision : string option;
}

let name t = t.name
let image t = t.image
let state t = t.state
let status t = t.status
let revision t = t.revision

let optional_string fields name =
  match List.Assoc.find fields ~equal:String.equal name with
  | Some (`String value) when not (String.is_empty value) -> Some value
  | _ -> None

let container_name fields =
  match List.Assoc.find fields ~equal:String.equal "Names" with
  | Some (`List (`String name :: _)) -> Some name
  | Some (`String name) -> Some name
  | _ -> optional_string fields "Name"

let revision_label fields =
  match List.Assoc.find fields ~equal:String.equal "Labels" with
  | Some (`Assoc labels) -> (
      match optional_string labels "io.nixploy.revision" with
      | Some _ as revision -> revision
      | None -> optional_string labels "nixploy.git_commit")
  | _ -> None

let of_json = function
  | `Assoc fields -> (
      match container_name fields with
      | None ->
          Or_error.error_string "Podman workload is missing its container name"
      | Some name ->
          Ok
            {
              name;
              image = optional_string fields "Image";
              state = optional_string fields "State";
              status = optional_string fields "Status";
              revision = revision_label fields;
            })
  | _ -> Or_error.error_string "Podman workload must be an object"

let all_of_json input =
  let open Or_error.Let_syntax in
  let%bind json = Or_error.try_with (fun () -> Yojson.Safe.from_string input) in
  match json with
  | `List workloads -> Or_error.all (List.map workloads ~f:of_json)
  | _ -> Or_error.error_string "Podman status must be a JSON array"
