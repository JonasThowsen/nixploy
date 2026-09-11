open Core
module Output = Nixploy_cli_mapping.Inspection_output

let () =
  let deployment =
    Nixploy.Application.For_testing.deployment ~id:"operation-1" ~state:Failed
      ~stage:"starting" ~message:"failed\n\"quoted\"" ~error:"uncertain"
      ~requested_at_ms:123L ()
  in
  let json = Output.deployment_json deployment |> Yojson.Safe.from_string in
  let open Yojson.Safe.Util in
  assert (String.equal (json |> member "id" |> to_string) "operation-1");
  assert (String.equal (json |> member "state" |> to_string) "failed");
  assert (
    String.equal (json |> member "message" |> to_string) "failed\n\"quoted\"");
  assert (json |> member "requestedAtMs" |> to_int = 123);
  assert (Poly.equal (json |> member "revision") `Null);
  assert (Poly.equal (json |> member "finishedAtMs") `Null);
  assert (
    Poly.equal
      (Output.history_json [ deployment ] |> Yojson.Safe.from_string)
      (`List [ json ]));
  let logs : Nixploy.Application.log_snapshot =
    {
      container_name = "owned-container";
      revision = Some "revision";
      observed_at_ms = 456L;
      truncated = true;
      lines = [ { timestamp = None; text = "line\nwith\"quotes" } ];
    }
  in
  let json = Output.logs_json logs |> Yojson.Safe.from_string in
  assert (json |> member "truncated" |> to_bool);
  assert (
    String.equal (json |> member "container" |> to_string) "owned-container");
  let line = json |> member "lines" |> to_list |> List.hd_exn in
  assert (Poly.equal (line |> member "timestamp") `Null);
  assert (String.equal (line |> member "text" |> to_string) "line\nwith\"quotes");
  printf
    "inspection JSON: stable keys, numbers, nulls, arrays, escaping passed\n"
