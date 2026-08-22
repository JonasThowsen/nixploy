open Core

let command =
  Command.basic ~summary:"Run the dedicated fail-closed target-lease broker"
    (let%map_open.Command socket_path =
       flag "--socket" (required string) ~doc:"PATH broker-owned Unix socket"
     and state_directory =
       flag "--state-directory" (required string)
         ~doc:"PATH broker-private durable state directory"
     and authority =
       flag "--authority" (required string) ~doc:"UUID fixed broker authority"
     and scopes =
       flag "--scope" (listed string)
         ~doc:"UUID allowlisted coordination scope (repeatable)"
     and allowed_users =
       flag "--allow-user" (listed string)
         ~doc:"USER allowlisted Unix identity (repeatable)"
     in
     fun () ->
       match
         Nixploy.Target_lease_broker.create_configuration ~socket_path
           ~state_directory ~authority ~scopes ~allowed_users
       with
       | Error error ->
           eprintf "%s\n%!" (Error.to_string_hum error);
           exit 2
       | Ok configuration -> (
           match Nixploy.Target_lease_broker.run configuration with
           | Ok () -> ()
           | Error error ->
               eprintf "%s\n%!" (Error.to_string_hum error);
               exit 1))

let () = Command_unix.run ~version:"0.1.0-ocaml" command
