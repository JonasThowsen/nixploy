let of_application = function
  | Nixploy.Application.Unknown -> Protocol.Resource_state.Unknown
  | Present -> Present
  | Absent -> Absent
