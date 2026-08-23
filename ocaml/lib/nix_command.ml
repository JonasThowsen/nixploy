open Core

let output_reference ~flake output = flake ^ "#" ^ output
let lock_args = [ "--no-update-lock-file"; "--no-write-lock-file" ]

let evaluation_args ~offline ~flake ~output =
  [ "eval"; "--json" ]
  @ (if offline then [ "--offline" ] else [])
  @ lock_args
  @ [ output_reference ~flake output ]

let build_args ~flake ~output =
  [ "build" ] @ lock_args
  @ [ output_reference ~flake output; "--print-out-paths"; "--no-link" ]
