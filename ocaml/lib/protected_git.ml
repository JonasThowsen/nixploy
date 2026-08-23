open Async
open Core
module U = Caml_unix

type t = {
  program : string;
  repository_root : string;
  common_directory : string;
}

let repository_root t = t.repository_root
let common_directory t = t.common_directory
let maximum_custody_entries = 200_000

let secure_mode stats =
  Int.equal stats.U.st_uid 0 && Int.equal (stats.U.st_perm land 0o022) 0

let lexical_absolute path =
  if not (Filename.is_absolute path) then
    Or_error.errorf "protected Git path %s must be absolute" path
  else
    let rec fold components = function
      | [] -> Ok components
      | "" :: rest | "." :: rest -> fold components rest
      | ".." :: rest -> (
          match components with
          | [] -> Or_error.errorf "protected Git path %s escapes root" path
          | _ :: components -> fold components rest)
      | component :: rest -> fold (component :: components) rest
    in
    Or_error.map
      (fold [] (String.split path ~on:'/'))
      ~f:(fun reversed -> "/" ^ String.concat ~sep:"/" (List.rev reversed))

let validate_no_symlink_components path =
  Or_error.try_with_join (fun () ->
      let open Or_error.Let_syntax in
      let%bind normalized = lexical_absolute path in
      let components =
        String.split normalized ~on:'/'
        |> List.filter ~f:(Fn.non String.is_empty)
      in
      let rec loop current = function
        | [] -> Ok normalized
        | component :: rest ->
            let current = Filename.concat current component in
            let stats = U.lstat current in
            if Poly.equal stats.U.st_kind U.S_LNK then
              Or_error.errorf "protected Git path %s contains symlink %s" path
                current
            else loop current rest
      in
      loop "/" components)

let validate_protected_ancestors path =
  Or_error.try_with_join (fun () ->
      let rec loop directory =
        let stats = U.lstat directory in
        if not (Poly.equal stats.U.st_kind U.S_DIR && secure_mode stats) then
          Or_error.errorf
            "protected Git directory %s must be root-owned and not group/other \
             writable"
            directory
        else
          let parent = Filename.dirname directory in
          if String.equal parent directory then Ok () else loop parent
      in
      loop (Filename.dirname path))

let validate_protected_directory path =
  let open Or_error.Let_syntax in
  let%bind () = validate_protected_ancestors path in
  let stats = U.lstat path in
  if Poly.equal stats.U.st_kind U.S_DIR && secure_mode stats then Ok ()
  else
    Or_error.errorf
      "protected Git directory %s must be root-owned and not group/other \
       writable"
      path

let validate_secure_custody_tree root =
  Or_error.try_with_join (fun () ->
      let visited = ref 0 in
      let rec walk path =
        Int.incr visited;
        if !visited > maximum_custody_entries then
          Or_error.errorf "protected Git custody exceeds %d filesystem entries"
            maximum_custody_entries
        else
          let stats = U.lstat path in
          if not (secure_mode stats) then
            Or_error.errorf
              "protected Git path %s must be root-owned and not group/other \
               writable"
              path
          else
            match stats.U.st_kind with
            | U.S_REG -> Ok ()
            | U.S_DIR ->
                Sys_unix.ls_dir path
                |> List.map ~f:(fun name -> walk (Filename.concat path name))
                |> Or_error.all_unit
            | _ ->
                Or_error.errorf
                  "protected Git path %s must not contain symlinks or special \
                   files"
                  path
      in
      walk root)

let inherited_authority () =
  let dangerous name =
    String.equal name "GIT_DIR"
    || String.equal name "GIT_WORK_TREE"
    || String.equal name "GIT_COMMON_DIR"
    || String.equal name "GIT_OBJECT_DIRECTORY"
    || String.equal name "GIT_ALTERNATE_OBJECT_DIRECTORIES"
    || String.equal name "GIT_REPLACE_REF_BASE"
    || String.equal name "GIT_INDEX_FILE"
    || String.equal name "GIT_NAMESPACE"
    || String.equal name "GIT_SHALLOW_FILE"
    || String.equal name "GIT_CEILING_DIRECTORIES"
    || String.equal name "GIT_DISCOVERY_ACROSS_FILESYSTEM"
    || String.equal name "GIT_TEMPLATE_DIR"
    || String.equal name "GIT_ATTR_NOSYSTEM"
    || String.is_prefix name ~prefix:"GIT_CONFIG"
  in
  U.environment () |> Array.to_list
  |> List.filter_map ~f:(fun binding ->
      String.lsplit2 binding ~on:'=' |> Option.map ~f:fst)
  |> List.find ~f:dangerous
  |> function
  | None -> Ok ()
  | Some name ->
      Or_error.errorf "protected source rejects inherited Git authority %s" name

let program () =
  match Sys.getenv "NIXPLOY_PROTECTED_GIT" with
  | Some path when Filename.is_absolute path -> Ok path
  | Some _ ->
      Or_error.error_string "NIXPLOY_PROTECTED_GIT must be an absolute path"
  | None ->
      List.find
        [ "/run/current-system/sw/bin/git"; "/usr/bin/git" ]
        ~f:Sys_unix.file_exists_exn
      |> Option.value_map
           ~default:
             (Or_error.error_string
                "protected source requires an absolute Git executable")
           ~f:Or_error.return

let environment =
  `Replace
    [
      ("HOME", "/var/empty");
      ("XDG_CONFIG_HOME", "/var/empty");
      ("PATH", "/no-such-path");
      ("GIT_CONFIG_NOSYSTEM", "1");
      ("GIT_CONFIG_SYSTEM", "/dev/null");
      ("GIT_CONFIG_GLOBAL", "/dev/null");
      ("GIT_ATTR_NOSYSTEM", "1");
      ("GIT_TERMINAL_PROMPT", "0");
      ("GIT_NO_LAZY_FETCH", "1");
      ("GIT_CONFIG_COUNT", "1");
      ("GIT_CONFIG_KEY_0", "safe.directory");
      ("GIT_CONFIG_VALUE_0", "*");
    ]

let run ?(max_output_bytes = 262_144) ~program args =
  Process_runner.run ~timeout:(Time_ns.Span.of_min 2.) ~max_output_bytes
    ~prog:program ~args ~env:environment ()

let output ?max_output_bytes ~program args =
  let open Deferred.Or_error.Let_syntax in
  let%bind result = run ?max_output_bytes ~program args in
  match result.exit_status with
  | Ok () -> Deferred.Or_error.return result.stdout
  | Error failure ->
      Deferred.Or_error.errorf "protected git failed (%s): %s"
        (Core_unix.Exit_or_signal.to_string_hum (Error failure))
        (String.strip result.stderr)

let explicit_args ~common_directory ~repository_root args =
  [
    "--no-replace-objects";
    "-c";
    "core.useReplaceRefs=false";
    "--git-dir=" ^ common_directory;
    "--work-tree=" ^ repository_root;
  ]
  @ args

let reject_external_config ~program ~common_directory ~repository_root =
  let open Deferred.Or_error.Let_syntax in
  let%bind names =
    output ~program
      (explicit_args ~common_directory ~repository_root
         [ "config"; "--local"; "--no-includes"; "--name-only"; "--list" ])
  in
  let external_authority name =
    let name = String.lowercase (String.strip name) in
    String.is_prefix name ~prefix:"include."
    || String.is_prefix name ~prefix:"includeif."
    || String.is_prefix name ~prefix:"filter."
    || List.mem
         [
           "core.attributesfile";
           "core.autocrlf";
           "core.eol";
           "core.hookspath";
           "core.worktree";
           "core.fsmonitor";
           "core.alternaterefscommand";
           "extensions.worktreeconfig";
         ]
         name ~equal:String.equal
  in
  String.split_lines names
  |> List.find ~f:external_authority
  |> Option.value_map ~default:(Deferred.Or_error.return ()) ~f:(fun name ->
      Deferred.Or_error.errorf
        "protected Git config contains external authority: %s" name)

let reject_alternate_object_mechanisms common_directory =
  [
    Filename.concat common_directory "objects/info/alternates";
    Filename.concat common_directory "objects/info/http-alternates";
    Filename.concat common_directory "refs/replace";
  ]
  |> List.find ~f:Sys_unix.file_exists_exn
  |> Option.value_map ~default:(Ok ()) ~f:(fun path ->
      Or_error.errorf
        "protected Git custody rejects alternate object mechanism %s" path)

let canonical path = Or_error.try_with (fun () -> Filename_unix.realpath path)

let admit ~repository_root ~working_directory =
  let open Deferred.Or_error.Let_syntax in
  let%bind () = Deferred.return (inherited_authority ()) in
  let%bind program = Deferred.return (program ()) in
  let%bind repository_root =
    Deferred.return (validate_no_symlink_components repository_root)
  in
  let%bind working_directory =
    Deferred.return (validate_no_symlink_components working_directory)
  in
  let%bind repository_root = Deferred.return (canonical repository_root) in
  let%bind working_directory = Deferred.return (canonical working_directory) in
  let%bind observed_root =
    output ~program [ "-C"; working_directory; "rev-parse"; "--show-toplevel" ]
  in
  let%bind observed_root =
    Deferred.return
      (validate_no_symlink_components (String.strip observed_root))
  in
  let%bind observed_root = Deferred.return (canonical observed_root) in
  let%bind () =
    if String.equal repository_root observed_root then
      Deferred.Or_error.return ()
    else
      Deferred.Or_error.error_string
        "managed source checkout is not the configured custody repository"
  in
  let%bind common_output =
    output ~program [ "-C"; working_directory; "rev-parse"; "--git-common-dir" ]
  in
  let common_output = String.strip common_output in
  let common_path =
    if Filename.is_absolute common_output then common_output
    else Filename.concat working_directory common_output
  in
  let%bind common_directory = Deferred.return (lexical_absolute common_path) in
  let%bind common_directory =
    Deferred.return (validate_no_symlink_components common_directory)
  in
  let%bind common_directory = Deferred.return (canonical common_directory) in
  let%bind () =
    In_thread.run (fun () ->
        let open Or_error.Let_syntax in
        let%bind () = validate_protected_directory repository_root in
        let%bind () = validate_protected_directory common_directory in
        let%bind () = reject_alternate_object_mechanisms common_directory in
        validate_secure_custody_tree common_directory)
  in
  let%bind () =
    reject_external_config ~program ~common_directory ~repository_root
  in
  let%bind objects_path =
    output ~program
      (explicit_args ~common_directory ~repository_root
         [ "rev-parse"; "--path-format=absolute"; "--git-path"; "objects" ])
  in
  let%bind objects_path =
    Deferred.return (validate_no_symlink_components (String.strip objects_path))
  in
  let%bind objects_path = Deferred.return (canonical objects_path) in
  let%bind expected_objects =
    Deferred.return (canonical (Filename.concat common_directory "objects"))
  in
  if String.equal objects_path expected_objects then
    Deferred.Or_error.return { program; repository_root; common_directory }
  else
    Deferred.Or_error.error_string
      "protected Git object directory is outside the protected common custody"

let stdout ?max_output_bytes t args =
  output ?max_output_bytes ~program:t.program
    (explicit_args ~common_directory:t.common_directory
       ~repository_root:t.repository_root args)
