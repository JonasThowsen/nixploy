open Async
open Core

let run directory =
  let open Deferred.Or_error.Let_syntax in
  let%bind selection = Nixploy.Source.local ~working_directory:directory in
  let%bind source =
    Nixploy.Source.prepare ~working_directory:directory ~selection
  in
  Monitor.protect
    ~finally:(fun () -> Nixploy.Source.cleanup source)
    (fun () ->
      let source_module =
        Filename.concat
          (Nixploy.Source.path source)
          "lib/nixploy_expo_fixture.ex"
      in
      let%bind () =
        Deferred.return
          (Or_error.try_with (fun () ->
               let contents = In_channel.read_all source_module in
               if not (String.is_substring contents ~substring:":dirty") then
                 failwith "prepared source omitted the tracked dirty edit";
               if
                 Sys_unix.file_exists_exn
                   (Filename.concat
                      (Nixploy.Source.path source)
                      "deps/expo/src")
               then
                 failwith "prepared source retained ignored Expo dependencies";
               if
                 Sys_unix.file_exists_exn
                   (Filename.concat (Nixploy.Source.nix_root source) ".git")
               then failwith "prepared source retained Git metadata"))
      in
      let build () =
        Nixploy.Process_runner.run_stdout
          ~working_directory:(Nixploy.Source.nix_root source)
          ~timeout:(Time_ns.Span.of_min 10.) ~max_output_bytes:262_144
          ~prog:"nix"
          ~args:
            (Nixploy.Nix_command.build_args
               ~flake:(Nixploy.Source.nix_flake source)
               ~output:"default")
          ()
      in
      let%bind first = build () in
      let%bind second = build () in
      if String.equal first second then Deferred.Or_error.return first
      else
        Deferred.Or_error.error_string
          "repeated prepared-source builds returned different outputs")

let command =
  Async.Command.async
    ~summary:"Build the Mix/Expo fixture through Nixploy's prepared source"
    (let%map_open.Command directory = anon ("DIRECTORY" %: string) in
     fun () ->
       let%map result = run directory in
       let output = Or_error.ok_exn result in
       printf "Mix/Expo prepared-source build: %s\n%!" (String.strip output))

let () = Command_unix.run command
