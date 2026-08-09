open Core

let contains_nul value = String.mem value '\000'

let non_empty_string ~field = function
  | `String value
    when (not (String.is_empty (String.strip value)))
         && not (contains_nul value) ->
      Ok value
  | _ -> Or_error.errorf "%s must be a non-empty string without NUL bytes" field

let required fields name parse =
  match List.Assoc.find fields ~equal:String.equal name with
  | Some value -> parse ~field:name value
  | None -> Or_error.errorf "%s is required" name

let optional fields name parse ~default =
  match List.Assoc.find fields ~equal:String.equal name with
  | None -> Ok default
  | Some value -> parse ~field:name value

let int_value ~field = function
  | `Int value -> Ok value
  | _ -> Or_error.errorf "%s must be an integer" field

let port_value ~field json =
  let open Or_error.Let_syntax in
  let%bind port = int_value ~field json in
  if port >= 1 && port <= 65_535 then Ok port
  else Or_error.errorf "%s must be between 1 and 65535" field

let nullable_string ~field = function
  | `Null -> Ok None
  | json -> Or_error.map (non_empty_string ~field json) ~f:Option.some

let string_list ~field = function
  | `List values ->
      Or_error.all
        (List.mapi values ~f:(fun index value ->
             non_empty_string ~field:(sprintf "%s[%d]" field index) value))
  | _ -> Or_error.errorf "%s must be a list of strings" field

let nullable_argv ~field = function
  | `Null -> Ok None
  | `List [] -> Or_error.errorf "%s must not be empty when specified" field
  | json -> Or_error.map (string_list ~field json) ~f:Option.some

module Run = struct
  type t = {
    command : string list option;
    environment : (string * string) list;
    pre_start : string list list;
    network : string option;
    ports : string list;
  }

  let command t = t.command
  let environment t = t.environment
  let pre_start t = t.pre_start
  let network t = t.network
  let ports t = t.ports

  let rendered_environment t ~port =
    let port = Int.to_string port in
    List.map t.environment ~f:(fun (name, value) ->
        (name, String.substr_replace_all value ~pattern:"{port}" ~with_:port))

  let empty =
    {
      command = None;
      environment = [];
      pre_start = [];
      network = None;
      ports = [];
    }

  let environment_value ~field = function
    | `Assoc values ->
        Or_error.all
          (List.map values ~f:(fun (name, value) ->
               let open Or_error.Let_syntax in
               let%bind name =
                 non_empty_string ~field:(field ^ " key") (`String name)
               in
               let%map value =
                 non_empty_string ~field:(field ^ "." ^ name) value
               in
               (name, value)))
    | _ -> Or_error.errorf "%s must be an object of strings" field

  let pre_start_value ~field = function
    | `List commands ->
        Or_error.all
          (List.mapi commands ~f:(fun index command ->
               match command with
               | `List [] ->
                   Or_error.errorf "%s[%d] must not be empty" field index
               | json -> string_list ~field:(sprintf "%s[%d]" field index) json))
    | _ -> Or_error.errorf "%s must be a list of argv lists" field

  let of_json ~field = function
    | `Assoc fields ->
        let open Or_error.Let_syntax in
        let%map command = optional fields "command" nullable_argv ~default:None
        and environment =
          optional fields "environment" environment_value ~default:[]
        and pre_start = optional fields "preStart" pre_start_value ~default:[]
        and network = optional fields "network" nullable_string ~default:None
        and ports = optional fields "ports" string_list ~default:[] in
        { command; environment; pre_start; network; ports }
    | _ -> Or_error.errorf "%s must be an object" field
end

module Web = struct
  type t = {
    domain : string;
    health_path : string;
    blue_port : int;
    green_port : int;
  }

  let domain t = t.domain
  let health_path t = t.health_path
  let blue_port t = t.blue_port
  let green_port t = t.green_port

  let of_json ~field = function
    | `Assoc fields ->
        let open Or_error.Let_syntax in
        let%bind domain = required fields "domain" non_empty_string in
        let%bind health_path =
          optional fields "healthPath" non_empty_string ~default:"/health"
        in
        let%bind () =
          if String.is_prefix health_path ~prefix:"/" then Ok ()
          else Or_error.error_string "healthPath must begin with /"
        in
        let%bind slots =
          match List.Assoc.find fields ~equal:String.equal "slots" with
          | None -> Ok []
          | Some (`Assoc slots) -> Ok slots
          | Some _ -> Or_error.error_string "web.slots must be an object"
        in
        let%bind blue_port = optional slots "blue" port_value ~default:8080
        and green_port = optional slots "green" port_value ~default:8081 in
        if Int.equal blue_port green_port then
          Or_error.error_string "blue and green ports must differ"
        else Ok { domain; health_path; blue_port; green_port }
    | _ -> Or_error.errorf "%s must be an object" field
end

module Target = struct
  type t = {
    name : Target_name.t;
    image : string;
    host : string;
    user : string;
    port : int;
    identity_file : string option;
    run : Run.t;
    web : Web.t option;
    secret_references : (string * string) list;
  }

  let name t = t.name
  let image t = t.image
  let host t = t.host
  let user t = t.user
  let port t = t.port
  let identity_file t = t.identity_file
  let run t = t.run
  let web t = t.web
  let secret_references t = t.secret_references

  let require_web t =
    match t.web with
    | None ->
        Or_error.error_string
          "the OCaml deployment path currently supports web targets only"
    | Some web -> Ok web
end

type t = { project : Project_name.t; targets : Target.t list }

let project t = t.project
let targets t = t.targets

let secret_references ~field = function
  | `Assoc references ->
      Or_error.all
        (List.map references ~f:(fun (name, value) ->
             let open Or_error.Let_syntax in
             let%bind name =
               non_empty_string ~field:(field ^ " key") (`String name)
             in
             let%map path =
               non_empty_string ~field:(field ^ "." ^ name) value
             in
             (name, path)))
  | _ -> Or_error.errorf "%s must be an object" field

let parse_target (name, json) =
  let open Or_error.Let_syntax in
  let%bind name = Target_name.of_string name in
  match json with
  | `Assoc fields ->
      let%map image = required fields "image" non_empty_string
      and host = required fields "ip" non_empty_string
      and user = optional fields "user" non_empty_string ~default:"root"
      and port = optional fields "port" port_value ~default:22
      and identity_file =
        optional fields "identityFile" nullable_string ~default:None
      and run = optional fields "run" Run.of_json ~default:Run.empty
      and web =
        optional fields "web"
          (fun ~field -> function
            | `Null -> Ok None
            | json -> Or_error.map (Web.of_json ~field json) ~f:Option.some)
          ~default:None
      and secret_references =
        optional fields "secrets" secret_references ~default:[]
      in
      {
        Target.name;
        image;
        host;
        user;
        port;
        identity_file;
        run;
        web;
        secret_references;
      }
  | _ -> Or_error.error_string "target must be an object"

let of_json input =
  let open Or_error.Let_syntax in
  let%bind json = Or_error.try_with (fun () -> Yojson.Safe.from_string input) in
  match json with
  | `Assoc fields ->
      let%bind schema = required fields "__schema" non_empty_string in
      let%bind () =
        if List.mem [ "v0.2"; "v0.3" ] schema ~equal:String.equal then Ok ()
        else
          Or_error.errorf "unsupported nixploy configuration schema %s" schema
      in
      let%bind project_text = required fields "project" non_empty_string in
      let%bind project = Project_name.of_string project_text in
      let%bind targets_json =
        match List.Assoc.find fields ~equal:String.equal "targets" with
        | Some (`Assoc targets) -> Ok targets
        | Some _ -> Or_error.error_string "targets must be an object"
        | None -> Or_error.error_string "targets is required"
      in
      let%map targets = Or_error.all (List.map targets_json ~f:parse_target) in
      { project; targets }
  | _ -> Or_error.error_string "nixploy configuration must be an object"

let find_target t name =
  match
    List.find t.targets ~f:(fun target ->
        Target_name.equal (Target.name target) name)
  with
  | Some target -> Ok target
  | None ->
      Or_error.errorf "target %s is not declared by .#nixploy"
        (Target_name.to_string name)
