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
  subdirectory : string;
  production_destination : production_destination option;
}

let maximum_count = 64
let key t = t.key
let project t = t.project
let target t = t.target
let repository t = t.repository
let repository_identity t = t.repository_identity
let repository_provenance t = t.repository_provenance
let production_destination t = t.production_destination
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

let parse_production_destination fields =
  match List.Assoc.find fields ~equal:String.equal "production" with
  | None | Some `Null -> Ok None
  | Some (`Assoc fields) ->
      let open Or_error.Let_syntax in
      let%bind () =
        validate_members ~field:"managed application production destination"
          ~allowed:
            (String.Set.of_list
               [ "host"; "user"; "port"; "kind"; "domain"; "coordinationScope" ])
          fields
      in
      let%bind host = required_string fields "host"
      and user = required_string fields "user"
      and coordination_scope = required_string fields "coordinationScope" in
      let%bind port =
        match List.Assoc.find fields ~equal:String.equal "port" with
        | Some (`Int port) when port >= 1 && port <= 65_535 -> Ok port
        | _ ->
            Or_error.error_string "production.port must be between 1 and 65535"
      in
      let%bind kind =
        match List.Assoc.find fields ~equal:String.equal "kind" with
        | Some (`String "non-web") -> Ok Non_web
        | Some (`String "web") -> Ok Web
        | _ -> Or_error.error_string "production.kind must be non-web or web"
      in
      let%bind domain =
        match (kind, List.Assoc.find fields ~equal:String.equal "domain") with
        | Non_web, (None | Some `Null) -> Ok None
        | Web, Some (`String domain)
          when not (String.is_empty (String.strip domain)) ->
            Ok (Some domain)
        | Non_web, Some _ ->
            Or_error.error_string
              "production non-web destination cannot declare domain"
        | Web, _ ->
            Or_error.error_string "production web destination requires domain"
      in
      if String.equal user "root" then
        Or_error.error_string "production destination SSH user must not be root"
      else Ok (Some { host; user; port; kind; domain; coordination_scope })
  | Some _ -> Or_error.error_string "production must be an object"

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
                   "subdirectory";
                   "production";
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
        let%bind subdirectory =
          optional_string fields "subdirectory" ~default:"."
        in
        let%bind production_destination = parse_production_destination fields in
        if
          Option.is_some production_destination
          && ((not repository_identity_is_explicit)
             || Option.is_none repository_provenance)
        then
          Or_error.error_string
            "production managed application requires explicit \
             repositoryIdentity and repositoryProvenance"
        else if not (Filename.is_absolute repository) then
          Or_error.error_string
            "managed application repository must be absolute"
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
              subdirectory;
              production_destination;
            }
    | _ -> Or_error.error_string "managed application must be an object"

let canonical_working_directory application =
  let working_directory = working_directory application in
  Or_error.try_with (fun () -> Filename_unix.realpath working_directory)
  |> Result.ok
  |> Option.value ~default:working_directory

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
      Ok
        (List.sort parsed ~compare:(fun left right ->
             String.compare left.key right.key))
  | _ -> Or_error.error_string "managed applications must be a JSON object"

let load_environment () =
  Sys.getenv "NIXPLOY_MANAGED_APPLICATIONS_JSON"
  |> Option.value ~default:"{}" |> all_of_json

let find applications key =
  match
    List.find applications ~f:(fun application ->
        String.equal application.key key)
  with
  | Some application -> Ok application
  | None -> Or_error.errorf "application %s is not managed by this host" key
