open Async
open Core

type t = {
  workspace : string;
  path : string;
  revision : string;
  repository : string;
}

type commit = { revision : string; subject : string; timestamp_ms : int64 }

let git_timeout = Time_ns.Span.of_min 2.
let max_git_output = 262_144
let path (source : t) = source.path
let revision (source : t) = source.revision
let repository (source : t) = source.repository
let commit_revision (commit : commit) = commit.revision
let commit_subject (commit : commit) = commit.subject
let commit_timestamp_ms (commit : commit) = commit.timestamp_ms

let git ?working_directory args =
  Process_runner.run_stdout ?working_directory ~timeout:git_timeout
    ~max_output_bytes:max_git_output ~prog:"git" ~args ()

let valid_revision revision =
  String.length revision = 40
  && String.for_all revision ~f:(fun character ->
      Char.is_digit character
      || (Char.compare character 'a' >= 0 && Char.compare character 'f' <= 0))

let parse_commit output =
  match String.rstrip output |> String.split ~on:'\000' with
  | [ revision; subject; timestamp ] when valid_revision revision ->
      let open Or_error.Let_syntax in
      let%bind timestamp_seconds =
        Or_error.try_with (fun () -> Int64.of_string timestamp)
      in
      let%bind timestamp_ms =
        Or_error.try_with (fun () -> Int64.(timestamp_seconds * 1_000L))
      in
      if String.length subject > 500 then
        Or_error.error_string "Git commit subject exceeds 500 bytes"
      else Ok { revision; subject; timestamp_ms }
  | _ -> Or_error.error_string "Git did not return valid commit metadata"

let describe ~working_directory revision =
  let open Deferred.Or_error.Let_syntax in
  let%bind output =
    git ~working_directory
      [ "show"; "--no-patch"; "--format=%H%x00%s%x00%ct"; revision; "--" ]
  in
  Deferred.return (parse_commit output)

let preview_main ~working_directory =
  match
    Or_error.try_with (fun () -> Filename_unix.realpath working_directory)
  with
  | Error error -> Deferred.return (Error error)
  | Ok working_directory ->
      describe ~working_directory "refs/heads/main^{commit}"

let find_commit ~working_directory ~revision =
  if not (valid_revision revision) then
    Deferred.Or_error.error_string "deployment revision must be a full SHA"
  else
    match
      Or_error.try_with (fun () -> Filename_unix.realpath working_directory)
    with
    | Error error -> Deferred.return (Error error)
    | Ok working_directory -> describe ~working_directory revision

module For_testing = struct
  let commit ~revision ~subject ~timestamp_ms =
    if not (valid_revision revision) then
      Or_error.error_string "deployment revision must be a full SHA"
    else if String.length subject > 500 then
      Or_error.error_string "Git commit subject exceeds 500 bytes"
    else Ok { revision; subject; timestamp_ms }
end

let cleanup t =
  let%map _ =
    Process_runner.run_stdout ~timeout:(Time_ns.Span.of_sec 30.)
      ~max_output_bytes:65_536 ~prog:"rm" ~ignore_termination:true
      ~args:[ "-rf"; "--"; t.workspace ]
      ()
  in
  ()

let prepare ~working_directory ~commit =
  let open Deferred.Or_error.Let_syntax in
  let%bind working_directory =
    Deferred.return
      (Or_error.try_with (fun () -> Filename_unix.realpath working_directory))
  in
  let revision = commit.revision in
  let%bind repository_root =
    git ~working_directory [ "rev-parse"; "--show-toplevel" ]
  in
  let%bind repository_root =
    Deferred.return
      (Or_error.try_with (fun () ->
           String.strip repository_root |> Filename_unix.realpath))
  in
  let%bind subdirectory =
    if String.equal working_directory repository_root then
      Deferred.Or_error.return "."
    else
      String.chop_prefix working_directory ~prefix:(repository_root ^ "/")
      |> Option.value_map
           ~default:
             (Deferred.Or_error.error_string
                "working directory is outside the Git repository")
           ~f:Deferred.Or_error.return
  in
  let%bind repository =
    git ~working_directory:repository_root
      [ "config"; "--get"; "remote.origin.url" ]
  in
  let repository = String.strip repository in
  let workspace = Filename_unix.temp_dir "nixploy-" "" in
  let source_root = Filename.concat workspace "source" in
  let source_path =
    if String.equal subdirectory "." then source_root
    else Filename.concat source_root subdirectory
  in
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
          repository_root;
          source_root;
        ]
    in
    let%bind _ =
      git ~working_directory:source_root [ "checkout"; "--detach"; revision ]
    in
    let%bind dirty =
      git ~working_directory:source_root [ "status"; "--porcelain" ]
    in
    let%bind () =
      if String.is_empty (String.strip dirty) then Deferred.Or_error.return ()
      else Deferred.Or_error.error_string "materialized main checkout is dirty"
    in
    let%bind gitlinks =
      git ~working_directory:source_root [ "ls-files"; "--stage" ]
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
