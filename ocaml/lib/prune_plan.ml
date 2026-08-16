open Core

type t = { resource_key : Resource_key.t; container_names : string list }

let create ~resource_key =
  let single = Resource_key.to_string resource_key in
  {
    resource_key;
    container_names =
      [
        single;
        Deployment_plan.web_container_name ~resource_key Deployment_plan.Blue;
        Deployment_plan.web_container_name ~resource_key Deployment_plan.Green;
      ];
  }

let container_names t = t.container_names

let select_secret_names t names =
  let prefix = Resource_key.to_string t.resource_key ^ "-" in
  List.filter names ~f:(String.is_prefix ~prefix)
  |> List.dedup_and_sort ~compare:String.compare
