open Core

let default () =
  match Sys.getenv "NIXPLOY_STATE_DB" with
  | Some path -> path
  | None ->
      let state_home =
        Sys.getenv "XDG_STATE_HOME"
        |> Option.value_map
             ~default:
               (Filename.concat (Sys_unix.home_directory ()) ".local/state")
             ~f:Fn.id
      in
      Filename.concat state_home "nixploy/state.db"
