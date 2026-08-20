open Core

let label fields name =
  match List.Assoc.find fields ~equal:String.equal name with
  | Some (`String value) when not (String.is_empty value) -> Some value
  | _ -> None

let exact_label labels name expected =
  Option.equal String.equal (label labels name) (Some expected)

let resource_key labels ~project ~target =
  if
    exact_label labels "io.nixploy.managed" "true"
    && exact_label labels "io.nixploy.project" (Project_name.to_string project)
    && exact_label labels "io.nixploy.target" (Target_name.to_string target)
  then label labels "io.nixploy.resource_key"
  else None

let exact labels ~project ~target ~resource_key:expected =
  Option.equal String.equal
    (resource_key labels ~project ~target)
    (Some (Resource_key.to_string expected))

let repository_identity labels = label labels "io.nixploy.repository_identity"
