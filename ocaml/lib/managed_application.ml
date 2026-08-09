open Core

type t = {
  key : string;
  project : Project_name.t;
  target : Target_name.t;
  repository : string;
  subdirectory : string;
}

let key t = t.key
let project t = t.project
let target t = t.target
let repository t = t.repository

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
        let%bind project =
          required_string fields "project" >>= Project_name.of_string
        in
        let%bind target =
          required_string fields "target" >>= Target_name.of_string
        in
        let%bind repository = required_string fields "repository" in
        let%bind subdirectory =
          optional_string fields "subdirectory" ~default:"."
        in
        if not (Filename.is_absolute repository) then
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
          Ok { key; project; target; repository; subdirectory }
    | _ -> Or_error.error_string "managed application must be an object"

let all_of_json input =
  let open Or_error.Let_syntax in
  let%bind json = Or_error.try_with (fun () -> Yojson.Safe.from_string input) in
  match json with
  | `Assoc applications ->
      Or_error.all (List.map applications ~f:parse)
      |> Or_error.map
           ~f:
             (List.sort ~compare:(fun left right ->
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
