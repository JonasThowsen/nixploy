open Core

let value_or_dash = Option.value ~default:"-"

let short_revision revision =
  String.prefix revision (Int.min 16 (String.length revision))

let role_name = function
  | Nixploy.Status.Single -> "app"
  | Active -> "active"
  | Unrouted -> "unrouted"

let cpu_text (stats : Nixploy.Podman.runtime_stats option) =
  match stats with
  | Some { cpu_percent = Some cpu; _ } -> sprintf "%.1f%%" cpu
  | Some _ | None -> "-"

let memory_text ~host_memory (stats : Nixploy.Podman.runtime_stats option) =
  let human = Nixploy.Status.human_bytes in
  match stats with
  | None -> "-"
  | Some { memory_used_bytes; memory_limit_bytes = Some limit; _ }
    when Option.for_all host_memory ~f:(fun total -> Int64.(limit < total)) ->
      sprintf "%s / %s" (human memory_used_bytes) (human limit)
  | Some { memory_used_bytes; _ } -> human memory_used_bytes

let section_error error = "unavailable: " ^ Error.to_string_hum error

let status status =
  let module Application = Nixploy.Application in
  let module Status = Nixploy.Status in
  let module Target = Nixploy.Configuration.Target in
  let module W = Nixploy.Workload in
  let human = Status.human_bytes in
  let target = Application.status_target status in
  let buffer = Buffer.create 2048 in
  let host = Status.host status in
  let host_memory =
    match host with Ok host -> host.memory_total_bytes | Error _ -> None
  in
  bprintf buffer "Project:  %s\n"
    (Nixploy.Project_name.to_string (Application.status_project status));
  bprintf buffer "Target:   %s\n"
    (Nixploy.Target_name.to_string (Target.name target));
  bprintf buffer "Host:     %s@%s:%d%s\n" (Target.user target)
    (Target.host target) (Target.port target)
    (match host with
    | Ok { cpus; memory_total_bytes; memory_free_bytes; _ } ->
        let parts =
          List.filter_opt
            [
              Option.map cpus ~f:(sprintf "%d CPUs");
              Option.map memory_total_bytes ~f:(fun total ->
                  sprintf "%s memory" (human total));
              Option.map memory_free_bytes ~f:(fun free ->
                  sprintf "%s free" (human free));
            ]
        in
        if List.is_empty parts then ""
        else " (" ^ String.concat ~sep:", " parts ^ ")"
    | Error _ -> "");
  bprintf buffer "Resource: %s\n"
    (Nixploy.Resource_key.to_string (Application.status_resource_key status));
  (match Status.containers status with
  | [] -> bprintf buffer "\nNo deployed containers found.\n"
  | containers ->
      bprintf buffer "\n%-40s %-8s %-9s %-24s %-7s %-22s %s\n" "CONTAINER"
        "ROLE" "STATE" "STATUS" "CPU" "MEMORY" "REVISION";
      List.iter containers ~f:(fun container ->
          let workload = container.workload in
          bprintf buffer "%-40s %-8s %-9s %-24s %-7s %-22s %s\n"
            (W.name workload) (role_name container.role)
            (W.state workload |> value_or_dash)
            (W.status workload |> value_or_dash)
            (cpu_text container.stats)
            (memory_text ~host_memory container.stats)
            (W.revision workload
            |> Option.map ~f:short_revision
            |> value_or_dash));
      Option.iter (Status.runtime_error status) ~f:(fun error ->
          bprintf buffer "Runtime details %s\n" (section_error error)));
  bprintf buffer "\n";
  (match Status.route status with
  | Ok Not_web -> ()
  | Ok Missing -> bprintf buffer "Route:    missing\n"
  | Ok (Routed { domain; port; slot }) ->
      bprintf buffer "Route:    %s -> 127.0.0.1:%d%s\n" domain port
        (Option.value_map slot ~default:" (undeclared port)" ~f:(fun slot ->
             sprintf " (%s slot)" (Nixploy.Deployment_plan.slot_name slot)))
  | Error error -> bprintf buffer "Route:    %s\n" (section_error error));
  (match Status.secrets status with
  | Ok secrets ->
      let owned, legacy =
        List.partition_tf secrets
          ~f:(fun (secret : Nixploy.Podman.Secret_status.t) -> secret.owned)
      in
      bprintf buffer "Secrets:  %d owned%s\n" (List.length owned)
        (if List.is_empty legacy then ""
         else sprintf ", %d unlabelled legacy" (List.length legacy))
  | Error error -> bprintf buffer "Secrets:  %s\n" (section_error error));
  (match Status.storage status with
  | Ok storage ->
      bprintf buffer
        "Storage:  images %s (%s reclaimable), containers %s, volumes %s \
         (host-wide)\n"
        (human storage.images_bytes)
        (human storage.images_reclaimable_bytes)
        (human storage.containers_bytes)
        (human storage.volumes_bytes)
  | Error error -> bprintf buffer "Storage:  %s\n" (section_error error));
  (match Status.disk status with
  | Ok disk ->
      bprintf buffer "Disk:     %s free of %s on %s\n"
        (human disk.available_bytes)
        (human disk.total_bytes) disk.path
  | Error error -> bprintf buffer "Disk:     %s\n" (section_error error));
  (match Status.guard status with
  | Ok Absent -> bprintf buffer "Guard:    idle\n"
  | Ok (Present directory) -> bprintf buffer "Guard:    held (%s)\n" directory
  | Error error -> bprintf buffer "Guard:    %s\n" (section_error error));
  bprintf buffer "Reboot:   %s\n"
    (if
       List.is_empty (Nixploy.Host_readiness.warnings (Status.readiness status))
     then "ready"
     else "not ready (see issues)");
  (match Status.issues status with
  | [] -> bprintf buffer "\nNo issues found.\n"
  | issues ->
      bprintf buffer "\nIssues:\n";
      List.iter issues ~f:(fun issue -> bprintf buffer "  - %s\n" issue));
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

let json_int64 value = `Intlit (Int64.to_string value)
let json_int value = Option.value_map value ~default:`Null ~f:(fun v -> `Int v)

let json_section result ~f =
  match result with
  | Ok value -> f value
  | Error error -> `Assoc [ ("error", `String (Error.to_string_hum error)) ]

let status_json status =
  let module A = Nixploy.Application in
  let module S = Nixploy.Status in
  let module T = Nixploy.Configuration.Target in
  let module W = Nixploy.Workload in
  let target = A.status_target status in
  let container (container : S.container) =
    let workload = container.workload in
    let stats = container.stats in
    `Assoc
      [
        ("name", json_string (W.name workload));
        ("id", json_option (W.id workload));
        ("role", json_string (role_name container.role));
        ("state", json_option (W.state workload));
        ("status", json_option (W.status workload));
        ("revision", json_option (W.revision workload));
        ("image", json_option (W.image workload));
        ("restartPolicy", json_option container.restart_policy);
        ("restarts", json_int (W.restarts workload));
        ( "startedAt",
          Option.value_map
            (W.started_at_unix workload)
            ~default:`Null ~f:json_int64 );
        ("exitCode", json_int (W.exit_code workload));
        ( "cpuPercent",
          Option.bind stats ~f:(fun stats -> stats.cpu_percent)
          |> Option.value_map ~default:`Null ~f:(fun cpu -> `Float cpu) );
        ( "memoryBytes",
          Option.value_map stats ~default:`Null ~f:(fun stats ->
              json_int64 stats.memory_used_bytes) );
        ( "memoryLimitBytes",
          Option.bind stats ~f:(fun stats -> stats.memory_limit_bytes)
          |> Option.value_map ~default:`Null ~f:json_int64 );
        ("pids", json_int (Option.bind stats ~f:(fun stats -> stats.pids)));
      ]
  in
  let route =
    json_section (S.route status) ~f:(function
      | Not_web -> `Null
      | Missing -> `Assoc [ ("state", `String "missing") ]
      | Routed { domain; port; slot } ->
          `Assoc
            [
              ("state", `String "routed");
              ("domain", `String domain);
              ("port", `Int port);
              ( "slot",
                Option.value_map slot ~default:`Null ~f:(fun slot ->
                    `String (Nixploy.Deployment_plan.slot_name slot)) );
            ])
  in
  let secrets =
    json_section (S.secrets status) ~f:(fun secrets ->
        let names owned =
          `List
            (List.filter_map secrets
               ~f:(fun (secret : Nixploy.Podman.Secret_status.t) ->
                 if Bool.equal secret.owned owned then
                   Some (`String secret.name)
                 else None))
        in
        `Assoc [ ("owned", names true); ("legacy", names false) ])
  in
  let storage =
    json_section (S.storage status) ~f:(fun storage ->
        `Assoc
          [
            ("imagesBytes", json_int64 storage.images_bytes);
            ( "imagesReclaimableBytes",
              json_int64 storage.images_reclaimable_bytes );
            ("containersBytes", json_int64 storage.containers_bytes);
            ("volumesBytes", json_int64 storage.volumes_bytes);
          ])
  in
  let host =
    json_section (S.host status) ~f:(fun host ->
        `Assoc
          [
            ("cpus", json_int host.cpus);
            ( "memoryTotalBytes",
              Option.value_map host.memory_total_bytes ~default:`Null
                ~f:json_int64 );
            ( "memoryFreeBytes",
              Option.value_map host.memory_free_bytes ~default:`Null
                ~f:json_int64 );
          ])
  in
  let disk =
    json_section (S.disk status) ~f:(fun disk ->
        `Assoc
          [
            ("path", `String disk.path);
            ("totalBytes", json_int64 disk.total_bytes);
            ("availableBytes", json_int64 disk.available_bytes);
          ])
  in
  let guard =
    json_section (S.guard status) ~f:(function
      | Absent -> `Assoc [ ("state", `String "idle") ]
      | Present directory ->
          `Assoc [ ("state", `String "held"); ("path", `String directory) ])
  in
  let readiness =
    `List
      (List.map
         (Nixploy.Host_readiness.checks (S.readiness status))
         ~f:(fun (check : Nixploy.Host_readiness.check) ->
           let state, reason =
             match check.state with
             | Ready -> ("ready", `Null)
             | Not_ready -> ("not-ready", `Null)
             | Unknown reason -> ("unknown", `String reason)
           in
           `Assoc
             [
               ("check", `String check.name);
               ("state", `String state);
               ("reason", reason);
               ("remedy", `String check.remedy);
             ]))
  in
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
         ("containers", `List (List.map (S.containers status) ~f:container));
         ("route", route);
         ("secrets", secrets);
         ("storage", storage);
         ("hostResources", host);
         ("disk", disk);
         ("guard", guard);
         ("rebootReadiness", readiness);
         ("issues", `List (List.map (S.issues status) ~f:json_string));
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
