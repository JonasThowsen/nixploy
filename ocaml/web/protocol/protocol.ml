open! Core
open! Async_rpc_kernel

module Deployment = struct
  module State = struct
    type t = Requested | Running | Succeeded | Failed
    [@@deriving bin_io, compare, equal, sexp]
  end

  type t = {
    id : string;
    state : State.t;
    stage : string;
    message : string;
    revision : string option;
    container_name : string option;
    error : string option;
    updated_at_ms : int64;
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

module List_applications = struct
  let t =
    Rpc.Rpc.create ~name:"list-applications" ~version:0
      ~bin_query:[%bin_type_class: unit]
      ~bin_response:[%bin_type_class: Application.t list Or_error.t]
      ~include_in_error_count:Or_error
end

module Deploy = struct
  module Query = struct
    type t = { application : string } [@@deriving bin_io, sexp]
  end

  let t =
    Rpc.Rpc.create ~name:"deploy" ~version:0
      ~bin_query:[%bin_type_class: Query.t]
      ~bin_response:[%bin_type_class: string Or_error.t]
      ~include_in_error_count:Or_error
end
