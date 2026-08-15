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

let parse_json_array input =
  let open Or_error.Let_syntax in
  let%bind json = Or_error.try_with (fun () -> Yojson.Safe.from_string input) in
  match json with
  | `List workloads -> Ok workloads
  | _ -> Or_error.error_string "Podman status must be a JSON array"

let all_of_json input =
  let open Or_error.Let_syntax in
  let%bind workloads = parse_json_array input in
  Or_error.all (List.map workloads ~f:of_json)

let all_owned_of_json ~ownership ~project ~target ~resource_key
    ~repository_identity ~expected_names input =
  let open Or_error.Let_syntax in
  let%bind workloads = parse_json_array input in
  let expected_project = Project_name.to_string project in
  let expected_target = Target_name.to_string target in
  let expected_resource_key = Resource_key.to_string resource_key in
  let label labels name = optional_string labels name in
  let modern_label_names =
    [
      "io.nixploy.managed";
      "io.nixploy.project";
      "io.nixploy.target";
      "io.nixploy.resource_key";
      "io.nixploy.repository";
      "io.nixploy.repository_identity";
    ]
  in
  let validate workload =
    match workload with
    | `Assoc fields ->
        let%bind parsed = of_json workload in
        let%bind () =
          if List.mem expected_names parsed.name ~equal:String.equal then Ok ()
          else
            Or_error.errorf
              "status returned container %s outside the exact resource names"
              parsed.name
        in
        let%bind labels =
          match List.Assoc.find fields ~equal:String.equal "Labels" with
          | Some (`Assoc labels) -> Ok labels
          | _ ->
              Or_error.errorf "container %s has no ownership labels" parsed.name
        in
        let exact name expected =
          Option.equal String.equal (label labels name) (Some expected)
        in
        let repository_label =
          Option.first_some
            (label labels "io.nixploy.repository_identity")
            (Option.first_some
               (label labels "io.nixploy.repository")
               (label labels "nixploy.repository"))
        in
        let owned =
          match ownership with
          | `Modern ->
              exact "io.nixploy.managed" "true"
              && exact "io.nixploy.project" expected_project
              && exact "io.nixploy.target" expected_target
              && exact "io.nixploy.resource_key" expected_resource_key
              && Option.equal String.equal repository_label
                   (Some repository_identity)
          | `Legacy ->
              (not
                 (List.exists modern_label_names ~f:(fun name ->
                      List.Assoc.mem labels ~equal:String.equal name)))
              && exact "nixploy.project" expected_project
              && exact "nixploy.target" expected_target
              && exact "nixploy.repository" repository_identity
        in
        if owned then Ok parsed
        else
          Or_error.errorf
            "container %s status ownership does not match this repository and \
             resource"
            parsed.name
    | _ -> Or_error.error_string "Podman workload must be an object"
  in
  Or_error.all (List.map workloads ~f:validate)
