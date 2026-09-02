open Core

let configuration =
  {|
{
  "__schema": "v0.4",
  "project": "sample",
  "controlPlane": {
    "authorityAlias": "netcup",
    "managedApplicationKey": "sample-production"
  },
  "targets": {
    "production": { "image": "image", "ip": "target.example.invalid" }
  }
}
|}

let () =
  let parsed = Nixploy.Configuration.of_json configuration |> Or_error.ok_exn in
  let control_plane =
    Nixploy.Configuration.control_plane parsed |> Option.value_exn
  in
  assert (
    String.equal
      (Nixploy.Configuration.Control_plane.authority_alias control_plane)
      "netcup");
  assert (
    String.equal
      (Nixploy.Configuration.Control_plane.managed_application_key control_plane)
      "sample-production");
  assert (
    Result.is_error
      (Nixploy.Configuration.of_json
         (String.substr_replace_first configuration ~pattern:"\"netcup\""
            ~with_:"\"Netcup\"")))
