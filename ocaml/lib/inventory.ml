open Async
open Core

type classification =
  | Current
  | Declared
  | Orphaned
  | Other_project
  | Unattributed
[@@deriving compare, equal, sexp]

type container = {
  id : string;
  name : string;
  state : string option;
  status : string option;
}

type secret = { id : string; name : string }

type group = {
  resource_key : string;
  project : string option;
  target : string option;
  repository : string option;
  classification : classification;
  containers : container list;
  secrets : secret list;
  images : Podman.owned_image list;
  route : bool;
  marker : string option;
  problems : string list;
}

type t = {
  host : Configuration.Target.t;
  connection : string;
  project : Project_name.t;
  groups : group list;
  unattributed_images : Podman.owned_image list;
  legacy_secrets : string list;
  unattributed_markers : string list;
  errors : (string * Error.t) list;
}

let host t = t.host
let connection t = t.connection
let project t = t.project
let groups t = t.groups
let unattributed_images t = t.unattributed_images
let legacy_secrets t = t.legacy_secrets
let unattributed_markers t = t.unattributed_markers
let errors t = t.errors

let find_group t key =
  List.find t.groups ~f:(fun group -> String.equal group.resource_key key)

let label (resource : Podman.Labelled.t) key =
  List.Assoc.find resource.labels ~equal:String.equal key
  |> Option.filter ~f:(Fn.non String.is_empty)

let resource_key_label resource = label resource "io.nixploy.resource_key"

let single ~what values =
  match List.dedup_and_sort values ~compare:String.compare with
  | [] -> (None, [])
  | [ value ] -> (Some value, [])
  | values ->
      ( None,
        [
          sprintf "conflicting %s labels: %s" what
            (String.concat ~sep:", " values);
        ] )

let classification_rank = function
  | Current -> 0
  | Declared -> 1
  | Orphaned -> 2
  | Other_project -> 3
  | Unattributed -> 4

let build ~project ~declared ~current_key ~containers ~secrets ~images
    ~route_keys ~markers =
  let keyed_secrets, legacy_secrets =
    List.partition_map secrets ~f:(fun secret ->
        match resource_key_label secret with
        | Some key -> First (key, secret)
        | None -> Second secret.name)
  in
  let keyed_containers =
    List.map containers ~f:(fun container ->
        match resource_key_label container with
        | Some key -> (key, container)
        | None -> (container.name, container))
  in
  let keys =
    List.map keyed_containers ~f:fst
    @ List.map keyed_secrets ~f:fst
    @ List.filter route_keys ~f:(fun key ->
        Result.is_ok (Resource_key.of_observed key))
    |> List.dedup_and_sort ~compare:String.compare
  in
  let repository_of key =
    Resource_key.of_observed key
    |> Result.ok
    |> Option.map ~f:Owned_image.repository
  in
  let image_in_repository repository (image : Podman.owned_image) =
    List.exists image.references ~f:(fun reference ->
        Option.is_some (Owned_image.tag ~repository reference))
  in
  let groups =
    List.map keys ~f:(fun key ->
        let containers =
          List.filter_map keyed_containers ~f:(fun (owner, container) ->
              Option.some_if (String.equal owner key) container)
        in
        let secrets =
          List.filter_map keyed_secrets ~f:(fun (owner, secret) ->
              Option.some_if (String.equal owner key) secret)
        in
        let labelled = containers @ secrets in
        let values name = List.filter_map labelled ~f:(fun r -> label r name) in
        let group_project, project_problems =
          single ~what:"project" (values "io.nixploy.project")
        in
        let group_target, target_problems =
          single ~what:"target" (values "io.nixploy.target")
        in
        let repository, repository_problems =
          single ~what:"repository" (values "io.nixploy.repository_identity")
        in
        let unlabelled_key =
          if
            (not (List.is_empty containers))
            && List.for_all containers ~f:(fun c ->
                Option.is_none (resource_key_label c))
          then [ "container has no resource key label" ]
          else []
        in
        let marker =
          match (group_project, group_target) with
          | Some p, Some t -> (
              match (Project_name.of_string p, Target_name.of_string t) with
              | Ok p, Ok t -> (
                  match Resource_key.derive_current ~project:p ~target:t with
                  | Ok marker
                    when List.mem markers
                           (Resource_key.to_string marker)
                           ~equal:String.equal ->
                      Some (Resource_key.to_string marker)
                  | Ok _ | Error _ -> None)
              | _ -> None)
          | _ -> None
        in
        let classification =
          if String.equal key (Resource_key.to_string current_key) then Current
          else
            match (group_project, group_target) with
            | Some p, Some t
              when String.equal p (Project_name.to_string project) ->
                if
                  List.exists declared ~f:(fun name ->
                      String.equal (Target_name.to_string name) t)
                then Declared
                else Orphaned
            | Some _, Some _ -> Other_project
            | _ -> Unattributed
        in
        {
          resource_key = key;
          project = group_project;
          target = group_target;
          repository;
          classification;
          containers =
            List.map containers ~f:(fun (c : Podman.Labelled.t) ->
                { id = c.id; name = c.name; state = c.state; status = c.status });
          secrets =
            List.map secrets ~f:(fun (s : Podman.Labelled.t) ->
                { id = s.id; name = s.name });
          images =
            (match repository_of key with
            | None -> []
            | Some repository ->
                List.filter images ~f:(image_in_repository repository));
          route = List.mem route_keys key ~equal:String.equal;
          marker;
          problems =
            unlabelled_key @ project_problems @ target_problems
            @ repository_problems;
        })
    |> List.sort ~compare:(fun left right ->
        Comparable.lexicographic
          [
            (fun l r ->
              Int.compare
                (classification_rank l.classification)
                (classification_rank r.classification));
            (fun l r -> String.compare l.resource_key r.resource_key);
          ]
          left right)
  in
  let attributed_images =
    List.concat_map groups ~f:(fun group ->
        List.map group.images ~f:(fun image -> image.image_id))
    |> String.Set.of_list
  in
  let matched_markers =
    List.filter_map groups ~f:(fun group -> group.marker) |> String.Set.of_list
  in
  ( groups,
    List.filter images ~f:(fun image ->
        not (Set.mem attributed_images image.image_id)),
    List.sort legacy_secrets ~compare:String.compare,
    List.filter markers ~f:(fun marker -> not (Set.mem matched_markers marker))
  )

let load ~working_directory ~target:target_name =
  let open Deferred.Or_error.Let_syntax in
  let%bind configuration = Nix_configuration.load ~working_directory in
  let%bind () =
    Deferred.return
      (Direct_mode.validate_configuration configuration ~target:target_name)
  in
  let%bind host =
    Deferred.return (Configuration.find_target configuration target_name)
  in
  let project = Configuration.project configuration in
  let declared =
    Configuration.targets configuration |> List.map ~f:Configuration.Target.name
  in
  let%bind repository_identity =
    Source.repository_identity ~working_directory
  in
  let%bind candidates =
    Deferred.return
      (Resource_key.candidates ~project ~target:target_name ~repository_identity)
  in
  let%bind current_key =
    Podman.select_resource_key ~project ~target:host ~repository_identity
      ~candidates
  in
  let%bind connection =
    Podman.ensure_connection ~target:host ~resource_key:current_key
  in
  let%bind containers = Podman.list_managed_containers ~connection
  and secrets = Podman.list_nixploy_secrets ~connection
  and images = Podman.list_nixploy_images ~connection in
  let open Deferred.Let_syntax in
  let%map route_keys =
    if
      List.exists (Configuration.targets configuration) ~f:(fun target ->
          match Configuration.Target.kind target with
          | Web _ -> true
          | Non_web -> false)
    then Caddy.list_route_keys ~target:host
    else
      (* Only query Caddy when this project uses it; a host without Caddy is
         normal for non-web projects. *)
      Deferred.Or_error.return []
  and markers = Mutation_guard.list_markers ~host in
  let errors =
    List.filter_map
      [
        ("Caddy routes", Result.error route_keys);
        ("mutation markers", Result.error markers);
      ]
      ~f:(fun (section, error) ->
        Option.map error ~f:(fun error -> (section, error)))
  in
  let groups, unattributed_images, legacy_secrets, unattributed_markers =
    build ~project ~declared ~current_key ~containers ~secrets ~images
      ~route_keys:(Result.ok route_keys |> Option.value ~default:[])
      ~markers:(Result.ok markers |> Option.value ~default:[])
  in
  Ok
    {
      host;
      connection;
      project;
      groups;
      unattributed_images;
      legacy_secrets;
      unattributed_markers;
      errors;
    }

module For_testing = struct
  let build = build
end
