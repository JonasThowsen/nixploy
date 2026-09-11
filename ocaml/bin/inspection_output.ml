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

let json_string value = `String value
let json_option value = Option.value_map value ~default:`Null ~f:json_string
let json_time value = `Intlit (Int64.to_string value)
let encode_json value = Yojson.Safe.to_string value ^ "\n"

let deployment_value deployment =
  let module A = Nixploy.Application in
  `Assoc
    [
      ("id", json_string (A.deployment_id deployment));
      ( "state",
        json_string (A.deployment_state deployment |> A.deployment_state_name)
      );
      ("stage", json_string (A.deployment_stage deployment));
      ("message", json_string (A.deployment_message deployment));
      ("revision", json_option (A.deployment_revision deployment));
      ("container", json_option (A.deployment_container_name deployment));
      ("error", json_option (A.deployment_error deployment));
      ("requestedAtMs", json_time (A.deployment_requested_at_ms deployment));
      ( "finishedAtMs",
        Option.value_map
          (A.deployment_finished_at_ms deployment)
          ~default:`Null ~f:json_time );
    ]

let deployment_json deployment = encode_json (deployment_value deployment)

let history_json deployments =
  encode_json (`List (List.map deployments ~f:deployment_value))

let status_json status =
  let module A = Nixploy.Application in
  let module T = Nixploy.Configuration.Target in
  let module W = Nixploy.Workload in
  let target = A.status_target status in
  encode_json
    (`Assoc
       [
         ( "project",
           json_string
             (A.status_project status |> Nixploy.Project_name.to_string) );
         ("target", json_string (T.name target |> Nixploy.Target_name.to_string));
         ("host", json_string (T.host target));
         ( "resourceKey",
           json_string
             (A.status_resource_key status |> Nixploy.Resource_key.to_string) );
         ( "containers",
           `List
             (List.map (A.status_workloads status) ~f:(fun workload ->
                  `Assoc
                    [
                      ("name", json_string (W.name workload));
                      ("state", json_option (W.state workload));
                      ("revision", json_option (W.revision workload));
                      ("image", json_option (W.image workload));
                    ])) );
       ])

let logs_json (logs : Nixploy.Application.log_snapshot) =
  encode_json
    (`Assoc
       [
         ("container", json_string logs.container_name);
         ("revision", json_option logs.revision);
         ("observedAtMs", json_time logs.observed_at_ms);
         ("truncated", `Bool logs.truncated);
         ( "lines",
           `List
             (List.map logs.lines ~f:(fun line ->
                  `Assoc
                    [
                      ("timestamp", json_option line.timestamp);
                      ("text", json_string line.text);
                    ])) );
       ])

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
