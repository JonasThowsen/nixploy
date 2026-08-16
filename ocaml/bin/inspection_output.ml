open Core

let value_or_dash = Option.value ~default:"-"

let status status =
  let module Application = Nixploy.Application in
  let module Target = Nixploy.Configuration.Target in
  let buffer = Buffer.create 512 in
  bprintf buffer "Project:  %s\n"
    (Nixploy.Project_name.to_string (Application.status_project status));
  bprintf buffer "Target:   %s\n"
    (Nixploy.Target_name.to_string
       (Target.name (Application.status_target status)));
  bprintf buffer "Host:     %s@%s:%d\n"
    (Target.user (Application.status_target status))
    (Target.host (Application.status_target status))
    (Target.port (Application.status_target status));
  bprintf buffer "Resource: %s\n"
    (Nixploy.Resource_key.to_string (Application.status_resource_key status));
  (match Application.status_workloads status with
  | [] -> bprintf buffer "\nNo deployed containers found.\n"
  | workloads ->
      bprintf buffer "\n%-36s %-12s %-18s %s\n" "CONTAINER" "STATE" "REVISION"
        "IMAGE";
      List.iter workloads ~f:(fun workload ->
          bprintf buffer "%-36s %-12s %-18s %s\n"
            (Nixploy.Workload.name workload)
            (Nixploy.Workload.state workload |> value_or_dash)
            (Nixploy.Workload.revision workload
            |> Option.map ~f:(fun revision ->
                String.prefix revision (Int.min 16 (String.length revision)))
            |> value_or_dash)
            (Nixploy.Workload.image workload |> value_or_dash)));
  Buffer.contents buffer

let history deployments =
  let module Application = Nixploy.Application in
  let buffer = Buffer.create 512 in
  (match deployments with
  | [] -> bprintf buffer "No deployment history found.\n"
  | deployments ->
      bprintf buffer "%-36s %-10s %-18s %s\n" "OPERATION" "STATE" "REVISION"
        "MESSAGE";
      List.iter deployments ~f:(fun deployment ->
          let revision =
            Application.deployment_revision deployment
            |> Option.map ~f:(fun revision ->
                String.prefix revision (Int.min 16 (String.length revision)))
            |> value_or_dash
          in
          bprintf buffer "%-36s %-10s %-18s %s\n"
            (Application.deployment_id deployment)
            (Application.deployment_state deployment
            |> Application.deployment_state_name)
            revision
            (Application.deployment_message deployment)));
  Buffer.contents buffer
