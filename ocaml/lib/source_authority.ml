open Async
open Core
module U = Caml_unix

type manifest = {
  provenance : string;
  reference : string;
  revision : string;
  observed_at_unix_seconds : float;
}

type t = {
  commit : Source.commit;
  provenance : string;
  reference : string;
  evidence_digest : string;
  repository_root : string;
}

let commit t = t.commit
let revision t = Source.commit_revision t.commit
let provenance t = t.provenance
let reference t = t.reference
let evidence_digest t = t.evidence_digest
let repository_root t = t.repository_root
let maximum_manifest_bytes = 4096
let maximum_custody_entries = 200_000

let valid_revision revision =
  String.length revision = 40
  && String.for_all revision ~f:(function
    | '0' .. '9' | 'a' .. 'f' -> true
    | _ -> false)

let validate_members fields =
  let allowed =
    String.Set.of_list
      [
        "version";
        "provenance";
        "reference";
        "revision";
        "observedAtUnixSeconds";
      ]
  in
  let rec loop seen = function
    | [] -> Ok ()
    | (name, _) :: rest ->
        if Set.mem seen name then
          Or_error.errorf "source evidence contains duplicate member %s" name
        else if not (Set.mem allowed name) then
          Or_error.errorf "source evidence contains unknown member %s" name
        else loop (Set.add seen name) rest
  in
  loop String.Set.empty fields

let required_string fields name =
  match List.Assoc.find fields ~equal:String.equal name with
  | Some (`String value) when not (String.is_empty value) -> Ok value
  | _ -> Or_error.errorf "source evidence %s must be a non-empty string" name

let parse_manifest input =
  let open Or_error.Let_syntax in
  let%bind json = Or_error.try_with (fun () -> Yojson.Safe.from_string input) in
  match json with
  | `Assoc fields ->
      let%bind () = validate_members fields in
      let%bind () =
        match List.Assoc.find fields ~equal:String.equal "version" with
        | Some (`Int 1) -> Ok ()
        | _ -> Or_error.error_string "source evidence version must be 1"
      in
      let%bind provenance = required_string fields "provenance"
      and reference = required_string fields "reference"
      and revision = required_string fields "revision"
      and observed_at_unix_seconds =
        match
          List.Assoc.find fields ~equal:String.equal "observedAtUnixSeconds"
        with
        | Some (`Int value) -> Ok (Float.of_int value)
        | Some (`Intlit value) ->
            Or_error.try_with (fun () -> Float.of_string value)
        | _ ->
            Or_error.error_string
              "source evidence observedAtUnixSeconds must be an integer"
      in
      if not (valid_revision revision) then
        Or_error.error_string
          "source evidence revision must be a full lowercase Git SHA"
      else Ok { provenance; reference; revision; observed_at_unix_seconds }
  | _ -> Or_error.error_string "source evidence must be a JSON object"

let validate_manifest_value ~now_seconds ~max_age_seconds ~expected_provenance
    ~expected_reference (manifest : manifest) =
  if not (String.equal manifest.provenance expected_provenance) then
    Or_error.error_string
      "source evidence provenance does not match the root-managed authority"
  else if not (String.equal manifest.reference expected_reference) then
    Or_error.error_string
      "source evidence reference does not match the root-managed authority"
  else
    let age = now_seconds -. manifest.observed_at_unix_seconds in
    if Float.(age < -30.) then
      Or_error.error_string "source evidence timestamp is too far in the future"
    else if Float.(age > of_int max_age_seconds) then
      Or_error.error_string "source evidence is stale"
    else Ok ()

let validate_manifest ~now_seconds ~max_age_seconds ~expected_provenance
    ~expected_reference input =
  let open Or_error.Let_syntax in
  let%bind manifest = parse_manifest input in
  validate_manifest_value ~now_seconds ~max_age_seconds ~expected_provenance
    ~expected_reference manifest

let secure_mode stats =
  Int.equal stats.U.st_uid 0 && Int.equal (stats.U.st_perm land 0o022) 0

let validate_secure_regular_file path stats =
  if not (Poly.equal stats.U.st_kind U.S_REG) then
    Or_error.errorf "source authority path %s must be a regular file" path
  else if not (secure_mode stats) then
    Or_error.errorf
      "source authority path %s must be root-owned and not group/other writable"
      path
  else Ok ()

let lexical_absolute path =
  if not (Filename.is_absolute path) then
    Or_error.errorf "source authority path %s must be absolute" path
  else
    let rec fold components = function
      | [] -> Ok components
      | "" :: rest | "." :: rest -> fold components rest
      | ".." :: rest -> (
          match components with
          | [] -> Or_error.errorf "source authority path %s escapes root" path
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
              Or_error.errorf
                "source authority path %s contains symlink component %s" path
                current
            else loop current rest
      in
      loop "/" components)

let read_evidence_file path =
  Or_error.try_with_join (fun () ->
      let path_stats = U.lstat path in
      let open Or_error.Let_syntax in
      let%bind () = validate_secure_regular_file path path_stats in
      let descriptor = U.openfile path [ U.O_RDONLY; U.O_CLOEXEC ] 0 in
      Exn.protect
        ~finally:(fun () -> U.close descriptor)
        ~f:(fun () ->
          let before = U.fstat descriptor in
          let open Or_error.Let_syntax in
          let%bind () = validate_secure_regular_file path before in
          let%bind () =
            if
              Int.equal path_stats.U.st_dev before.U.st_dev
              && Int.equal path_stats.U.st_ino before.U.st_ino
            then Ok ()
            else
              Or_error.error_string
                "source evidence was replaced while being opened"
          in
          if before.U.st_size > maximum_manifest_bytes then
            Or_error.error_string "source evidence exceeds 4096 bytes"
          else
            let length = before.U.st_size in
            let bytes = Bytes.create length in
            let rec read_all offset =
              if offset < length then
                let count = U.read descriptor bytes offset (length - offset) in
                if Int.equal count 0 then
                  failwith "unexpected EOF while reading source evidence"
                else read_all (offset + count)
            in
            read_all 0;
            let after = U.fstat descriptor in
            if
              before.U.st_dev <> after.U.st_dev
              || before.U.st_ino <> after.U.st_ino
              || before.U.st_size <> after.U.st_size
              || Float.(before.U.st_mtime <> after.U.st_mtime)
            then
              Or_error.error_string "source evidence changed while being read"
            else Ok (Bytes.to_string bytes)))

let validate_protected_ancestors path =
  Or_error.try_with_join (fun () ->
      let rec loop directory =
        let stats = U.lstat directory in
        if not (Poly.equal stats.U.st_kind U.S_DIR && secure_mode stats) then
          Or_error.errorf
            "source authority directory %s must be root-owned and not \
             group/other writable"
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
      "source custody directory %s must be root-owned and not group/other \
       writable"
      path

let validate_secure_custody_tree root =
  Or_error.try_with_join (fun () ->
      let visited = ref 0 in
      let rec walk path =
        Int.incr visited;
        if !visited > maximum_custody_entries then
          Or_error.errorf
            "source custody contains more than %d filesystem entries"
            maximum_custody_entries
        else
          let stats = U.lstat path in
          if not (secure_mode stats) then
            Or_error.errorf
              "source custody path %s must be root-owned and not group/other \
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
                  "source custody path %s must not contain symlinks or special \
                   files"
                  path
      in
      walk root)

let inherited_git_authority () =
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
    || String.is_prefix name ~prefix:"GIT_CONFIG"
  in
  U.environment () |> Array.to_list
  |> List.filter_map ~f:(fun binding ->
      String.lsplit2 binding ~on:'=' |> Option.map ~f:fst)
  |> List.find ~f:dangerous
  |> function
  | None -> Ok ()
  | Some name ->
      Or_error.errorf
        "protected source verification rejects inherited Git authority %s" name

let protected_git_program () =
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
                "protected source verification requires an absolute Git \
                 executable")
           ~f:Or_error.return

let protected_git_env =
  `Replace
    [
      ("HOME", "/var/empty");
      ("PATH", "/no-such-path");
      ("GIT_CONFIG_NOSYSTEM", "1");
      ("GIT_CONFIG_SYSTEM", "/dev/null");
      ("GIT_CONFIG_GLOBAL", "/dev/null");
      ("GIT_TERMINAL_PROMPT", "0");
      ("GIT_NO_LAZY_FETCH", "1");
      ("GIT_CONFIG_COUNT", "1");
      ("GIT_CONFIG_KEY_0", "safe.directory");
      ("GIT_CONFIG_VALUE_0", "*");
    ]

let git_run ~prog args =
  Process_runner.run ~timeout:(Time_ns.Span.of_min 2.) ~max_output_bytes:262_144
    ~prog ~args ~env:protected_git_env ()

let git ~prog args =
  let open Deferred.Or_error.Let_syntax in
  let%bind result = git_run ~prog args in
  match result.exit_status with
  | Ok () -> Deferred.Or_error.return result.stdout
  | Error failure ->
      Deferred.Or_error.errorf "protected git failed (%s): %s"
        (Core_unix.Exit_or_signal.to_string_hum (Error failure))
        (String.strip result.stderr)

let reject_git_config_authority ~prog ~common_directory ~repository_root =
  let open Deferred.Or_error.Let_syntax in
  let%bind result =
    git_run ~prog
      [
        "--no-replace-objects";
        "--git-dir=" ^ common_directory;
        "--work-tree=" ^ repository_root;
        "config";
        "--local";
        "--no-includes";
        "--name-only";
        "--list";
      ]
  in
  match result.exit_status with
  | Ok () ->
      let external_authority name =
        let name = String.lowercase (String.strip name) in
        String.is_prefix name ~prefix:"include."
        || String.is_prefix name ~prefix:"includeif."
        || List.mem
             [
               "core.worktree";
               "core.alternaterefscommand";
               "extensions.worktreeconfig";
             ]
             name ~equal:String.equal
      in
      String.split_lines result.stdout
      |> List.find ~f:external_authority
      |> Option.value_map ~default:(Deferred.Or_error.return ()) ~f:(fun name ->
          Deferred.Or_error.errorf
            "protected Git config contains external authority: %s" name)
  | Error failure ->
      Deferred.Or_error.errorf "could not inspect protected Git config (%s): %s"
        (Core_unix.Exit_or_signal.to_string_hum (Error failure))
        (String.strip result.stderr)

let reject_alternate_object_mechanisms common_directory =
  let mechanisms =
    [
      Filename.concat common_directory "objects/info/alternates";
      Filename.concat common_directory "objects/info/http-alternates";
      Filename.concat common_directory "refs/replace";
    ]
  in
  match List.find mechanisms ~f:Sys_unix.file_exists_exn with
  | None -> Ok ()
  | Some path ->
      Or_error.errorf
        "protected Git custody rejects alternate object mechanism %s" path

let canonical path = Or_error.try_with (fun () -> Filename_unix.realpath path)

let verify ?expected_revision application =
  let open Deferred.Or_error.Let_syntax in
  let repository = Managed_application.repository application in
  let working_directory = Managed_application.working_directory application in
  let max_age_seconds =
    Managed_application.repository_evidence_max_age_seconds application
  in
  let%bind () = Deferred.return (inherited_git_authority ()) in
  let%bind prog = Deferred.return (protected_git_program ()) in
  let%bind expected_provenance =
    Managed_application.repository_provenance application
    |> Option.value_map
         ~default:
           (Deferred.Or_error.error_string
              "production source authority requires repositoryProvenance")
         ~f:Deferred.Or_error.return
  in
  let%bind expected_reference =
    Managed_application.repository_reference application
    |> Option.value_map
         ~default:
           (Deferred.Or_error.error_string
              "production source authority requires repositoryReference")
         ~f:Deferred.Or_error.return
  in
  let%bind evidence_file =
    Managed_application.repository_evidence_file application
    |> Option.value_map
         ~default:
           (Deferred.Or_error.error_string
              "production source authority requires repositoryEvidenceFile")
         ~f:Deferred.Or_error.return
  in
  let%bind repository_lexical =
    Deferred.return (validate_no_symlink_components repository)
  in
  let%bind working_lexical =
    Deferred.return (validate_no_symlink_components working_directory)
  in
  let%bind evidence_lexical =
    Deferred.return (validate_no_symlink_components evidence_file)
  in
  let%bind repository_root = Deferred.return (canonical repository_lexical) in
  let%bind working_directory = Deferred.return (canonical working_lexical) in
  let%bind evidence_file = Deferred.return (canonical evidence_lexical) in
  let%bind observed_root =
    git ~prog [ "-C"; working_directory; "rev-parse"; "--show-toplevel" ]
  in
  let%bind observed_root_lexical =
    Deferred.return
      (validate_no_symlink_components (String.strip observed_root))
  in
  let%bind observed_root = Deferred.return (canonical observed_root_lexical) in
  let%bind () =
    if String.equal repository_root observed_root then
      Deferred.Or_error.return ()
    else
      Deferred.Or_error.error_string
        "managed source checkout is not the configured custody repository"
  in
  let%bind common_output =
    git ~prog [ "-C"; working_directory; "rev-parse"; "--git-common-dir" ]
  in
  let common_output = String.strip common_output in
  let common_path =
    if Filename.is_absolute common_output then common_output
    else Filename.concat working_directory common_output
  in
  let%bind common_lexical = Deferred.return (lexical_absolute common_path) in
  let%bind common_lexical =
    Deferred.return (validate_no_symlink_components common_lexical)
  in
  let%bind common_directory = Deferred.return (canonical common_lexical) in
  let%bind () =
    In_thread.run (fun () ->
        let open Or_error.Let_syntax in
        let%bind () = validate_protected_directory repository_root in
        let%bind () = validate_protected_directory common_directory in
        let%bind () = validate_protected_ancestors evidence_file in
        let%bind () = reject_alternate_object_mechanisms common_directory in
        validate_secure_custody_tree common_directory)
  in
  let%bind () =
    reject_git_config_authority ~prog ~common_directory ~repository_root
  in
  let explicit_git args =
    git ~prog
      ([
         "--no-replace-objects";
         "-c";
         "core.useReplaceRefs=false";
         "--git-dir=" ^ common_directory;
         "--work-tree=" ^ repository_root;
       ]
      @ args)
  in
  let%bind objects_path =
    explicit_git
      [ "rev-parse"; "--path-format=absolute"; "--git-path"; "objects" ]
  in
  let%bind objects_lexical =
    Deferred.return (validate_no_symlink_components (String.strip objects_path))
  in
  let%bind objects_path = Deferred.return (canonical objects_lexical) in
  let expected_objects = Filename.concat common_directory "objects" in
  let%bind expected_objects = Deferred.return (canonical expected_objects) in
  let%bind () =
    if String.equal objects_path expected_objects then
      Deferred.Or_error.return ()
    else
      Deferred.Or_error.error_string
        "protected Git object directory is outside the protected common custody"
  in
  let%bind first_evidence =
    In_thread.run (fun () -> read_evidence_file evidence_file)
  in
  let%bind manifest = Deferred.return (parse_manifest first_evidence) in
  let validate_fresh () =
    validate_manifest_value ~now_seconds:(U.gettimeofday ()) ~max_age_seconds
      ~expected_provenance ~expected_reference manifest
  in
  let%bind () = Deferred.return (validate_fresh ()) in
  let%bind () =
    match expected_revision with
    | None -> Deferred.Or_error.return ()
    | Some expected when String.equal expected manifest.revision ->
        Deferred.Or_error.return ()
    | Some _ ->
        Deferred.Or_error.error_string
          "source evidence no longer names the confirmed commit"
  in
  let%bind reference_revision =
    explicit_git [ "rev-parse"; "--verify"; expected_reference ^ "^{commit}" ]
  in
  let%bind () =
    if String.equal (String.strip reference_revision) manifest.revision then
      Deferred.Or_error.return ()
    else
      Deferred.Or_error.error_string
        "protected Git reference does not match source evidence"
  in
  let%bind _ =
    explicit_git [ "cat-file"; "-e"; manifest.revision ^ "^{commit}" ]
  in
  let%bind commit_output =
    explicit_git
      [
        "show";
        "--no-patch";
        "--format=%H%x00%s%x00%ct";
        manifest.revision ^ "^{commit}";
        "--";
      ]
  in
  let%bind commit = Deferred.return (Source.commit_of_git_show commit_output) in
  let%bind second_evidence =
    In_thread.run (fun () -> read_evidence_file evidence_file)
  in
  let%bind () =
    if String.equal first_evidence second_evidence then
      Deferred.Or_error.return ()
    else
      Deferred.Or_error.error_string
        "source evidence changed during ref and object validation"
  in
  let%bind () = Deferred.return (validate_fresh ()) in
  Deferred.Or_error.return
    {
      commit;
      provenance = manifest.provenance;
      reference = manifest.reference;
      evidence_digest =
        Digestif.SHA256.digest_string second_evidence |> Digestif.SHA256.to_hex;
      repository_root;
    }

module For_testing = struct
  let create ~commit ~provenance ~reference ~evidence_digest ~repository_root =
    { commit; provenance; reference; evidence_digest; repository_root }

  let validate_manifest = validate_manifest
end
