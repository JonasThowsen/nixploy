open Async
open Core

let shell_quote value =
  "'" ^ String.substr_replace_all value ~pattern:"'" ~with_:"'\\''" ^ "'"

let expand_home path =
  if String.is_prefix path ~prefix:"~/" then
    Filename.concat (Sys_unix.home_directory ()) (String.drop_prefix path 2)
  else path

let identity_file target =
  let configured =
    Sys.getenv "NIXPLOY_SSH_IDENTITY_FILE"
    |> Option.filter ~f:(Fn.non (Fn.compose String.is_empty String.strip))
  in
  Option.first_some configured (Configuration.Target.identity_file target)
  |> Option.map ~f:expand_home

let ssh_args target remote_argv =
  let identity =
    identity_file target
    |> Option.value_map ~default:[] ~f:(fun path -> [ "-i"; path ])
  in
  let known_hosts =
    Sys.getenv "NIXPLOY_SSH_KNOWN_HOSTS_FILE"
    |> Option.value_map ~default:[] ~f:(fun path ->
        [ "-o"; "UserKnownHostsFile=" ^ path ])
  in
  [
    "-o";
    "BatchMode=yes";
    "-o";
    "StrictHostKeyChecking=yes";
    "-o";
    "ConnectTimeout=10";
    "-p";
    Int.to_string (Configuration.Target.port target);
  ]
  @ known_hosts @ identity
  @ [
      "--";
      Configuration.Target.user target ^ "@" ^ Configuration.Target.host target;
      String.concat ~sep:" " (List.map remote_argv ~f:shell_quote);
    ]

let destination target =
  sprintf "%s@%s:%d"
    (Configuration.Target.user target)
    (Configuration.Target.host target)
    (Configuration.Target.port target)

let contains_any text patterns =
  let text = String.lowercase text in
  List.exists patterns ~f:(fun pattern ->
      String.is_substring text ~substring:(String.lowercase pattern))

let identity_description target =
  match identity_file target with
  | None -> "no identityFile is configured"
  | Some path -> (
      match Core_unix.access path [ `Read ] with
      | Ok () -> sprintf "identity file %s is readable" path
      | Error _ -> sprintf "identity file %s is missing or unreadable" path)

let failure_hint target stderr =
  let host = Configuration.Target.host target in
  let port = Configuration.Target.port target in
  if
    contains_any stderr
      [
        "Permission denied (publickey";
        "unable to authenticate";
        "no supported methods remain";
        "Too many authentication failures";
      ]
  then
    if contains_any stderr [ "agent refused operation" ] then
      "The ssh-agent refused to sign. The key was probably added with \
       confirmation (ssh-add -c) and nothing can show the prompt; re-add it \
       without -c."
    else
      sprintf
        "No usable SSH key was offered: %s, and %s. Batch mode cannot prompt \
         for a passphrase, so load the key into an ssh-agent this process can \
         reach, or set NIXPLOY_SSH_IDENTITY_FILE to a readable key without a \
         passphrase."
        (Tool_environment.describe_ssh_agent ())
        (identity_description target)
  else if
    contains_any stderr
      [
        "Host key verification failed";
        "host key for";
        "No ED25519 host key is known";
        "No RSA host key is known";
        "No ECDSA host key is known";
        "knownhosts: key is unknown";
        "key mismatch";
      ]
  then
    sprintf
      "The host key for %s is not trusted by this process. Verify it once \
       from a trusted terminal (`ssh -p %d %s@%s true`), or point \
       NIXPLOY_SSH_KNOWN_HOSTS_FILE at a known_hosts file that contains it. \
       Never disable host-key checking."
      host port
      (Configuration.Target.user target)
      host
  else if
    contains_any stderr
      [
        "Could not resolve hostname";
        "Name or service not known";
        "Temporary failure in name resolution";
        "Network is unreachable";
        "No route to host";
        "Operation not permitted";
        "Connection timed out";
        "timed out";
      ]
  then
    sprintf
      "%s:%d is unreachable from this process. If nixploy runs inside an \
       agent or sandbox, allow outbound TCP to that address."
      host port
  else if contains_any stderr [ "Connection refused" ] then
    sprintf "Nothing accepts SSH connections on %s:%d." host port
  else if contains_any stderr [ "Bad owner or permissions" ] then
    "The local SSH configuration has unsafe permissions; fix the file named \
     above."
  else
    sprintf "SSH could not connect: %s, and %s." (Tool_environment.describe_ssh_agent ())
      (identity_description target)

let ssh_failure target stderr =
  let lines =
    String.split_lines stderr
    |> List.map ~f:String.strip
    |> List.filter ~f:(Fn.non String.is_empty)
  in
  let detail =
    List.drop lines (Int.max 0 (List.length lines - 5))
    |> String.concat ~sep:" "
  in
  Error.createf "NIXPLOY_SSH_FAILED: cannot run a command on %s over SSH%s. %s"
    (destination target)
    (if String.is_empty detail then "" else " (" ^ detail ^ ")")
    (failure_hint target stderr)

let run ?stdin ?ignore_termination ~target ~timeout ~max_output_bytes
    remote_argv =
  let open Deferred.Or_error.Let_syntax in
  let%bind result =
    Process_runner.run ?stdin ?ignore_termination ~timeout ~max_output_bytes
      ~prog:"ssh"
      ~args:(ssh_args target remote_argv)
      ()
  in
  match result.exit_status with
  | Error (`Exit_non_zero 255) ->
      (* 255 is ssh's own failure status; remote commands used here never
         return it. *)
      Deferred.Or_error.fail (ssh_failure target result.stderr)
  | _ -> Deferred.Or_error.return result
