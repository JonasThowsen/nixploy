let handle ~applications ~cancel query =
  match
    Nixploy.Managed_application.find applications
      query.Protocol.Cancel_deployment_v1.Query.application
  with
  | Error error -> Async.Deferred.return (Error error)
  | Ok application -> cancel ~application ~operation_id:query.operation_id
