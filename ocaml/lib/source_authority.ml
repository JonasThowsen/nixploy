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
let maximum_custody_entries = 1_000_000

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
          Or_error.error_string
            "source custody contains more than 1000000 filesystem entries"
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

let git ~working_directory args =
  Process_runner.run_stdout ~working_directory ~timeout:(Time_ns.Span.of_min 2.)
    ~max_output_bytes:262_144 ~prog:"git" ~args
    ~env:
      (`Extend
         [
           ("GIT_CONFIG_COUNT", "1");
           ("GIT_CONFIG_KEY_0", "safe.directory");
           ("GIT_CONFIG_VALUE_0", "*");
         ])
    ()

let canonical path = Or_error.try_with (fun () -> Filename_unix.realpath path)

let verify ?expected_revision application =
  let open Deferred.Or_error.Let_syntax in
  let repository = Managed_application.repository application in
  let working_directory = Managed_application.working_directory application in
  let%bind expected_provenance =
    match Managed_application.repository_provenance application with
    | Some value -> Deferred.Or_error.return value
    | None ->
        Deferred.Or_error.error_string
          "production source authority requires repositoryProvenance"
  in
  let%bind expected_reference =
    match Managed_application.repository_reference application with
    | Some value -> Deferred.Or_error.return value
    | None ->
        Deferred.Or_error.error_string
          "production source authority requires repositoryReference"
  in
  let%bind evidence_file =
    match Managed_application.repository_evidence_file application with
    | Some value -> Deferred.Or_error.return value
    | None ->
        Deferred.Or_error.error_string
          "production source authority requires repositoryEvidenceFile"
  in
  let%bind repository_root = Deferred.return (canonical repository) in
  let%bind observed_root =
    git ~working_directory [ "rev-parse"; "--show-toplevel" ]
  in
  let%bind observed_root =
    Deferred.return (canonical (String.strip observed_root))
  in
  let%bind () =
    if String.equal repository_root observed_root then
      Deferred.Or_error.return ()
    else
      Deferred.Or_error.error_string
        "managed source checkout is not the configured custody repository"
  in
  let%bind common_directory =
    git ~working_directory [ "rev-parse"; "--git-common-dir" ]
  in
  let common_directory = String.strip common_directory in
  let common_directory =
    if Filename.is_absolute common_directory then common_directory
    else Filename.concat working_directory common_directory
  in
  let%bind common_directory = Deferred.return (canonical common_directory) in
  let%bind () =
    Deferred.return (validate_protected_directory repository_root)
  in
  let%bind () =
    Deferred.return (validate_secure_custody_tree common_directory)
  in
  let%bind () = Deferred.return (validate_protected_ancestors evidence_file) in
  let%bind first_evidence =
    Deferred.return (read_evidence_file evidence_file)
  in
  let%bind manifest = Deferred.return (parse_manifest first_evidence) in
  let%bind () =
    Deferred.return
      (validate_manifest_value ~now_seconds:(U.gettimeofday ())
         ~max_age_seconds:
           (Managed_application.repository_evidence_max_age_seconds application)
         ~expected_provenance ~expected_reference manifest)
  in
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
    git ~working_directory
      [ "rev-parse"; "--verify"; expected_reference ^ "^{commit}" ]
  in
  let%bind () =
    if String.equal (String.strip reference_revision) manifest.revision then
      Deferred.Or_error.return ()
    else
      Deferred.Or_error.error_string
        "protected Git reference does not match source evidence"
  in
  let%bind _ =
    git ~working_directory [ "cat-file"; "-e"; manifest.revision ^ "^{commit}" ]
  in
  let%bind commit =
    Source.find_commit ~working_directory ~revision:manifest.revision
  in
  let%bind second_evidence =
    Deferred.return (read_evidence_file evidence_file)
  in
  let%bind () =
    if String.equal first_evidence second_evidence then
      Deferred.Or_error.return ()
    else
      Deferred.Or_error.error_string
        "source evidence changed during ref and object validation"
  in
  Deferred.Or_error.return
    {
      commit;
      provenance = manifest.provenance;
      reference = manifest.reference;
      evidence_digest =
        Digestif.SHA256.digest_string first_evidence |> Digestif.SHA256.to_hex;
      repository_root;
    }

module For_testing = struct
  let create ~commit ~provenance ~reference ~evidence_digest ~repository_root =
    { commit; provenance; reference; evidence_digest; repository_root }

  let validate_manifest = validate_manifest
end
