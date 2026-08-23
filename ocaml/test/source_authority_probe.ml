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
       | Ok authority -> (
           let protected_git =
             Nixploy.Source_authority.protected_git authority |> Or_error.ok_exn
           in
           let commit = Nixploy.Source_authority.commit authority in
           let%bind source =
             Nixploy.Source.prepare_protected
               ~working_directory:
                 (Nixploy.Managed_application.working_directory application)
               ~protected_git
               ~repository_identity:
                 (Nixploy.Managed_application.repository_identity application)
               ~commit
           in
           match source with
           | Error error ->
               eprintf "%s\n" (Error.to_string_hum error);
               Shutdown.exit 1
           | Ok source ->
               Monitor.protect
                 ~finally:(fun () -> Nixploy.Source.cleanup source)
                 (fun () ->
                   let materialized =
                     In_channel.read_all
                       (Filename.concat
                          (Nixploy.Source.path source)
                          "flake.nix")
                   in
                   let object_path =
                     let subdirectory =
                       Nixploy.Managed_application.working_directory application
                       |> String.chop_prefix_exn
                            ~prefix:
                              (Nixploy.Managed_application.repository
                                 application)
                       |> String.chop_prefix_if_exists ~prefix:"/"
                     in
                     if String.is_empty subdirectory then "flake.nix"
                     else subdirectory ^ "/flake.nix"
                   in
                   let%bind committed =
                     Nixploy.Protected_git.stdout protected_git
                       [
                         "cat-file";
                         "blob";
                         Nixploy.Source_authority.revision authority
                         ^ ":" ^ object_path;
                       ]
                   in
                   match committed with
                   | Ok committed when String.equal committed materialized ->
                       printf "%s %s\n"
                         (Nixploy.Source_authority.revision authority)
                         (Digestif.SHA256.digest_string materialized
                         |> Digestif.SHA256.to_hex);
                       Deferred.unit
                   | Ok _ ->
                       eprintf
                         "materialized flake.nix differs from committed blob\n";
                       Shutdown.exit 1
                   | Error error ->
                       eprintf "%s\n" (Error.to_string_hum error);
                       Shutdown.exit 1))
       | Error error ->
           eprintf "%s\n" (Error.to_string_hum error);
           Shutdown.exit 1)

let () = Command_unix.run command
