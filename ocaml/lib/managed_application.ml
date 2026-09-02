open Core

type destination_kind = Non_web | Web [@@deriving compare, equal, sexp]

type production_destination = {
  host : string;
  user : string;
  port : int;
  kind : destination_kind;
  domain : string option;
  coordination_scope : string;
}

type t = {
  key : string;
  project : Project_name.t;
  target : Target_name.t;
  repository : string;
  repository_identity : string;
  repository_provenance : string option;
  repository_reference : string option;
  repository_evidence_file : string option;
  repository_evidence_max_age_seconds : int;
  subdirectory : string;
  production_destination : production_destination option;
  non_production_destination : production_destination option;
}

let maximum_count = 64
let key t = t.key
let project t = t.project
let target t = t.target
let repository t = t.repository
let repository_identity t = t.repository_identity
let repository_provenance t = t.repository_provenance
let repository_reference t = t.repository_reference
let repository_evidence_file t = t.repository_evidence_file

let repository_evidence_max_age_seconds t =
  t.repository_evidence_max_age_seconds

let production_destination t = t.production_destination
let non_production_destination t = t.non_production_destination
let destination_host t = t.host
let destination_user t = t.user
let destination_port t = t.port
let destination_kind t = t.kind
let destination_domain t = t.domain
let coordination_scope t = t.coordination_scope

let working_directory t =
  if String.equal t.subdirectory "." then t.repository
  else Filename.concat t.repository t.subdirectory

let required_string fields name =
  match List.Assoc.find fields ~equal:String.equal name with
  | Some (`String value) when not (String.is_empty (String.strip value)) ->
      Ok value
  | _ -> Or_error.errorf "%s must be a non-empty string" name

let optional_string fields name ~default =
  match List.Assoc.find fields ~equal:String.equal name with
  | Some (`String value) when not (String.is_empty (String.strip value)) ->
      Ok value
  | None -> Ok default
  | _ -> Or_error.errorf "%s must be a non-empty string" name

let validate_members ~field ~allowed fields =
  let rec loop seen = function
    | [] -> Ok ()
    | (name, _) :: rest ->
        if Set.mem seen name then
          Or_error.errorf "%s contains duplicate member %s" field name
        else if not (Set.mem allowed name) then
          Or_error.errorf "%s contains unknown member %s" field name
        else loop (Set.add seen name) rest
  in
  loop String.Set.empty fields

let parse_destination fields field_name =
  match List.Assoc.find fields ~equal:String.equal field_name with
  | None | Some `Null -> Ok None
  | Some (`Assoc fields) ->
      let open Or_error.Let_syntax in
      let%bind () =
        validate_members
          ~field:("managed application " ^ field_name ^ " destination")
          ~allowed:
            (String.Set.of_list
               [ "host"; "user"; "port"; "kind"; "domain"; "coordinationScope" ])
          fields
      in
      let%bind raw_host = required_string fields "host"
      and user = required_string fields "user"
      and raw_coordination_scope = required_string fields "coordinationScope" in
      let%bind host = Endpoint_identity.host raw_host
      and coordination_scope =
        Endpoint_identity.coordination_scope raw_coordination_scope
      in
      let%bind port =
        match List.Assoc.find fields ~equal:String.equal "port" with
        | Some (`Int port) when port >= 1 && port <= 65_535 -> Ok port
        | _ -> Or_error.errorf "%s.port must be between 1 and 65535" field_name
      in
      let%bind kind =
        match List.Assoc.find fields ~equal:String.equal "kind" with
        | Some (`String "non-web") -> Ok Non_web
        | Some (`String "web") -> Ok Web
        | _ -> Or_error.errorf "%s.kind must be non-web or web" field_name
      in
      let%bind domain =
        match (kind, List.Assoc.find fields ~equal:String.equal "domain") with
        | Non_web, (None | Some `Null) -> Ok None
        | Web, Some (`String domain)
          when not (String.is_empty (String.strip domain)) ->
            Or_error.map (Endpoint_identity.domain domain) ~f:Option.some
        | Non_web, Some _ ->
            Or_error.error_string
              "production non-web destination cannot declare domain"
        | Web, _ ->
            Or_error.error_string "production web destination requires domain"
      in
      if String.equal user "root" then
        Or_error.error_string "production destination SSH user must not be root"
      else Ok (Some { host; user; port; kind; domain; coordination_scope })
  | Some _ -> Or_error.errorf "%s must be an object" field_name

let absolute_normalized_path ~field path =
  let components = String.split path ~on:'/' in
  if
    (not (Filename.is_absolute path))
    || String.is_suffix path ~suffix:"/"
    || List.exists (List.tl_exn components) ~f:(fun component ->
        String.is_empty component || String.equal component "."
        || String.equal component "..")
  then Or_error.errorf "%s must be an absolute normalized path" field
  else Ok path

let valid_key key =
  let valid_character = function
    | 'a' .. 'z' | '0' .. '9' | '_' | '-' -> true
    | _ -> false
  in
  let length = String.length key in
  length > 0 && length <= 63
  && (Char.is_lowercase key.[0] || Char.is_digit key.[0])
  && String.for_all key ~f:valid_character

let parse (key, json) =
  let open Or_error.Let_syntax in
  if not (valid_key key) then
    Or_error.error_string
      "application key must use lowercase letters, digits, dashes, or \
       underscores"
  else
    match json with
    | `Assoc fields ->
        let%bind () =
          validate_members
            ~field:("managed application " ^ key)
            ~allowed:
              (String.Set.of_list
                 [
                   "project";
                   "target";
                   "repository";
                   "repositoryIdentity";
                   "repositoryProvenance";
                   "repositoryReference";
                   "repositoryEvidenceFile";
                   "repositoryEvidenceMaxAgeSeconds";
                   "subdirectory";
                   "production";
                   "nonProduction";
                 ])
            fields
        in
        let%bind project =
          required_string fields "project" >>= Project_name.of_string
        in
        let%bind target =
          required_string fields "target" >>= Target_name.of_string
        in
        let%bind repository = required_string fields "repository" in
        let%bind repository =
          absolute_normalized_path ~field:"managed application repository"
            repository
        in
        let repository_identity_is_explicit =
          Option.is_some
            (List.Assoc.find fields ~equal:String.equal "repositoryIdentity")
        in
        let%bind repository_identity =
          optional_string fields "repositoryIdentity" ~default:repository
        in
        let%bind repository_provenance =
          match
            List.Assoc.find fields ~equal:String.equal "repositoryProvenance"
          with
          | None | Some `Null -> Ok None
          | Some (`String value) when not (String.is_empty (String.strip value))
            ->
              Ok (Some value)
          | Some _ ->
              Or_error.error_string
                "repositoryProvenance must be a non-empty string"
        in
        let%bind repository_reference =
          match
            List.Assoc.find fields ~equal:String.equal "repositoryReference"
          with
          | None | Some `Null -> Ok None
          | Some (`String value)
            when String.is_prefix value ~prefix:"refs/heads/"
                 && not (String.is_empty (String.drop_prefix value 11)) ->
              Ok (Some value)
          | Some _ ->
              Or_error.error_string
                "repositoryReference must be a full refs/heads/... reference"
        in
        let%bind repository_evidence_file =
          match
            List.Assoc.find fields ~equal:String.equal "repositoryEvidenceFile"
          with
          | None | Some `Null -> Ok None
          | Some (`String value) ->
              Or_error.map
                (absolute_normalized_path ~field:"repositoryEvidenceFile" value)
                ~f:Option.some
          | Some _ ->
              Or_error.error_string
                "repositoryEvidenceFile must be an absolute path"
        in
        let%bind repository_evidence_max_age_seconds =
          match
            List.Assoc.find fields ~equal:String.equal
              "repositoryEvidenceMaxAgeSeconds"
          with
          | None -> Ok 900
          | Some (`Int value) when value >= 1 && value <= 3600 -> Ok value
          | Some _ ->
              Or_error.error_string
                "repositoryEvidenceMaxAgeSeconds must be between 1 and 3600"
        in
        let%bind subdirectory =
          optional_string fields "subdirectory" ~default:"."
        in
        let%bind production_destination = parse_destination fields "production"
        and non_production_destination =
          parse_destination fields "nonProduction"
        in
        if
          Option.is_some production_destination
          && Option.is_some non_production_destination
        then
          Or_error.error_string
            "managed application cannot be both production and nonProduction"
        else if
          Option.is_some production_destination
          && ((not repository_identity_is_explicit)
             || Option.is_none repository_provenance
             || Option.is_none repository_reference
             || Option.is_none repository_evidence_file)
        then
          Or_error.error_string
            "production managed application requires explicit \
             repositoryIdentity, repositoryProvenance, repositoryReference, \
             and repositoryEvidenceFile"
        else if
          Filename.is_absolute subdirectory
          || List.mem
               (String.split subdirectory ~on:'/')
               ".." ~equal:String.equal
        then
          Or_error.error_string
            "managed application subdirectory must stay inside its repository"
        else
          let subdirectory =
            String.split subdirectory ~on:'/'
            |> List.filter ~f:(fun component ->
                not (String.is_empty component || String.equal component "."))
            |> String.concat ~sep:"/"
          in
          let subdirectory =
            if String.is_empty subdirectory then "." else subdirectory
          in
          Ok
            {
              key;
              project;
              target;
              repository;
              repository_identity;
              repository_provenance;
              repository_reference;
              repository_evidence_file;
              repository_evidence_max_age_seconds;
              subdirectory;
              production_destination;
              non_production_destination;
            }
    | _ -> Or_error.error_string "managed application must be an object"

let canonical_working_directory application =
  let working_directory = working_directory application in
  Or_error.try_with (fun () -> Filename_unix.realpath working_directory)
  |> Result.ok
  |> Option.value ~default:working_directory

let destinations_intersect production non_production =
  String.equal production.host non_production.host
  || Option.equal String.equal production.domain non_production.domain
     && Option.is_some production.domain
  || String.equal production.coordination_scope
       non_production.coordination_scope

let cross_profile_intersection applications =
  List.find_map applications ~f:(fun production_application ->
      Option.bind production_application.production_destination
        ~f:(fun production ->
          List.find_map applications ~f:(fun non_production_application ->
              Option.bind non_production_application.non_production_destination
                ~f:(fun non_production ->
                  let managed_identity =
                    Project_name.equal production_application.project
                      non_production_application.project
                    && Target_name.equal production_application.target
                         non_production_application.target
                  in
                  if
                    managed_identity
                    || destinations_intersect production non_production
                  then
                    Some
                      ( production_application.key,
                        non_production_application.key )
                  else None))))

let duplicate_identity applications =
  List.find_a_dup applications ~compare:(fun left right ->
      let by_directory =
        String.compare
          (canonical_working_directory left)
          (canonical_working_directory right)
      in
      if not (Int.equal by_directory 0) then by_directory
      else
        let by_target = Target_name.compare left.target right.target in
        if not (Int.equal by_target 0) then by_target
        else String.compare left.repository_identity right.repository_identity)

let all_of_json input =
  let open Or_error.Let_syntax in
  let%bind json = Or_error.try_with (fun () -> Yojson.Safe.from_string input) in
  match json with
  | `Assoc applications when List.length applications > maximum_count ->
      Or_error.errorf "managed applications may contain at most %d entries"
        maximum_count
  | `Assoc applications ->
      let%bind parsed = Or_error.all (List.map applications ~f:parse) in
      let%bind () =
        match duplicate_identity parsed with
        | None -> Ok ()
        | Some application ->
            Or_error.errorf
              "managed applications contain duplicate operational identity for \
               %s"
              application.key
      in
      let%bind () =
        match cross_profile_intersection parsed with
        | None -> Ok ()
        | Some (production, non_production) ->
            Or_error.errorf
              "production application %s intersects nonProduction application \
               %s"
              production non_production
      in
      Ok
        (List.sort parsed ~compare:(fun left right ->
             String.compare left.key right.key))
  | _ -> Or_error.error_string "managed applications must be a JSON object"

let authority_file = "/etc/nixploy/managed-applications.json"
let maximum_authority_file_bytes = 262_144

let load_authority_file () =
  Or_error.try_with_join (fun () ->
      let rec validate_directory directory =
        let stats = Caml_unix.lstat directory in
        let nix_store_root =
          String.equal directory "/nix/store"
          && Int.equal stats.st_uid 0
          && Int.equal (stats.st_perm land 0o1000) 0o1000
          && Int.equal (stats.st_perm land 0o002) 0
        in
        if
          Poly.equal stats.st_kind Caml_unix.S_DIR
          && (nix_store_root
             || Int.equal stats.st_uid 0
                && Int.equal (stats.st_perm land 0o022) 0)
        then
          let parent = Filename.dirname directory in
          if String.equal parent directory then Ok ()
          else validate_directory parent
        else
          Or_error.errorf
            "managed application authority directory %s must be root-owned, \
             non-symlinked, and not group/other writable"
            directory
      in
      let open Or_error.Let_syntax in
      let%bind () = validate_directory (Filename.dirname authority_file) in
      let link_stats = Caml_unix.lstat authority_file in
      let%bind () =
        if Int.equal link_stats.st_uid 0 then Ok ()
        else
          Or_error.error_string
            "managed application authority path must be root-owned"
      in
      let resolved = Filename_unix.realpath authority_file in
      let%bind () = validate_directory (Filename.dirname resolved) in
      let path_stats = Caml_unix.lstat resolved in
      let%bind () =
        if
          Poly.equal path_stats.st_kind Caml_unix.S_REG
          && Int.equal path_stats.st_uid 0
          && Int.equal (path_stats.st_perm land 0o022) 0
        then Ok ()
        else
          Or_error.error_string
            "managed application authority must resolve to a root-owned \
             regular file that is not group/other writable"
      in
      let descriptor =
        Caml_unix.openfile resolved
          [ Caml_unix.O_RDONLY; Caml_unix.O_CLOEXEC ]
          0
      in
      Exn.protect
        ~finally:(fun () -> Caml_unix.close descriptor)
        ~f:(fun () ->
          let before = Caml_unix.fstat descriptor in
          let open Or_error.Let_syntax in
          let%bind () =
            if
              Int.equal path_stats.st_dev before.st_dev
              && Int.equal path_stats.st_ino before.st_ino
            then Ok ()
            else
              Or_error.error_string
                "managed application authority was replaced while opening"
          in
          if before.st_size > maximum_authority_file_bytes then
            Or_error.error_string
              "managed application authority exceeds 262144 bytes"
          else
            let length = before.st_size in
            let bytes = Bytes.create length in
            let rec read_all offset =
              if offset < length then
                let count =
                  Caml_unix.read descriptor bytes offset (length - offset)
                in
                if Int.equal count 0 then
                  failwith
                    "unexpected EOF while reading managed application authority"
                else read_all (offset + count)
            in
            read_all 0;
            let after = Caml_unix.fstat descriptor in
            if
              before.st_dev <> after.st_dev
              || before.st_ino <> after.st_ino
              || before.st_size <> after.st_size
              || Float.(before.st_mtime <> after.st_mtime)
            then
              Or_error.error_string
                "managed application authority changed while being read"
            else all_of_json (Bytes.to_string bytes)))

let load_authority_file_if_present () =
  try
    let directory = Caml_unix.lstat (Filename.dirname authority_file) in
    if
      Poly.equal directory.st_kind Caml_unix.S_DIR
      && Int.equal directory.st_uid 0
      && Int.equal (directory.st_perm land 0o022) 0
    then
      (try
         ignore (Caml_unix.lstat authority_file);
         load_authority_file ()
       with
       | Caml_unix.Unix_error (Caml_unix.ENOENT, _, _) -> Ok [])
    else Ok []
  with
  | Caml_unix.Unix_error (Caml_unix.ENOENT, _, _) -> Ok []

let find applications key =
  match
    List.find applications ~f:(fun application ->
        String.equal application.key key)
  with
  | Some application -> Ok application
  | None -> Or_error.errorf "application %s is not managed by this host" key
