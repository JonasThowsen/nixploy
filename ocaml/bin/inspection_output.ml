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
  if Status.stopped status then
    bprintf buffer "State:    stopped (nixploy stop)\n";
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
  (match Status.images status with
  | Ok [] -> bprintf buffer "Images:   none owned\n"
  | Ok images ->
      let in_use =
        List.count images ~f:(fun (image : Nixploy.Podman.owned_image) ->
            image.containers > 0)
      in
      bprintf buffer "Images:   %d owned (%s), %d in use\n" (List.length images)
        (human
           (List.sum
              (module Int64)
              images
              ~f:(fun image -> Option.value image.size_bytes ~default:0L)))
        in_use
  | Error error -> bprintf buffer "Images:   %s\n" (section_error error));
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
  let images =
    json_section (S.images status) ~f:(fun images ->
        `List
          (List.map images ~f:(fun (image : Nixploy.Podman.owned_image) ->
               `Assoc
                 [
                   ("id", `String image.image_id);
                   ( "references",
                     `List (List.map image.references ~f:json_string) );
                   ( "sizeBytes",
                     Option.value_map image.size_bytes ~default:`Null
                       ~f:json_int64 );
                   ("containers", `Int image.containers);
                 ])))
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
         ("stopped", `Bool (S.stopped status));
         ("containers", `List (List.map (S.containers status) ~f:container));
         ("route", route);
         ("secrets", secrets);
         ("images", images);
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

let prune_route_name = function
  | Nixploy.Application.Not_configured -> "not-configured"
  | Missing -> "missing"
  | Kept -> "kept"

let prune result =
  let module A = Nixploy.Application in
  let buffer = Buffer.create 1024 in
  let dry_run = A.prune_dry_run result in
  let containers = A.prune_containers result in
  let secrets = A.prune_secrets result in
  let images = A.prune_image_references result in
  let scope =
    match A.prune_mode result with
    | Everything -> "Full cleanup"
    | Stale { keep } ->
        sprintf "Stale cleanup (keeping the newest %d images)" keep
  in
  let nothing =
    List.is_empty containers && List.is_empty secrets && List.is_empty images
  in
  if dry_run then
    bprintf buffer "Dry run; nothing was changed. %s would remove:\n" scope
  else bprintf buffer "%s removed:\n" scope;
  if nothing then bprintf buffer "  nothing\n"
  else (
    List.iter containers ~f:(bprintf buffer "  container  %s\n");
    List.iter secrets ~f:(bprintf buffer "  secret     %s\n");
    List.iter images ~f:(bprintf buffer "  image      %s\n"));
  if not (List.is_empty images) then
    bprintf buffer "Image space freed: up to %s\n"
      (Nixploy.Status.human_bytes (A.prune_image_bytes result));
  List.iter (A.prune_notes result) ~f:(bprintf buffer "Note: %s\n");
  if dry_run && not nothing then
    bprintf buffer "Run again with --yes instead of --dry-run to remove them.\n";
  Buffer.contents buffer

let prune_json result =
  let module A = Nixploy.Application in
  let strings values = `List (List.map values ~f:json_string) in
  encode_json
    (`Assoc
       [
         ( "mode",
           json_string
             (match A.prune_mode result with
             | Everything -> "everything"
             | Stale _ -> "stale") );
         ( "keep",
           match A.prune_mode result with
           | Everything -> `Null
           | Stale { keep } -> `Int keep );
         ("dryRun", `Bool (A.prune_dry_run result));
         ("containers", strings (A.prune_containers result));
         ("secrets", strings (A.prune_secrets result));
         ("imageReferences", strings (A.prune_image_references result));
         ("imageBytes", json_time (A.prune_image_bytes result));
         ("route", json_string (prune_route_name (A.prune_route_state result)));
         ("notes", strings (A.prune_notes result));
         ("containersRemoved", `Int (A.prune_containers_removed result));
         ("secretsRemoved", `Int (A.prune_secrets_removed result));
         ("secretsRetained", `Int (A.prune_secrets_retained result));
       ])

let classification_name = function
  | Nixploy.Inventory.Current -> "current"
  | Declared -> "declared"
  | Orphaned -> "orphaned"
  | Other_project -> "other-project"
  | Unattributed -> "unattributed"

let image_total (images : Nixploy.Podman.owned_image list) =
  List.sum
    (module Int64)
    images
    ~f:(fun image -> Option.value image.size_bytes ~default:0L)

let resources inventory =
  let module I = Nixploy.Inventory in
  let module Target = Nixploy.Configuration.Target in
  let human = Nixploy.Status.human_bytes in
  let host = I.host inventory in
  let buffer = Buffer.create 2048 in
  bprintf buffer "Host: %s@%s:%d (via target %s)\n" (Target.user host)
    (Target.host host) (Target.port host)
    (Nixploy.Target_name.to_string (Target.name host));
  (match I.groups inventory with
  | [] -> bprintf buffer "\nNo nixploy resources found.\n"
  | groups ->
      List.iter groups ~f:(fun (group : I.group) ->
          bprintf buffer "\n%s  %s%s\n"
            (classification_name group.classification)
            group.resource_key
            (match (group.project, group.target) with
            | Some project, Some target -> sprintf "  (%s/%s)" project target
            | _ -> "");
          List.iter group.containers ~f:(fun container ->
              bprintf buffer "  container  %s  %s\n" container.name
                (Option.first_some container.status container.state
                |> value_or_dash));
          if not (List.is_empty group.secrets) then
            bprintf buffer "  secrets    %d\n" (List.length group.secrets);
          if not (List.is_empty group.images) then
            bprintf buffer "  images     %d (%s)\n" (List.length group.images)
              (human (image_total group.images));
          if group.route then bprintf buffer "  route      present\n";
          Option.iter group.marker ~f:(fun marker ->
              bprintf buffer "  marker     .nixploy-mutations/%s\n" marker);
          List.iter group.problems ~f:(bprintf buffer "  problem    %s\n")));
  let orphans =
    List.filter (I.groups inventory) ~f:(fun group ->
        match group.classification with
        | Orphaned | Other_project -> List.is_empty group.problems
        | Current | Declared | Unattributed -> false)
  in
  (match I.legacy_secrets inventory with
  | [] -> ()
  | names ->
      bprintf buffer "\nUnlabelled legacy secrets (never pruned): %s\n"
        (String.concat ~sep:", " names));
  (match I.unattributed_images inventory with
  | [] -> ()
  | images ->
      bprintf buffer "\nImages in no known resource's repository: %d (%s)\n"
        (List.length images)
        (human (image_total images)));
  (match I.unattributed_markers inventory with
  | [] -> ()
  | markers ->
      bprintf buffer "\nMutation markers with no matching resources: %s\n"
        (String.concat ~sep:", " markers));
  List.iter (I.errors inventory) ~f:(fun (section, error) ->
      bprintf buffer "\n%s %s\n" section (section_error error));
  if not (List.is_empty orphans) then (
    bprintf buffer
      "\nPreview removal of a resource whose target is gone with:\n";
    List.iter orphans ~f:(fun group ->
        bprintf buffer "  nixploy prune -t %s --orphan %s --dry-run\n"
          (Nixploy.Target_name.to_string (Target.name host))
          group.resource_key));
  Buffer.contents buffer

let resources_json inventory =
  let module I = Nixploy.Inventory in
  let strings values = `List (List.map values ~f:json_string) in
  let image (image : Nixploy.Podman.owned_image) =
    `Assoc
      [
        ("id", `String image.image_id);
        ("references", strings image.references);
        ( "sizeBytes",
          Option.value_map image.size_bytes ~default:`Null ~f:json_int64 );
        ("containers", `Int image.containers);
      ]
  in
  encode_json
    (`Assoc
       [
         ( "host",
           json_string (Nixploy.Configuration.Target.host (I.host inventory)) );
         ( "resources",
           `List
             (List.map (I.groups inventory) ~f:(fun (group : I.group) ->
                  `Assoc
                    [
                      ("resourceKey", `String group.resource_key);
                      ( "classification",
                        `String (classification_name group.classification) );
                      ("project", json_option group.project);
                      ("target", json_option group.target);
                      ("repository", json_option group.repository);
                      ( "containers",
                        `List
                          (List.map group.containers ~f:(fun container ->
                               `Assoc
                                 [
                                   ("id", `String container.id);
                                   ("name", `String container.name);
                                   ("state", json_option container.state);
                                   ("status", json_option container.status);
                                 ])) );
                      ( "secrets",
                        strings
                          (List.map group.secrets ~f:(fun secret -> secret.name))
                      );
                      ("images", `List (List.map group.images ~f:image));
                      ("route", `Bool group.route);
                      ("marker", json_option group.marker);
                      ("problems", strings group.problems);
                    ])) );
         ("legacySecrets", strings (I.legacy_secrets inventory));
         ( "unattributedImages",
           `List (List.map (I.unattributed_images inventory) ~f:image) );
         ("unattributedMarkers", strings (I.unattributed_markers inventory));
         ( "errors",
           `List
             (List.map (I.errors inventory) ~f:(fun (section, error) ->
                  `Assoc
                    [
                      ("section", `String section);
                      ("error", `String (Error.to_string_hum error));
                    ])) );
       ])

let orphan_prune result =
  let module O = Nixploy.Orphan_prune in
  let buffer = Buffer.create 512 in
  if O.dry_run result then
    bprintf buffer "Dry run; nothing was changed. Would remove %s (%s/%s):\n"
      (O.resource_key result) (O.project result) (O.target result)
  else
    bprintf buffer "Removed %s (%s/%s):\n" (O.resource_key result)
      (O.project result) (O.target result);
  List.iter (O.containers result) ~f:(bprintf buffer "  container  %s\n");
  List.iter (O.secrets result) ~f:(bprintf buffer "  secret     %s\n");
  List.iter (O.image_references result) ~f:(bprintf buffer "  image      %s\n");
  if not (List.is_empty (O.image_references result)) then
    bprintf buffer "Image space freed: up to %s\n"
      (Nixploy.Status.human_bytes (O.image_bytes result));
  if O.dry_run result then
    bprintf buffer "Run again with --yes instead of --dry-run to remove them.\n";
  Buffer.contents buffer

let orphan_prune_json result =
  let module O = Nixploy.Orphan_prune in
  let strings values = `List (List.map values ~f:json_string) in
  encode_json
    (`Assoc
       [
         ("mode", `String "orphan");
         ("resourceKey", `String (O.resource_key result));
         ("project", `String (O.project result));
         ("target", `String (O.target result));
         ("dryRun", `Bool (O.dry_run result));
         ("containers", strings (O.containers result));
         ("secrets", strings (O.secrets result));
         ("imageReferences", strings (O.image_references result));
         ("imageBytes", json_int64 (O.image_bytes result));
       ])

let stopped_text ~label ~route_removed ~containers =
  let buffer = Buffer.create 256 in
  bprintf buffer "Stopped %s:\n" label;
  if route_removed then bprintf buffer "  route      removed\n";
  (match containers with
  | [] -> bprintf buffer "  no owned containers\n"
  | containers ->
      List.iter containers
        ~f:(bprintf buffer "  container  %s (restart disabled)\n"));
  bprintf buffer "Deploy to start it again, or prune with --yes to remove it.\n";
  Buffer.contents buffer

let stop result =
  let module S = Nixploy.Stop in
  stopped_text
    ~label:(Nixploy.Target_name.to_string (S.target result))
    ~route_removed:(S.route_removed result) ~containers:(S.containers result)

let stop_json result =
  let module S = Nixploy.Stop in
  encode_json
    (`Assoc
       [
         ("project", `String (Nixploy.Project_name.to_string (S.project result)));
         ("target", `String (Nixploy.Target_name.to_string (S.target result)));
         ( "resourceKey",
           `String (Nixploy.Resource_key.to_string (S.resource_key result)) );
         ("routeRemoved", `Bool (S.route_removed result));
         ("containers", `List (List.map (S.containers result) ~f:json_string));
       ])

let orphan_stop result =
  let module O = Nixploy.Orphan_prune in
  stopped_text
    ~label:
      (sprintf "%s (%s/%s)" (O.stopped_key result) (O.stopped_project result)
         (O.stopped_target result))
    ~route_removed:(O.stopped_route_removed result)
    ~containers:(O.stopped_containers result)
  |> String.substr_replace_first ~pattern:"Deploy to start it again, or prune"
       ~with_:"Prune it with --orphan and"

let orphan_stop_json result =
  let module O = Nixploy.Orphan_prune in
  encode_json
    (`Assoc
       [
         ("resourceKey", `String (O.stopped_key result));
         ("project", `String (O.stopped_project result));
         ("target", `String (O.stopped_target result));
         ("routeRemoved", `Bool (O.stopped_route_removed result));
         ( "containers",
           `List (List.map (O.stopped_containers result) ~f:json_string) );
       ])
