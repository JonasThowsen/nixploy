open Core

let validate_configuration configuration ~target =
  let open Or_error.Let_syntax in
  let%bind () = Configuration.require_daemonless configuration in
  let%map _ = Configuration.find_target configuration target in
  ()
