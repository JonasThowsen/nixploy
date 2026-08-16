open! Core
open! Async
module Application = Nixploy.Application
module Managed_application = Nixploy.Managed_application
module Resource_state_response = Resource_state_response

let protocol_state = function
  | Application.Requested -> Protocol.Deployment.State.Requested
  | Running -> Running
  | Succeeded -> Succeeded
  | Failed -> Failed
  | Cancelled -> Cancelled

let protocol_commit deployment =
  Application.deployment_revision deployment
  |> Option.map ~f:(fun revision ->
      {
        Protocol.Commit.revision;
        subject =
          Application.deployment_commit_subject deployment
          |> Option.value ~default:"Commit subject unavailable";
        timestamp_ms =
          Application.deployment_commit_timestamp_ms deployment
          |> Option.value
               ~default:(Application.deployment_requested_at_ms deployment);
      })

let deployment ~now_ms ~can_cancel deployment =
  let state = Application.deployment_state deployment in
  let can_cancel =
    can_cancel
    &&
    match state with
    | Requested | Running -> true
    | Succeeded | Failed | Cancelled -> false
  in
  let started_at_ms = Application.deployment_started_at_ms deployment in
  let finished_at_ms = Application.deployment_finished_at_ms deployment in
  {
    Protocol.Deployment.id = Application.deployment_id deployment;
    state = protocol_state state;
    stage = Application.deployment_stage deployment;
    message = Application.deployment_message deployment;
    commit = protocol_commit deployment;
    container_name = Application.deployment_container_name deployment;
    error = Application.deployment_error deployment;
    requested_at_ms = Application.deployment_requested_at_ms deployment;
    started_at_ms;
    finished_at_ms;
    elapsed_ms =
      Option.map started_at_ms ~f:(fun started ->
          let finished = Option.value finished_at_ms ~default:now_ms in
          Int64.max 0L Int64.(finished - started));
    cancel_requested_at_ms =
      Application.deployment_cancel_requested_at_ms deployment;
    updated_at_ms = Application.deployment_updated_at_ms deployment;
    can_cancel;
  }

let application managed ~resource_state ~deployment =
  {
    Protocol.Application.key = Managed_application.key managed;
    project =
      Managed_application.project managed |> Nixploy.Project_name.to_string;
    target = Managed_application.target managed |> Nixploy.Target_name.to_string;
    repository = Managed_application.repository_identity managed;
    resource_state = Resource_state_response.of_application resource_state;
    deployment;
  }

let recent_deployment ~application ~deployment =
  {
    Protocol.Recent_deployment.application = Managed_application.key application;
    deployment;
  }

let cancellation (_ : Application.cancellation_result) = ()

let log_snapshot ~application (snapshot : Application.log_snapshot) =
  {
    Protocol.Log_snapshot.application;
    container_name = snapshot.Application.container_name;
    revision = snapshot.revision;
    observed_at_ms = snapshot.observed_at_ms;
    lines =
      List.map snapshot.lines ~f:(fun line ->
          { Protocol.Log_line.timestamp = line.timestamp; text = line.text });
    truncated = snapshot.truncated;
  }

let protocol_health = function
  | Application.Healthy -> Protocol.Health.Healthy
  | Unhealthy -> Unhealthy
  | Unavailable error -> Unavailable error

let target_metrics (metrics : Application.target_metrics) =
  {
    Protocol.Target_metrics.target = metrics.target;
    host = metrics.host;
    observed_at_ms = metrics.observed_at_ms;
    error = metrics.error;
    cpu_percent = metrics.cpu_percent;
    memory_used_bytes = metrics.memory_used_bytes;
    memory_total_bytes = metrics.memory_total_bytes;
    filesystem_used_bytes = metrics.filesystem_used_bytes;
    filesystem_total_bytes = metrics.filesystem_total_bytes;
    load_1 = metrics.load_1;
    load_5 = metrics.load_5;
    load_15 = metrics.load_15;
    uptime_seconds = metrics.uptime_seconds;
    applications =
      List.map metrics.applications ~f:(fun application ->
          {
            Protocol.Application_metrics.application = application.application;
            container_name = application.container_name;
            health = protocol_health application.health;
            error = application.error;
            cpu_percent = application.cpu_percent;
            memory_used_bytes = application.memory_used_bytes;
            memory_host_percent = application.memory_host_percent;
            uptime_seconds = application.uptime_seconds;
          });
  }

let merge_target_metrics targets (metric : Protocol.Target_metrics.t) =
  match
    List.findi targets ~f:(fun _ existing ->
        String.equal existing.Protocol.Target_metrics.host metric.host
        && not (String.equal existing.host "unavailable"))
  with
  | None -> targets @ [ metric ]
  | Some (index, existing) ->
      List.mapi targets ~f:(fun current item ->
          if Int.equal current index then
            {
              existing with
              applications = existing.applications @ metric.applications;
            }
          else item)

let max_concurrent_metrics = 4

let collect_metrics applications ~observe =
  let%map metrics =
    Deferred.List.map applications
      ~how:(`Max_concurrent_jobs max_concurrent_metrics) ~f:(fun application ->
        observe application >>| target_metrics)
  in
  List.fold metrics ~init:[] ~f:merge_target_metrics
