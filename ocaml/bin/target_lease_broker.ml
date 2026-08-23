open Core

let parse_scope_user value =
  match String.lsplit2 value ~on:':' with
  | Some (scope, user) when not (String.is_empty scope || String.is_empty user)
    ->
      Ok (scope, user)
  | _ -> Or_error.error_string "--scope-user must be SCOPE:USER"

let command =
  Command.basic ~summary:"Run the dedicated fail-closed target-lease broker"
    (let%map_open.Command socket_path =
       flag "--socket" (required string) ~doc:"PATH broker-owned Unix socket"
     and state_directory =
       flag "--state-directory" (required string)
         ~doc:"PATH broker-private durable state directory"
     and authority =
       flag "--authority" (required string) ~doc:"UUID fixed broker authority"
     and identity =
       flag "--identity" (required string)
         ~doc:"UUID fixed build/config identity"
     and scope_users =
       flag "--scope-user" (listed string)
         ~doc:"SCOPE:USER per-scope Unix peer allowlist (repeatable)"
     in
     fun () ->
       match Or_error.all (List.map scope_users ~f:parse_scope_user) with
       | Error error ->
           eprintf "%s\n%!" (Error.to_string_hum error);
           exit 2
       | Ok scope_users -> (
           let grouped =
             List.fold scope_users ~init:[] ~f:(fun groups (scope, user) ->
                 match List.Assoc.find groups scope ~equal:String.equal with
                 | None -> (scope, [ user ]) :: groups
                 | Some users ->
                     (scope, users @ [ user ])
                     :: List.Assoc.remove groups scope ~equal:String.equal)
           in
           match
             Nixploy.Target_lease_broker.create_configuration
               ~broker_uid:(Caml_unix.geteuid ()) ~socket_path ~state_directory
               ~authority ~identity ~scope_users:grouped
           with
           | Error error ->
               eprintf "%s\n%!" (Error.to_string_hum error);
               exit 2
           | Ok configuration -> (
               match Nixploy.Target_lease_broker.run configuration with
               | Ok () -> ()
               | Error error ->
                   eprintf "%s\n%!" (Error.to_string_hum error);
                   exit 1)))

let () = Command_unix.run ~version:"0.1.0-ocaml" command
