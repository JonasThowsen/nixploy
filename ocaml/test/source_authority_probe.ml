open Async
open Core

let command =
  Async.Command.async ~summary:"Verify one managed source authority"
    (let%map_open.Command key = anon ("APPLICATION" %: string) in
     fun () ->
       let open Deferred.Let_syntax in
       let applications =
         Nixploy.Managed_application.load_authority_file () |> Or_error.ok_exn
       in
       let application =
         Nixploy.Managed_application.find applications key |> Or_error.ok_exn
       in
       let%bind authority = Nixploy.Source_authority.verify application in
       match authority with
       | Ok authority ->
           printf "%s\n" (Nixploy.Source_authority.revision authority);
           Deferred.unit
       | Error error ->
           eprintf "%s\n" (Error.to_string_hum error);
           Shutdown.exit 1)

let () = Command_unix.run command
