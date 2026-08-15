let route_of_application = function
  | Nixploy.Application.Not_configured ->
      Protocol.Prune_result.Route.Not_configured
  | Missing -> Missing
  | Removed -> Removed

let of_application result =
  {
    Protocol.Prune_result.project =
      Nixploy.Application.prune_project result |> Nixploy.Project_name.to_string;
    target =
      Nixploy.Application.prune_target result |> Nixploy.Target_name.to_string;
    resource_key =
      Nixploy.Application.prune_resource_key result
      |> Nixploy.Resource_key.to_string;
    containers_removed = Nixploy.Application.prune_containers_removed result;
    secrets_removed = Nixploy.Application.prune_secrets_removed result;
    route = Nixploy.Application.prune_route_state result |> route_of_application;
  }
