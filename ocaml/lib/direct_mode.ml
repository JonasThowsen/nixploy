open Core

let validate_configuration configuration ~target =
  match Configuration.control_plane configuration with
  | Some _ ->
      Or_error.error_string
        "NIXPLOY_DIRECT_MANAGED_DECLARATION: a flake declaring controlPlane \
         identity cannot use local execution"
  | None ->
      let open Or_error.Let_syntax in
      let%bind target = Configuration.find_target configuration target in
      if Option.is_some (Configuration.Target.non_production target) then Ok ()
      else
        Or_error.error_string
          "NIXPLOY_DIRECT_NON_PRODUCTION_REQUIRED: local execution requires \
           an explicitly declared nonProduction target"
