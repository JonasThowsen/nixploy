open Async
open Core

type t = {
  workspace : string;
  path : string;
  revision : string;
  repository : string;
}

let git_timeout = Time_ns.Span.of_min 2.
let max_git_output = 262_144
let path t = t.path
let revision t = t.revision
let repository t = t.repository

let git ?working_directory args =
  Process_runner.run_stdout ?working_directory ~timeout:git_timeout
    ~max_output_bytes:max_git_output ~prog:"git" ~args ()

let valid_revision revision =
  String.length revision = 40
  && String.for_all revision ~f:(fun character ->
      Char.is_digit character
      || (Char.compare character 'a' >= 0 && Char.compare character 'f' <= 0))

let cleanup t =
  let%map _ =
    Process_runner.run_stdout ~timeout:(Time_ns.Span.of_sec 30.)
      ~max_output_bytes:65_536 ~prog:"rm" ~ignore_termination:true
      ~args:[ "-rf"; "--"; t.workspace ]
      ()
  in
  ()

let prepare ~working_directory =
  let open Deferred.Or_error.Let_syntax in
  let working_directory = Filename_unix.realpath working_directory in
  let%bind revision =
    git ~working_directory
      [ "rev-parse"; "--verify"; "refs/heads/main^{commit}" ]
  in
  let revision = String.strip revision in
  let%bind () =
    if valid_revision revision then Deferred.Or_error.return ()
    else
      Deferred.Or_error.error_string
        "refs/heads/main did not resolve to a full Git revision"
  in
  let%bind repository =
    git ~working_directory [ "config"; "--get"; "remote.origin.url" ]
  in
  let repository = String.strip repository in
  let workspace = Filename_unix.temp_dir "nixploy-" "" in
  let source_path = Filename.concat workspace "source" in
  let provisional = { workspace; path = source_path; revision; repository } in
  let result =
    let%bind _ =
      git
        [
          "clone";
          "--no-checkout";
          "--local";
          "--no-hardlinks";
          "--";
          working_directory;
          source_path;
        ]
    in
    let%bind _ =
      git ~working_directory:source_path [ "checkout"; "--detach"; revision ]
    in
    let%bind dirty =
      git ~working_directory:source_path [ "status"; "--porcelain" ]
    in
    let%bind () =
      if String.is_empty (String.strip dirty) then Deferred.Or_error.return ()
      else Deferred.Or_error.error_string "materialized main checkout is dirty"
    in
    let%bind gitlinks =
      git ~working_directory:source_path [ "ls-files"; "--stage" ]
    in
    let%bind () =
      if
        String.split_lines gitlinks
        |> List.exists ~f:(fun line -> String.is_prefix line ~prefix:"160000 ")
      then Deferred.Or_error.error_string "Git submodules are not supported"
      else Deferred.Or_error.return ()
    in
    let%bind () =
      if
        Sys_unix.file_exists_exn (Filename.concat source_path "flake.nix")
        && Sys_unix.file_exists_exn (Filename.concat source_path "flake.lock")
      then Deferred.Or_error.return ()
      else
        Deferred.Or_error.error_string
          "main must contain committed flake.nix and flake.lock"
    in
    Deferred.Or_error.return provisional
  in
  match%bind.Deferred result with
  | Ok source -> Deferred.Or_error.return source
  | Error error ->
      let%map.Deferred () = cleanup provisional in
      Error error
