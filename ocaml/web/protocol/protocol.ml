open! Core
open! Async_rpc_kernel

module Commit = struct
  type t = { revision : string; subject : string; timestamp_ms : int64 }
  [@@deriving bin_io, equal, sexp]
end

module Deployment = struct
  module State = struct
    type t = Requested | Running | Succeeded | Failed | Cancelled
    [@@deriving bin_io, compare, equal, sexp]
  end

  type t = {
    id : string;
    state : State.t;
    stage : string;
    message : string;
    commit : Commit.t option;
    container_name : string option;
    error : string option;
    requested_at_ms : int64;
    started_at_ms : int64 option;
    finished_at_ms : int64 option;
    elapsed_ms : int64 option;
    cancel_requested_at_ms : int64 option;
    updated_at_ms : int64;
    can_cancel : bool;
  }
  [@@deriving bin_io, equal, sexp]
end

module Application = struct
  type t = {
    key : string;
    project : string;
    target : string;
    repository : string;
    deployment : Deployment.t option;
  }
  [@@deriving bin_io, equal, sexp]
end

module Recent_deployment = struct
  type t = { application : string; deployment : Deployment.t }
  [@@deriving bin_io, equal, sexp]
end

module Preview_deployment = struct
  module Query = struct
    type t = { application : string } [@@deriving bin_io, equal, sexp]
  end

  let t =
    Rpc.Rpc.create ~name:"preview-deployment" ~version:0
      ~bin_query:[%bin_type_class: Query.t]
      ~bin_response:[%bin_type_class: Commit.t Or_error.t]
      ~include_in_error_count:Or_error
end

module List_applications = struct
  let t =
    Rpc.Rpc.create ~name:"list-applications" ~version:1
      ~bin_query:[%bin_type_class: unit]
      ~bin_response:[%bin_type_class: Application.t list Or_error.t]
      ~include_in_error_count:Or_error
end

module Deploy = struct
  module Query = struct
    type t = { application : string; revision : string }
    [@@deriving bin_io, equal, sexp]
  end

  let t =
    Rpc.Rpc.create ~name:"start-deployment" ~version:0
      ~bin_query:[%bin_type_class: Query.t]
      ~bin_response:[%bin_type_class: string Or_error.t]
      ~include_in_error_count:Or_error
end

module List_deployments = struct
  module Query = struct
    type t = { application : string option } [@@deriving bin_io, equal, sexp]
  end

  let t =
    Rpc.Rpc.create ~name:"list-deployments" ~version:0
      ~bin_query:[%bin_type_class: Query.t]
      ~bin_response:[%bin_type_class: Recent_deployment.t list Or_error.t]
      ~include_in_error_count:Or_error
end

module Cancel_deployment = struct
  module Query = struct
    type t = { operation_id : string } [@@deriving bin_io, equal, sexp]
  end

  let t =
    Rpc.Rpc.create ~name:"cancel-deployment" ~version:0
      ~bin_query:[%bin_type_class: Query.t]
      ~bin_response:[%bin_type_class: unit Or_error.t]
      ~include_in_error_count:Or_error
end

module Log_line = struct
  type t = { timestamp : string option; text : string }
  [@@deriving bin_io, equal, sexp]
end

module Log_snapshot = struct
  type t = {
    application : string;
    container_name : string;
    revision : string option;
    observed_at_ms : int64;
    lines : Log_line.t list;
    truncated : bool;
  }
  [@@deriving bin_io, equal, sexp]
end

module Get_application_logs = struct
  module Query = struct
    type t = { application : string option } [@@deriving bin_io, equal, sexp]
  end

  let t =
    Rpc.Rpc.create ~name:"get-application-logs" ~version:0
      ~bin_query:[%bin_type_class: Query.t]
      ~bin_response:[%bin_type_class: Log_snapshot.t option Or_error.t]
      ~include_in_error_count:Or_error
end

module Health = struct
  type t = Healthy | Unhealthy | Unavailable of string
  [@@deriving bin_io, equal, sexp]
end

module Application_metrics = struct
  type t = {
    application : string;
    container_name : string option;
    health : Health.t;
    error : string option;
    cpu_percent : float option;
    memory_used_bytes : int64 option;
    memory_host_percent : float option;
    uptime_seconds : int64 option;
  }
  [@@deriving bin_io, equal, sexp]
end

module Target_metrics = struct
  type t = {
    target : string;
    host : string;
    observed_at_ms : int64;
    error : string option;
    cpu_percent : float option;
    memory_used_bytes : int64 option;
    memory_total_bytes : int64 option;
    filesystem_used_bytes : int64 option;
    filesystem_total_bytes : int64 option;
    load_1 : float option;
    load_5 : float option;
    load_15 : float option;
    uptime_seconds : int64 option;
    applications : Application_metrics.t list;
  }
  [@@deriving bin_io, equal, sexp]
end

module Get_metrics = struct
  let t =
    Rpc.Rpc.create ~name:"get-metrics" ~version:0
      ~bin_query:[%bin_type_class: unit]
      ~bin_response:[%bin_type_class: Target_metrics.t list Or_error.t]
      ~include_in_error_count:Or_error
end
