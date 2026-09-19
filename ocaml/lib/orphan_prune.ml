open Async
open Core

type t = {
  resource_key : string;
  project : string;
  target : string;
  dry_run : bool;
  containers : string list;
  secrets : string list;
  image_references : string list;
  image_bytes : int64;
}

let resource_key t = t.resource_key
let project t = t.project
let target t = t.target
let dry_run t = t.dry_run
let containers t = t.containers
let secrets t = t.secrets
let image_references t = t.image_references
let image_bytes t = t.image_bytes

let removable_group inventory ~key =
  match Inventory.find_group inventory key with
  | None ->
      Or_error.errorf "no nixploy resources with key %s were found on this host"
        key
  | Some group -> (
      let label_error =
        Or_error.errorf
          "%s has no project and target labels to verify ownership; inspect \
           and remove it manually"
          key
      in
      match group.classification with
      | Current | Declared ->
          Or_error.errorf
            "%s belongs to target %s, which this flake declares; use `nixploy \
             prune -t %s` instead"
            key
            (Option.value group.target ~default:"?")
            (Option.value group.target ~default:"TARGET")
      | Unattributed -> label_error
      | Orphaned | Other_project -> (
          match
            (group.problems, group.project, group.target, group.repository)
          with
          | _ :: _, _, _, _ ->
              Or_error.errorf "refusing %s: %s" key
                (String.concat ~sep:"; " group.problems)
          | [], Some project, Some target, Some repository ->
              Ok (group, project, target, repository)
          | [], _, _, _ -> label_error))

(* A shared image also carries other keys' references; only this key's are
   removed, and the image is freed only when it has no others. *)
let own_references (group : Inventory.group) (image : Podman.owned_image) =
  match Resource_key.of_observed group.resource_key with
  | Error _ -> []
  | Ok key ->
      let repository = Owned_image.repository key in
      List.filter image.references ~f:(fun reference ->
          Option.is_some (Owned_image.tag ~repository reference))

let running (group : Inventory.group) =
  List.exists group.containers ~f:(fun container ->
      Option.equal String.equal container.state (Some "running"))

let inactive (group : Inventory.group) ~host_name =
  if group.route || running group then
    Or_error.errorf
      "NIXPLOY_PRUNE_ACTIVE: %s still has %s; run `nixploy stop -t %s --orphan \
       %s` first. Prune never removes a route or a running application."
      group.resource_key
      (if group.route then "a Caddy route" else "a running container")
      (Target_name.to_string host_name)
      group.resource_key
  else Ok ()

let summary ~dry_run ~project ~target (group : Inventory.group) =
  {
    resource_key = group.resource_key;
    project;
    target;
    dry_run;
    containers = List.map group.containers ~f:(fun container -> container.name);
    secrets = List.map group.secrets ~f:(fun secret -> secret.name);
    image_references = List.concat_map group.images ~f:(own_references group);
    image_bytes =
      List.sum
        (module Int64)
        group.images
        ~f:(fun image ->
          if
            List.length (own_references group image)
            = List.length image.references
          then Option.value image.size_bytes ~default:0L
          else 0L);
  }

let ownership_labels ~project ~target ~key ~repository =
  [
    ("io.nixploy.managed", "true");
    ("io.nixploy.project", project);
    ("io.nixploy.target", target);
    ("io.nixploy.resource_key", key);
    ("io.nixploy.repository_identity", repository);
  ]

let prune ~store ~working_directory ~target:host_name ~resource_key:key
    ~confirmed ~dry_run =
  let open Deferred.Or_error.Let_syntax in
  let%bind () =
    if confirmed || dry_run then Deferred.Or_error.return ()
    else
      Deferred.Or_error.error_string
        "NIXPLOY_PRUNE_CONFIRMATION_REQUIRED: pass --yes to remove the \
         orphaned resources, or --dry-run to preview"
  in
  let%bind resource_key = Deferred.return (Resource_key.of_observed key) in
  let%bind inventory = Inventory.load ~working_directory ~target:host_name in
  let%bind group, project, target, repository =
    Deferred.return (removable_group inventory ~key)
  in
  let%bind () = Deferred.return (inactive group ~host_name) in
  if dry_run then
    Deferred.Or_error.return (summary ~dry_run ~project ~target group)
  else
    let%bind project_name = Deferred.return (Project_name.of_string project) in
    let%bind target_name = Deferred.return (Target_name.of_string target) in
    let host = Inventory.host inventory in
    let operation_id =
      Uuid.create_random (Random.State.make_self_init ()) |> Uuid.to_string
    in
    let record message =
      Store.record_prune_event store ~operation_id ~working_directory
        ~target:target_name ~message
    in
    let%bind () = record ("requested: orphaned resources of " ^ key) in
    let ownership = ownership_labels ~project ~target ~key ~repository in
    let%bind.Deferred result =
      Mutation_guard.with_mutation_for ~host ~project:project_name ~target_name
        (fun () ->
          let open Deferred.Or_error.Let_syntax in
          (* Observe again under the guard; anything that changed since the
             unguarded read must still pass every check. *)
          let%bind inventory =
            Inventory.load ~working_directory ~target:host_name
          in
          let%bind group, project', target', repository' =
            Deferred.return (removable_group inventory ~key)
          in
          let%bind () =
            if
              String.equal project project'
              && String.equal target target'
              && String.equal repository repository'
            then Deferred.Or_error.return ()
            else
              Deferred.Or_error.error_string
                "orphan ownership changed between observation and removal"
          in
          let%bind () = Deferred.return (inactive group ~host_name) in
          let connection = Inventory.connection inventory in
          let%bind () = record "ownership preflight complete" in
          let%bind () =
            Deferred.Or_error.List.iter group.containers ~how:`Sequential
              ~f:(fun container ->
                let%bind () = record ("removing container " ^ container.id) in
                Podman.remove_labelled_container ~connection ~id:container.id
                  ~expected:ownership)
          in
          let%bind () =
            Deferred.Or_error.List.iter group.secrets ~how:`Sequential
              ~f:(fun secret ->
                let%bind () = record ("removing secret " ^ secret.id) in
                Podman.remove_labelled_secret ~connection ~id:secret.id
                  ~name:secret.name
                  ~ownership:(("io.nixploy.repository", repository) :: ownership))
          in
          let%bind () =
            Deferred.Or_error.List.iter group.images ~how:`Sequential
              ~f:(fun image ->
                Deferred.Or_error.List.iter (own_references group image)
                  ~how:`Sequential ~f:(fun reference ->
                    let%bind () =
                      record ("removing image reference " ^ reference)
                    in
                    Podman.remove_owned_image_reference ~connection
                      ~resource_key reference))
          in
          Deferred.Or_error.return (summary ~dry_run ~project ~target group))
    in
    let message =
      match result with
      | Ok _ -> "succeeded"
      | Error error -> "failed or unknown: " ^ Error.to_string_hum error
    in
    let%bind.Deferred recorded = record message in
    match (result, recorded) with
    | Ok result, Ok () -> Deferred.Or_error.return result
    | Error error, Ok () ->
        Deferred.Or_error.fail
          (Error.tag error ~tag:("Prune operation " ^ operation_id))
    | _, Error error ->
        Deferred.Or_error.fail
          (Error.tag error
             ~tag:
               ("Prune operation " ^ operation_id
              ^ ": terminal reporting failed; inspect remote state and \
                 prune_events"))

type stopped = {
  stopped_key : string;
  stopped_project : string;
  stopped_target : string;
  route_removed : bool;
  stopped_containers : string list;
}

let stopped_key stopped = stopped.stopped_key
let stopped_project stopped = stopped.stopped_project
let stopped_target stopped = stopped.stopped_target
let stopped_route_removed stopped = stopped.route_removed
let stopped_containers stopped = stopped.stopped_containers

let stop ~store ~working_directory ~target:host_name ~resource_key:key =
  let open Deferred.Or_error.Let_syntax in
  let%bind resource_key = Deferred.return (Resource_key.of_observed key) in
  let%bind inventory = Inventory.load ~working_directory ~target:host_name in
  let%bind _, project, target, repository =
    Deferred.return (removable_group inventory ~key)
  in
  let%bind project_name = Deferred.return (Project_name.of_string project) in
  let%bind target_name = Deferred.return (Target_name.of_string target) in
  let host = Inventory.host inventory in
  let operation_id =
    Uuid.create_random (Random.State.make_self_init ()) |> Uuid.to_string
  in
  let record message =
    Store.record_prune_event store ~operation_id ~working_directory
      ~target:target_name ~message:("stop: " ^ message)
  in
  let%bind () = record ("requested: stop orphaned resources of " ^ key) in
  let ownership = ownership_labels ~project ~target ~key ~repository in
  let%bind.Deferred result =
    Mutation_guard.with_mutation_for ~host ~project:project_name ~target_name
      (fun () ->
        let open Deferred.Or_error.Let_syntax in
        let%bind inventory =
          Inventory.load ~working_directory ~target:host_name
        in
        let%bind group, project', target', repository' =
          Deferred.return (removable_group inventory ~key)
        in
        let%bind () =
          if
            String.equal project project'
            && String.equal target target'
            && String.equal repository repository'
          then Deferred.Or_error.return ()
          else
            Deferred.Or_error.error_string
              "orphan ownership changed between observation and stop"
        in
        let connection = Inventory.connection inventory in
        let%bind route_removed =
          if group.route then
            let%bind () = record "removing Caddy route" in
            Caddy.delete_key ~target:host ~resource_key
          else Deferred.Or_error.return false
        in
        let%map () =
          Deferred.Or_error.List.iter group.containers ~how:`Sequential
            ~f:(fun container ->
              let%bind () = record ("stopping container " ^ container.id) in
              Podman.stop_labelled_container ~connection ~id:container.id
                ~expected:ownership)
        in
        {
          stopped_key = key;
          stopped_project = project;
          stopped_target = target;
          route_removed;
          stopped_containers =
            List.map group.containers ~f:(fun container -> container.name);
        })
  in
  let message =
    match result with
    | Ok _ -> "succeeded"
    | Error error -> "failed or unknown: " ^ Error.to_string_hum error
  in
  let%bind.Deferred recorded = record message in
  match (result, recorded) with
  | Ok result, Ok () -> Deferred.Or_error.return result
  | Error error, Ok () ->
      Deferred.Or_error.fail
        (Error.tag error ~tag:("Stop operation " ^ operation_id))
  | _, Error error ->
      Deferred.Or_error.fail
        (Error.tag error
           ~tag:
             ("Stop operation " ^ operation_id
            ^ ": terminal reporting failed; inspect remote state and \
               prune_events"))
