open Core
open Async_rpc_kernel

module Commit : sig
  type t = { revision : string; subject : string; timestamp_ms : int64 }
  [@@deriving bin_io, equal, sexp]
end

module Deployment_preview : sig
  type t = { commit : Commit.t; receipt : string; prune_receipt : string }
  [@@deriving bin_io, equal, sexp]
end

module Deployment : sig
  module State : sig
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

module Resource_state : sig
  type t = Unknown | Present | Absent
  [@@deriving bin_io, compare, equal, sexp]
end

module Application : sig
  type t = {
    key : string;
    project : string;
    target : string;
    repository : string;
    resource_state : Resource_state.t;
    deployment : Deployment.t option;
  }
  [@@deriving bin_io, equal, sexp]
end

module Recent_deployment : sig
  type t = { application : string; deployment : Deployment.t }
  [@@deriving bin_io, equal, sexp]
end

module Control_plane_capabilities : sig
  module Query : sig
    type t = {
      protocol_major : int;
      protocol_minor : int;
      required_capabilities : string list;
    }
    [@@deriving bin_io, equal, sexp]
  end

  type t = {
    control_plane_id : string;
    package_revision : string;
    protocol_major : int;
    protocol_minor : int;
    deployment_config_schemas : string list;
    capabilities : string list;
  }
  [@@deriving bin_io, equal, sexp]

  val t : (Query.t, t Or_error.t) Rpc.Rpc.t
end

module Preview_deployment : sig
  module Query : sig
    type t = { application : string } [@@deriving bin_io, equal, sexp]
  end

  val t : (Query.t, Deployment_preview.t Or_error.t) Rpc.Rpc.t
end

module List_applications : sig
  val t : (unit, Application.t list Or_error.t) Rpc.Rpc.t
end

module Deploy : sig
  module Query : sig
    type t = { application : string } [@@deriving bin_io, equal, sexp]
  end

  val t : (Query.t, string Or_error.t) Rpc.Rpc.t
end

module Admit_managed_deployment : sig
  module Query : sig
    type t = {
      managed_application_key : string;
      requested_target : string;
      provenance : string;
      revision : string;
    }
    [@@deriving bin_io, equal, sexp]
  end

  module Response : sig
    type t = { operation_id : string; update_sequence : int64 }
    [@@deriving bin_io, equal, sexp]
  end

  val t : (Query.t, Response.t Or_error.t) Rpc.Rpc.t
end

module List_deployments : sig
  module Query : sig
    type t = { application : string option } [@@deriving bin_io, equal, sexp]
  end

  val t : (Query.t, Recent_deployment.t list Or_error.t) Rpc.Rpc.t
end

module Cancel_deployment : sig
  module Query : sig
    type t = { operation_id : string } [@@deriving bin_io, equal, sexp]
  end

  val t : (Query.t, unit Or_error.t) Rpc.Rpc.t
end

module Cancel_deployment_v1 : sig
  module Query : sig
    type t = { application : string; operation_id : string }
    [@@deriving bin_io, equal, sexp]
  end

  val t : (Query.t, unit Or_error.t) Rpc.Rpc.t
end

module Prune_result : sig
  module Route : sig
    type t = Not_configured | Missing | Removed
    [@@deriving bin_io, equal, sexp]
  end

  type t = {
    project : string;
    target : string;
    resource_key : string;
    containers_removed : int;
    secrets_removed : int;
    route : Route.t;
  }
  [@@deriving bin_io, equal, sexp]
end

module Prune : sig
  module Query : sig
    type t = { application : string; receipt : string }
    [@@deriving bin_io, equal, sexp]
  end

  val t : (Query.t, Prune_result.t Or_error.t) Rpc.Rpc.t
end

module Log_line : sig
  type t = { timestamp : string option; text : string }
  [@@deriving bin_io, equal, sexp]
end

module Log_snapshot : sig
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

module Get_application_logs : sig
  module Query : sig
    type t = { application : string option } [@@deriving bin_io, equal, sexp]
  end

  val t : (Query.t, Log_snapshot.t option Or_error.t) Rpc.Rpc.t
end

module Health : sig
  type t = Healthy | Unhealthy | Unavailable of string
  [@@deriving bin_io, equal, sexp]
end

module Application_metrics : sig
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

module Metrics_freshness : sig
  type t = Fresh | Stale | Unavailable [@@deriving bin_io, equal, sexp]
end

module Target_metrics : sig
  type t = {
    target : string;
    host : string;
    observed_at_ms : int64;
    freshness : Metrics_freshness.t;
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

module Get_metrics : sig
  val t : (unit, Target_metrics.t list Or_error.t) Rpc.Rpc.t
end
