open Async
open Core

type evaluated = { configuration : Configuration.t; json : string }

let max_configuration_bytes = 1_048_576
let evaluation_timeout = Time_ns.Span.of_min 1.
let configuration t = t.configuration
let json t = t.json

let load_evaluated ~working_directory =
  let open Deferred.Or_error.Let_syntax in
  let%bind json =
    Process_runner.run_stdout ~working_directory ~timeout:evaluation_timeout
      ~max_output_bytes:max_configuration_bytes ~prog:"nix"
      ~args:[ "eval"; "--json"; "--no-write-lock-file"; ".#nixploy" ]
      ()
  in
  let%map configuration = Deferred.return (Configuration.of_json json) in
  { configuration; json }

let load ~working_directory =
  let%map result = load_evaluated ~working_directory in
  Or_error.map result ~f:configuration
