open Core

type route = Non_web | Missing | Routed of Deployment_plan.slot option

type container = {
  name : string;
  placement : Deployment_plan.placement;
  running : bool;
  secret_names : string list option;
  image_id : string option;
}

type image = {
  image_id : string;
  references : string list;
  size_bytes : int64 option;
  containers : int;
}

type t = {
  remove_containers : container list;
  retain_containers : container list;
  remove_secrets : string list;
  remove_images : image list;
  retain_images : image list;
  notes : string list;
}

let image_tag_key image =
  List.map image.references ~f:(fun reference ->
      match String.rsplit2 reference ~on:':' with
      | Some (_, tag) -> tag
      | None -> reference)
  |> List.max_elt ~compare:String.compare
  |> Option.value ~default:""

let is_slot slot (container : container) =
  match container.placement with
  | Web_slot { slot = placed; _ } -> Deployment_plan.equal_slot slot placed
  | Single_container -> false

let partition_containers ~route containers =
  match route with
  | Non_web ->
      let retain, remove =
        List.partition_tf containers ~f:(fun (container : container) ->
            match container.placement with
            | Single_container -> true
            | Web_slot _ -> false)
      in
      (remove, retain, [])
  | Routed (Some slot) ->
      if List.exists containers ~f:(is_slot slot) then
        let retain, remove = List.partition_tf containers ~f:(is_slot slot) in
        (remove, retain, [])
      else
        ( [],
          containers,
          if List.is_empty containers then []
          else
            [
              sprintf
                "kept all containers: the route serves the %s slot, which has \
                 no container"
                (Deployment_plan.slot_name slot);
            ] )
  | Routed None ->
      ( [],
        containers,
        [ "kept all containers: the route targets an undeclared port" ] )
  | Missing ->
      ( [],
        containers,
        if List.is_empty containers then []
        else
          [
            "kept all containers: the route is missing, so the live slot is \
             unknown; redeploy first";
          ] )

let create ~route ~containers ~owned_secrets ~images ~keep =
  if keep < 1 then Or_error.error_string "--keep must be at least 1"
  else
    let remove_containers, retain_containers, container_notes =
      partition_containers ~route containers
    in
    let untracked =
      List.filter retain_containers ~f:(fun container ->
          Option.is_none container.secret_names)
    in
    let remove_secrets, secret_notes =
      match untracked with
      | [] ->
          let mounted =
            List.concat_map retain_containers ~f:(fun container ->
                Option.value container.secret_names ~default:[])
            |> String.Set.of_list
          in
          ( List.filter owned_secrets ~f:(fun name -> not (Set.mem mounted name))
            |> List.dedup_and_sort ~compare:String.compare,
            [] )
      | container :: _ ->
          ( [],
            [
              sprintf
                "kept all secrets: %s predates secret tracking; redeploy to \
                 enable secret cleanup"
                container.name;
            ] )
    in
    let retained_image_ids =
      List.filter_map retain_containers ~f:(fun container -> container.image_id)
      |> String.Set.of_list
    in
    let removed_users image =
      List.count remove_containers ~f:(fun container ->
          Option.equal String.equal container.image_id (Some image.image_id))
    in
    let newest =
      List.sort images ~compare:(fun left right ->
          String.compare (image_tag_key right) (image_tag_key left))
      |> Fn.flip List.take keep
      |> List.map ~f:(fun image -> image.image_id)
      |> String.Set.of_list
    in
    let retain_images, remove_images =
      List.partition_tf images ~f:(fun image ->
          Set.mem retained_image_ids image.image_id
          || Set.mem newest image.image_id
          (* Another container, possibly of a different owner, still uses the
             image through a reference that nixploy does not own here. *)
          || image.containers > removed_users image)
    in
    Ok
      {
        remove_containers;
        retain_containers;
        remove_secrets;
        remove_images;
        retain_images;
        notes = container_notes @ secret_notes;
      }
