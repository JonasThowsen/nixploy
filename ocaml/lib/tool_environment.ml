open Async
open Core

let connectable path =
  match Core_unix.stat path with
  | { st_kind = S_SOCK; _ } -> (
      try
        let socket =
          Core_unix.socket ~domain:PF_UNIX ~kind:SOCK_STREAM ~protocol:0 ()
        in
        Exn.protect
          ~f:(fun () ->
            Core_unix.connect socket ~addr:(ADDR_UNIX path);
            true)
          ~finally:(fun () -> Core_unix.close socket)
      with _ -> false)
  | _ -> false
  | exception _ -> false

let configured_agent () =
  Sys.getenv "SSH_AUTH_SOCK"
  |> Option.map ~f:String.strip
  |> Option.filter ~f:(Fn.non String.is_empty)

let ssh_agent_usable () = Option.exists (configured_agent ()) ~f:connectable

let standard_agent_sockets () =
  let user_runtime =
    sprintf "/run/user/%d" (Core_unix.getuid ())
  in
  let runtimes =
    List.filter_opt [ Sys.getenv "XDG_RUNTIME_DIR"; Some user_runtime ]
    |> List.dedup_and_sort ~compare:String.compare
  in
  List.concat_map runtimes ~f:(fun runtime ->
      List.map
        [ "ssh-agent"; "gcr/ssh"; "keyring/ssh"; "gnupg/S.gpg-agent.ssh" ]
        ~f:(Filename.concat runtime))

let adopt_ssh_agent () =
  if ssh_agent_usable () then None
  else
    match List.find (standard_agent_sockets ()) ~f:connectable with
    | None -> None
    | Some socket ->
        Core_unix.putenv ~key:"SSH_AUTH_SOCK" ~data:socket;
        Some socket

let describe_ssh_agent () =
  match configured_agent () with
  | None -> "SSH_AUTH_SOCK is not set and no standard ssh-agent socket was found"
  | Some socket when connectable socket ->
      sprintf "ssh-agent %s is reachable" socket
  | Some socket ->
      sprintf
        "SSH_AUTH_SOCK=%s cannot be connected to (a sandbox may hide it)"
        socket

let rec remove_tree path =
  match Core_unix.lstat path with
  | { st_kind = S_DIR; _ } ->
      Array.iter (Sys_unix.readdir path) ~f:(fun entry ->
          remove_tree (Filename.concat path entry));
      Core_unix.rmdir path
  | _ -> Core_unix.unlink path
  | exception _ -> ()

let private_directory =
  lazy
    (let root = Filename_unix.temp_dir ~perm:0o700 "nixploy-podman-" "" in
     let runtime = Filename.concat root "run" in
     Core_unix.mkdir ~perm:0o700 runtime;
     Shutdown.at_shutdown (fun () ->
         (try remove_tree root with _ -> ());
         Deferred.unit);
     (root, runtime))

let podman () =
  let root, runtime = Lazy.force private_directory in
  `Extend
    [
      ("PODMAN_CONNECTIONS_CONF", Filename.concat root "connections.json");
      ("XDG_RUNTIME_DIR", runtime);
    ]
