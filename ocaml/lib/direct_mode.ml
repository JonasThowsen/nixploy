open Core

let validate_configuration configuration ~target =
  match Configuration.control_plane configuration with
  | Some _ ->
      Or_error.error_string
        "NIXPLOY_CONTROL_PLANE_REMOVED: remove obsolete controlPlane \
         configuration; nixploy now executes directly over SSH"
  | None ->
      let open Or_error.Let_syntax in
      let%map _ = Configuration.find_target configuration target in
      ()
