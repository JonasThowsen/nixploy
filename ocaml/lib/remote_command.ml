open Core

let shell_quote value =
  "'" ^ String.substr_replace_all value ~pattern:"'" ~with_:"'\\''" ^ "'"

let ssh_args target remote_argv =
  let identity =
    Configuration.Target.identity_file target
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

let run ?stdin ~target ~timeout ~max_output_bytes remote_argv =
  Process_runner.run ?stdin ~timeout ~max_output_bytes ~prog:"ssh"
    ~args:(ssh_args target remote_argv)
    ()
