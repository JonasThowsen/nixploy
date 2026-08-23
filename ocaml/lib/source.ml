open Async
open Core

type t = {
  workspace : string option;
  path : string;
  nix_root : string;
  subdirectory : string;
  revision : string;
  repository : string;
  is_local : bool;
}

type commit = { revision : string; subject : string; timestamp_ms : int64 }

type selection =
  | Local of { commit : commit; working_directory : string }
  | Immutable of { commit : commit }

let git_timeout = Time_ns.Span.of_min 2.
let max_git_output = 262_144
let path (source : t) = source.path
let nix_root (source : t) = source.nix_root

let nix_flake (source : t) =
  if String.equal source.subdirectory "." then "."
  else "path:.?dir=" ^ Uri.pct_encode source.subdirectory

let revision (source : t) = source.revision
let repository (source : t) = source.repository
let is_local (source : t) = source.is_local
let commit_revision (commit : commit) = commit.revision
let commit_subject (commit : commit) = commit.subject
let commit_timestamp_ms (commit : commit) = commit.timestamp_ms

let git ?working_directory args =
  Process_runner.run_stdout ?working_directory ~timeout:git_timeout
    ~max_output_bytes:max_git_output ~prog:"git" ~args
    ~env:
      (`Extend
         [
           ("GIT_CONFIG_COUNT", "1");
           ("GIT_CONFIG_KEY_0", "safe.directory");
           ("GIT_CONFIG_VALUE_0", "*");
         ])
    ()

let valid_revision revision =
  String.length revision = 40
  && String.for_all revision ~f:(fun character ->
      Char.is_digit character
      || (Char.compare character 'a' >= 0 && Char.compare character 'f' <= 0))

let commit_of_git_show output =
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

let canonical_directory working_directory =
  Or_error.try_with (fun () -> Filename_unix.realpath working_directory)

let repository_origin ~working_directory =
  let open Deferred.Or_error.Let_syntax in
  let%bind working_directory =
    Deferred.return (canonical_directory working_directory)
  in
  let%bind.Deferred result =
    Process_runner.run ~working_directory ~timeout:git_timeout
      ~max_output_bytes:max_git_output ~prog:"git"
      ~args:[ "config"; "--get"; "remote.origin.url" ]
      ()
  in
  match result with
  | Error error -> Deferred.return (Error error)
  | Ok { exit_status = Ok (); stdout; _ }
    when not (String.is_empty (String.strip stdout)) ->
      Deferred.Or_error.return (Some (String.strip stdout))
  | Ok _ -> Deferred.Or_error.return None

let repository_identity ~working_directory =
  let open Deferred.Or_error.Let_syntax in
  let%bind working_directory =
    Deferred.return (canonical_directory working_directory)
  in
  let%map origin = repository_origin ~working_directory in
  Option.value origin ~default:working_directory

let describe ~working_directory revision =
  let open Deferred.Or_error.Let_syntax in
  let%bind output =
    git ~working_directory
      [ "show"; "--no-patch"; "--format=%H%x00%s%x00%ct"; revision; "--" ]
  in
  Deferred.return (commit_of_git_show output)

let reject_non_ignored_untracked ~working_directory =
  let open Deferred.Or_error.Let_syntax in
  let%bind output =
    git ~working_directory [ "ls-files"; "--others"; "--exclude-standard" ]
  in
  match
    String.split_lines output |> List.filter ~f:(Fn.non String.is_empty)
  with
  | [] -> Deferred.Or_error.return ()
  | paths ->
      let shown = List.take paths 10 |> String.concat ~sep:"\n  " in
      let remainder = List.length paths - 10 in
      let suffix =
        if remainder > 0 then sprintf "\n  ... and %d more" remainder else ""
      in
      Deferred.Or_error.errorf
        "local deployment contains non-ignored untracked files. Nixploy will \n\
        \         not silently omit them; add intentional files to the Git \
         index (git \n\
        \         add -N -- FILE is sufficient) or ignore/remove them before \
         deploying:\n\
        \         \n\
        \  %s%s"
        shown suffix

let preview_main ~working_directory =
  match canonical_directory working_directory with
  | Error error -> Deferred.return (Error error)
  | Ok working_directory ->
      describe ~working_directory "refs/heads/main^{commit}"

let local ~working_directory =
  match canonical_directory working_directory with
  | Error error -> Deferred.return (Error error)
  | Ok working_directory ->
      describe ~working_directory "HEAD^{commit}"
      >>| Or_error.map ~f:(fun commit -> Local { commit; working_directory })

let immutable commit = Immutable { commit }

let selection_commit = function
  | Local { commit; _ } -> commit
  | Immutable { commit } -> commit

let selection_is_local = function Local _ -> true | Immutable _ -> false

let find_commit ~working_directory ~revision =
  if not (valid_revision revision) then
    Deferred.Or_error.error_string "deployment revision must be a full SHA"
  else
    match canonical_directory working_directory with
    | Error error -> Deferred.return (Error error)
    | Ok working_directory -> describe ~working_directory revision

module For_testing = struct
  let commit ~revision ~subject ~timestamp_ms =
    if not (valid_revision revision) then
      Or_error.error_string "deployment revision must be a full SHA"
    else if String.length subject > 500 then
      Or_error.error_string "Git commit subject exceeds 500 bytes"
    else Ok { revision; subject; timestamp_ms }

  let local ~working_directory commit = Local { commit; working_directory }
end

let cleanup t =
  match t.workspace with
  | None -> Deferred.unit
  | Some workspace ->
      let%map _ =
        Process_runner.run_stdout ~timeout:(Time_ns.Span.of_sec 30.)
          ~max_output_bytes:65_536 ~prog:"rm" ~ignore_termination:true
          ~args:[ "-rf"; "--"; workspace ] ()
      in
      ()

let repository_layout ~working_directory =
  let open Deferred.Or_error.Let_syntax in
  let%bind repository_root =
    git ~working_directory [ "rev-parse"; "--show-toplevel" ]
  in
  let%bind repository_root =
    Deferred.return
      (Or_error.try_with (fun () ->
           String.strip repository_root |> Filename_unix.realpath))
  in
  let%map subdirectory =
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
  (repository_root, subdirectory)

let reject_gitlinks ~repository_root =
  let open Deferred.Or_error.Let_syntax in
  let%bind gitlinks =
    git ~working_directory:repository_root [ "ls-files"; "--stage" ]
  in
  if
    String.split_lines gitlinks
    |> List.exists ~f:(fun line -> String.is_prefix line ~prefix:"160000 ")
  then Deferred.Or_error.error_string "Git submodules are not supported"
  else Deferred.Or_error.return ()

let existing_path path =
  match Core_unix.lstat path with
  | _ -> true
  | exception Caml_unix.Unix_error (Caml_unix.ENOENT, _, _) -> false

let copy_tracked_files ~repository_root ~destination =
  let open Deferred.Or_error.Let_syntax in
  let%bind output =
    git ~working_directory:repository_root [ "ls-files"; "--cached"; "-z" ]
  in
  let paths =
    String.split output ~on:'\000'
    |> List.filter ~f:(fun path ->
        (not (String.is_empty path))
        && existing_path (Filename.concat repository_root path))
  in
  let%bind () =
    Deferred.return (Or_error.try_with (fun () -> Core_unix.mkdir destination))
  in
  paths |> List.chunks_of ~length:128
  |> Deferred.Or_error.List.iter ~how:`Sequential ~f:(fun paths ->
      let%map _ =
        Process_runner.run_stdout ~working_directory:repository_root
          ~timeout:(Time_ns.Span.of_min 2.) ~max_output_bytes:max_git_output
          ~prog:"cp"
          ~args:
            ([ "--parents"; "--no-dereference"; "--preserve=mode"; "--" ]
            @ paths @ [ destination ])
          ()
      in
      ())

let prepare_immutable ~working_directory ~commit =
  let open Deferred.Or_error.Let_syntax in
  let%bind working_directory =
    Deferred.return (canonical_directory working_directory)
  in
  let revision = commit.revision in
  let%bind repository_root, subdirectory =
    repository_layout ~working_directory
  in
  let%bind repository = repository_identity ~working_directory in
  let workspace = Filename_unix.temp_dir "nixploy-" "" in
  let checkout_root = Filename.concat workspace "checkout" in
  let source_root = Filename.concat workspace "source" in
  let source_path =
    if String.equal subdirectory "." then source_root
    else Filename.concat source_root subdirectory
  in
  let provisional =
    {
      workspace = Some workspace;
      path = source_path;
      nix_root = source_root;
      subdirectory;
      revision;
      repository;
      is_local = false;
    }
  in
  let prepare () =
    let%bind _ =
      git
        [
          "clone";
          "--no-checkout";
          "--local";
          "--no-hardlinks";
          "--";
          repository_root;
          checkout_root;
        ]
    in
    let%bind _ =
      git ~working_directory:checkout_root [ "checkout"; "--detach"; revision ]
    in
    let%bind dirty =
      git ~working_directory:checkout_root [ "status"; "--porcelain" ]
    in
    let%bind () =
      if String.is_empty (String.strip dirty) then Deferred.Or_error.return ()
      else Deferred.Or_error.error_string "materialized main checkout is dirty"
    in
    let%bind () = reject_gitlinks ~repository_root:checkout_root in
    let%bind () =
      copy_tracked_files ~repository_root:checkout_root ~destination:source_root
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
  let%bind.Deferred result = Monitor.try_with_or_error prepare in
  match Or_error.join result with
  | Ok source -> Deferred.Or_error.return source
  | Error error ->
      let%map.Deferred () = cleanup provisional in
      Error error

let prepare_local ~working_directory ~selected_directory ~commit =
  let open Deferred.Or_error.Let_syntax in
  let%bind working_directory =
    Deferred.return (canonical_directory working_directory)
  in
  let%bind () =
    if String.equal working_directory selected_directory then
      Deferred.Or_error.return ()
    else
      Deferred.Or_error.error_string
        "local source selection does not match the deployment directory"
  in
  let%bind repository_root, subdirectory =
    repository_layout ~working_directory
  in
  let%bind () =
    reject_non_ignored_untracked ~working_directory:repository_root
  in
  let%bind () = reject_gitlinks ~repository_root in
  let%bind repository = repository_identity ~working_directory in
  let workspace = Filename_unix.temp_dir "nixploy-local-" "" in
  let source_root = Filename.concat workspace "source" in
  let source_path =
    if String.equal subdirectory "." then source_root
    else Filename.concat source_root subdirectory
  in
  let provisional =
    {
      workspace = Some workspace;
      path = source_path;
      nix_root = source_root;
      subdirectory;
      revision = commit.revision;
      repository;
      is_local = true;
    }
  in
  let prepare () =
    let%bind () =
      copy_tracked_files ~repository_root ~destination:source_root
    in
    let%bind () =
      reject_non_ignored_untracked ~working_directory:repository_root
    in
    let%bind current = describe ~working_directory "HEAD^{commit}" in
    let%bind () =
      if String.equal current.revision commit.revision then
        Deferred.Or_error.return ()
      else
        Deferred.Or_error.error_string
          "local deployment HEAD changed while preparing its source snapshot"
    in
    if Sys_unix.file_exists_exn (Filename.concat source_path "flake.nix") then
      Deferred.Or_error.return provisional
    else
      Deferred.Or_error.error_string
        "local source snapshot does not contain flake.nix"
  in
  let%bind.Deferred result = Monitor.try_with_or_error prepare in
  match Or_error.join result with
  | Ok source -> Deferred.Or_error.return source
  | Error error ->
      let%map.Deferred () = cleanup provisional in
      Error error

let prepare ~working_directory ~selection =
  match selection with
  | Immutable { commit } -> prepare_immutable ~working_directory ~commit
  | Local { commit; working_directory = selected_directory } ->
      prepare_local ~working_directory ~selected_directory ~commit
