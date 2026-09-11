open Async
open Core

let target_flag =
  let open Command.Param in
  Command.Param.flag "--target" (required string) ~aliases:[ "-t" ]
    ~doc:"TARGET target declared by .#nixploy"

let directory_flag =
  let open Command.Param in
  Command.Param.flag "--directory"
    (optional_with_default "." string)
    ~aliases:[ "-C" ] ~doc:"DIRECTORY local project flake directory"

let with_target raw f =
  match Nixploy.Target_name.of_string raw with
  | Ok target -> f target
  | Error error ->
      eprintf "%s\n%!" (Error.to_string_hum error);
      Shutdown.exit 2

let report_error error =
  eprintf "Runbook failed: %s\n%!" (Error.to_string_hum error);
  let exit_code =
    Option.value_map (Nixploy.Process_runner.termination_signal ()) ~default:1
      ~f:(fun signal -> 128 + Signal_unix.to_system_int signal)
  in
  Shutdown.exit exit_code

let print_selection (selection : Nixploy.Runbook.selection) =
  eprintf "Container %s (%s), deployed revision %s\n%!" selection.container_name
    selection.container_id
    (Option.value selection.revision ~default:"unknown");
  Deferred.unit

let commands ~list ~run =
  let list_command =
    Async.Command.async
      ~summary:"List named commands from the selected local flake"
      (let%map_open.Command target = target_flag
       and working_directory = directory_flag
       and json =
         flag "--json" no_arg ~doc:" emit command descriptions as JSON"
       in
       fun () ->
         with_target target (fun target ->
             let%bind result = list ~working_directory ~target in
             match result with
             | Error error -> report_error error
             | Ok commands ->
                 let module C = Nixploy.Configuration.Runbook_command in
                 if json then
                   printf "%s\n%!"
                     (Yojson.Safe.to_string
                        (`List
                           (List.map commands ~f:(fun command ->
                                `Assoc
                                  [
                                    ("name", `String (C.name command));
                                    ( "description",
                                      `String (C.description command) );
                                    ( "interactive",
                                      `Bool (C.interactive command) );
                                  ]))))
                 else if List.is_empty commands then
                   printf "No runbook commands declared.\n%!"
                 else
                   List.iter commands ~f:(fun command ->
                       printf "%s%s  %s\n%!" (C.name command)
                         (if C.interactive command then " (interactive)" else "")
                         (C.description command));
                 Deferred.unit))
  in
  let run_command =
    Async.Command.async
      ~summary:
        "Execute a named command in the verified running container (never \
         retried)"
      (let%map_open.Command target = target_flag
       and working_directory = directory_flag
       and name = anon ("NAME" %: string) in
       fun () ->
         with_target target (fun target ->
             let%bind result =
               run ~on_selection:print_selection ~working_directory ~target
                 ~name
             in
             match result with
             | Error error -> report_error error
             | Ok (outcome : Nixploy.Runbook.outcome) ->
                 Option.iter outcome.uncertainty ~f:(fun message ->
                     eprintf "%s\n%!" message);
                 Shutdown.exit outcome.exit_code))
  in
  [ ("runbook", list_command); ("run", run_command) ]
