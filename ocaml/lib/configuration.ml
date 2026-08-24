open Core

let contains_nul value = String.mem value '\000'

let non_empty_string ~field = function
  | `String value
    when (not (String.is_empty (String.strip value)))
         && not (contains_nul value) ->
      Ok value
  | _ -> Or_error.errorf "%s must be a non-empty string without NUL bytes" field

let string_without_nul ~field = function
  | `String value when not (contains_nul value) -> Ok value
  | _ -> Or_error.errorf "%s must be a string without NUL bytes" field

let required fields name parse =
  match List.Assoc.find fields ~equal:String.equal name with
  | Some value -> parse ~field:name value
  | None -> Or_error.errorf "%s is required" name

let optional fields name parse ~default =
  match List.Assoc.find fields ~equal:String.equal name with
  | None -> Ok default
  | Some value -> parse ~field:name value

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

let validate_map_members ~field fields =
  let rec loop seen = function
    | [] -> Ok ()
    | (name, _) :: rest ->
        if Set.mem seen name then
          Or_error.errorf "%s contains duplicate member %s" field name
        else loop (Set.add seen name) rest
  in
  loop String.Set.empty fields

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

let string_list parse ~field = function
  | `List values ->
      Or_error.all
        (List.mapi values ~f:(fun index value ->
             parse ~field:(sprintf "%s[%d]" field index) value))
  | _ -> Or_error.errorf "%s must be a list of strings" field

let non_empty_string_list = string_list non_empty_string
let argv = string_list string_without_nul

let nullable_argv ~field = function
  | `Null -> Ok None
  | `List [] -> Or_error.errorf "%s must not be empty when specified" field
  | json -> Or_error.map (argv ~field json) ~f:Option.some

module Read_only_bind = struct
  type t = { source : string; destination : string }

  let source t = t.source
  let destination t = t.destination

  let safe_mount_path ~field = function
    | `String path ->
        let rec contains_unsafe_code_point index =
          if index >= String.length path then false
          else
            let decoded = Stdlib.String.get_utf_8_uchar path index in
            if not (Stdlib.Uchar.utf_decode_is_valid decoded) then true
            else
              let code_point =
                Stdlib.Uchar.utf_decode_uchar decoded |> Stdlib.Uchar.to_int
              in
              code_point <= 0x1f
              || (code_point >= 0x7f && code_point <= 0x9f)
              || contains_unsafe_code_point
                   (index + Stdlib.Uchar.utf_decode_length decoded)
        in
        let normalized_segments =
          String.is_prefix path ~prefix:"/"
          && (not (String.equal path "/"))
          && String.split path ~on:'/' |> List.tl_exn
             |> List.for_all ~f:(fun segment ->
                 (not (String.is_empty segment))
                 && (not (String.equal segment "."))
                 && not (String.equal segment ".."))
        in
        if
          normalized_segments
          && (not (String.mem path ','))
          && not (contains_unsafe_code_point 0)
        then Ok path
        else
          Or_error.errorf
            "%s must be a non-root absolute normalized Unix path without \
             commas or control characters"
            field
    | _ -> Or_error.errorf "%s must be a string" field

  let of_json ~field = function
    | `Assoc fields ->
        let open Or_error.Let_syntax in
        let%bind () =
          validate_members ~field
            ~allowed:(String.Set.of_list [ "source"; "destination" ])
            fields
        in
        let%bind source =
          required fields "source" (fun ~field:_ json ->
              safe_mount_path ~field:(field ^ ".source") json)
        and destination =
          required fields "destination" (fun ~field:_ json ->
              safe_mount_path ~field:(field ^ ".destination") json)
        in
        if String.equal source destination then
          Or_error.errorf "%s source and destination must differ" field
        else Ok { source; destination }
    | _ -> Or_error.errorf "%s must be an object" field
end

module Run = struct
  type t = {
    command : string list option;
    environment : (string * string) list;
    pre_start : string list list;
    network : string option;
    ports : string list;
    read_only_binds : Read_only_bind.t list;
  }

  let command t = t.command
  let environment t = t.environment
  let pre_start t = t.pre_start
  let network t = t.network
  let ports t = t.ports
  let read_only_binds t = t.read_only_binds

  let rendered_environment t ~port ~revision =
    let render value =
      let value =
        Option.value_map port ~default:value ~f:(fun port ->
            String.substr_replace_all value ~pattern:"{port}"
              ~with_:(Int.to_string port))
      in
      Option.value_map revision ~default:value ~f:(fun revision ->
          String.substr_replace_all value ~pattern:"{revision}" ~with_:revision)
    in
    List.map t.environment ~f:(fun (name, value) -> (name, render value))

  let empty =
    {
      command = None;
      environment = [];
      pre_start = [];
      network = None;
      ports = [];
      read_only_binds = [];
    }

  let environment_value ~field = function
    | `Assoc values ->
        let open Or_error.Let_syntax in
        let%bind () = validate_map_members ~field values in
        Or_error.all
          (List.map values ~f:(fun (name, value) ->
               let open Or_error.Let_syntax in
               let%bind name =
                 non_empty_string ~field:(field ^ " key") (`String name)
               in
               let%map value =
                 string_without_nul ~field:(field ^ "." ^ name) value
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
               | json -> argv ~field:(sprintf "%s[%d]" field index) json))
    | _ -> Or_error.errorf "%s must be a list of argv lists" field

  let read_only_binds_value ~field = function
    | `List binds ->
        let open Or_error.Let_syntax in
        let%bind binds =
          Or_error.all
            (List.mapi binds ~f:(fun index bind ->
                 Read_only_bind.of_json
                   ~field:(sprintf "%s[%d]" field index)
                   bind))
        in
        let rec unique_destinations seen = function
          | [] -> Ok binds
          | bind :: rest ->
              let destination = Read_only_bind.destination bind in
              if Set.mem seen destination then
                Or_error.errorf "%s contains duplicate destination %s" field
                  destination
              else unique_destinations (Set.add seen destination) rest
        in
        unique_destinations String.Set.empty binds
    | _ -> Or_error.errorf "%s must be a list" field

  let of_json ~schema ~field = function
    | `Assoc fields ->
        let open Or_error.Let_syntax in
        let%bind () =
          validate_members ~field
            ~allowed:
              (String.Set.of_list
                 [
                   "command";
                   "environment";
                   "preStart";
                   "network";
                   "ports";
                   "readOnlyBinds";
                 ])
            fields
        in
        let%bind () =
          match List.Assoc.find fields ~equal:String.equal "readOnlyBinds" with
          | None -> Ok ()
          | Some _ when String.equal schema "v0.4" -> Ok ()
          | Some _ ->
              Or_error.errorf
                "%s.readOnlyBinds requires nixploy configuration schema v0.4"
                field
        in
        let%map command = optional fields "command" nullable_argv ~default:None
        and environment =
          optional fields "environment" environment_value ~default:[]
        and pre_start = optional fields "preStart" pre_start_value ~default:[]
        and network = optional fields "network" nullable_string ~default:None
        and ports = optional fields "ports" non_empty_string_list ~default:[]
        and read_only_binds =
          optional fields "readOnlyBinds" read_only_binds_value ~default:[]
        in
        { command; environment; pre_start; network; ports; read_only_binds }
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
        let%bind () =
          validate_members ~field
            ~allowed:(String.Set.of_list [ "domain"; "healthPath"; "slots" ])
            fields
        in
        let%bind raw_domain = required fields "domain" non_empty_string in
        let%bind domain = Endpoint_identity.domain raw_domain in
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
          | Some (`Assoc slots) ->
              let%map () =
                validate_members ~field:(field ^ ".slots")
                  ~allowed:(String.Set.of_list [ "blue"; "green" ])
                  slots
              in
              slots
          | Some _ -> Or_error.error_string "web.slots must be an object"
        in
        let%bind blue_port = optional slots "blue" port_value ~default:8080
        and green_port = optional slots "green" port_value ~default:8081 in
        if Int.equal blue_port green_port then
          Or_error.error_string "blue and green ports must differ"
        else Ok { domain; health_path; blue_port; green_port }
    | _ -> Or_error.errorf "%s must be an object" field
end

module Coordination_profile = struct
  type t = { coordination_scope : string }

  let coordination_scope t = t.coordination_scope

  let of_json ~field = function
    | `Assoc fields ->
        let open Or_error.Let_syntax in
        let%bind () =
          validate_members ~field
            ~allowed:(String.Set.of_list [ "coordinationScope" ])
            fields
        in
        let%bind raw_scope =
          required fields "coordinationScope" non_empty_string
        in
        let%map coordination_scope =
          Endpoint_identity.coordination_scope raw_scope
        in
        { coordination_scope }
    | _ -> Or_error.errorf "%s must be an object" field
end

module Production = Coordination_profile
module Non_production = Coordination_profile

module Target = struct
  type kind = Non_web | Web of Web.t

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
    production : Production.t option;
    non_production : Non_production.t option;
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
  let production t = t.production
  let non_production t = t.non_production
  let kind t = Option.value_map t.web ~default:Non_web ~f:(fun web -> Web web)

  let require_web t =
    match t.web with
    | None -> Or_error.error_string "target does not declare web routing"
    | Some web -> Ok web
end

type t = { project : Project_name.t; targets : Target.t list }

let project t = t.project
let targets t = t.targets

let secret_references ~field = function
  | `Assoc references ->
      let open Or_error.Let_syntax in
      let%bind () = validate_map_members ~field references in
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

let parse_target ~schema (raw_name, json) =
  let open Or_error.Let_syntax in
  let field = "targets." ^ raw_name in
  let%bind name = Target_name.of_string raw_name in
  match json with
  | `Assoc fields ->
      let allowed =
        String.Set.of_list
          [
            "image";
            "ip";
            "user";
            "port";
            "identityFile";
            "run";
            "web";
            "secrets";
            "production";
            "nonProduction";
          ]
        |> fun allowed ->
        if String.equal schema "v0.3" then Set.add allowed "tasks" else allowed
      in
      let%bind () = validate_members ~field ~allowed fields in
      let%bind () =
        match List.Assoc.find fields ~equal:String.equal "tasks" with
        | None | Some (`Assoc []) -> Ok ()
        | Some _ ->
            Or_error.errorf
              "%s.tasks declares named operational tasks, which are not \
               supported by the OCaml application"
              field
      in
      let%bind image = required fields "image" non_empty_string
      and raw_host = required fields "ip" non_empty_string
      and user = optional fields "user" non_empty_string ~default:"root"
      and port = optional fields "port" port_value ~default:22
      and identity_file =
        optional fields "identityFile" nullable_string ~default:None
      and run =
        optional fields "run"
          (fun ~field:_ -> Run.of_json ~schema ~field:(field ^ ".run"))
          ~default:Run.empty
      and web =
        optional fields "web"
          (fun ~field:_ -> function
            | `Null -> Ok None
            | json ->
                Or_error.map
                  (Web.of_json ~field:(field ^ ".web") json)
                  ~f:Option.some)
          ~default:None
      and secret_references =
        optional fields "secrets"
          (fun ~field:_ -> secret_references ~field:(field ^ ".secrets"))
          ~default:[]
      and production =
        optional fields "production"
          (fun ~field:_ -> function
            | `Null -> Ok None
            | json ->
                Or_error.map
                  (Production.of_json ~field:(field ^ ".production") json)
                  ~f:Option.some)
          ~default:None
      and non_production =
        optional fields "nonProduction"
          (fun ~field:_ -> function
            | `Null -> Ok None
            | json ->
                Or_error.map
                  (Non_production.of_json ~field:(field ^ ".nonProduction") json)
                  ~f:Option.some)
          ~default:None
      in
      let%bind host = Endpoint_identity.host raw_host in
      if Option.is_some production && Option.is_some non_production then
        Or_error.errorf "%s cannot be both production and nonProduction" field
      else
        Ok
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
            production;
            non_production;
          }
  | _ -> Or_error.error_string "target must be an object"

let of_json input =
  let open Or_error.Let_syntax in
  let%bind json = Or_error.try_with (fun () -> Yojson.Safe.from_string input) in
  match json with
  | `Assoc fields ->
      let%bind () =
        validate_members ~field:"nixploy configuration"
          ~allowed:(String.Set.of_list [ "__schema"; "project"; "targets" ])
          fields
      in
      let%bind schema = required fields "__schema" non_empty_string in
      let%bind () =
        if List.mem [ "v0.2"; "v0.3"; "v0.4" ] schema ~equal:String.equal then
          Ok ()
        else
          Or_error.errorf "unsupported nixploy configuration schema %s" schema
      in
      let%bind project_text = required fields "project" non_empty_string in
      let%bind project = Project_name.of_string project_text in
      let%bind targets_json =
        match List.Assoc.find fields ~equal:String.equal "targets" with
        | Some (`Assoc targets) ->
            let%map () = validate_map_members ~field:"targets" targets in
            targets
        | Some _ -> Or_error.error_string "targets must be an object"
        | None -> Or_error.error_string "targets is required"
      in
      let%map targets =
        Or_error.all (List.map targets_json ~f:(parse_target ~schema))
      in
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
