open Core

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let target = Nixploy.Target_name.of_string "staging" |> assert_ok

let configuration json = Nixploy.Configuration.of_json json |> assert_ok

let unmanaged_non_production =
  configuration
    {|{"__schema":"v0.4","project":"sample","targets":{"staging":{"image":"image","ip":"target.example.invalid","nonProduction":{"coordinationScope":"sample-staging"}}}}|}

let control_plane =
  configuration
    {|{"__schema":"v0.4","project":"sample","controlPlane":{"authorityAlias":"netcup","managedApplicationKey":"sample-production"},"targets":{"staging":{"image":"image","ip":"target.example.invalid","nonProduction":{"coordinationScope":"sample-staging"}}}}|}

let production =
  configuration
    {|{"__schema":"v0.4","project":"sample","targets":{"staging":{"image":"image","ip":"target.example.invalid"}}}|}

let () =
  assert_ok
    (Nixploy.Direct_mode.validate_configuration unmanaged_non_production ~target);
  let managed =
    Nixploy.Direct_mode.validate_configuration control_plane ~target
    |> Result.error |> Option.value_exn |> Error.to_string_hum
  in
  assert (String.is_substring managed ~substring:"NIXPLOY_DIRECT_MANAGED_DECLARATION");
  let not_non_production =
    Nixploy.Direct_mode.validate_configuration production ~target
    |> Result.error |> Option.value_exn |> Error.to_string_hum
  in
  assert (
    String.is_substring not_non_production
      ~substring:"NIXPLOY_DIRECT_NON_PRODUCTION_REQUIRED")
