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
  Nixploy.Configuration.of_json
    {|{"__schema":"v0.4","project":"sample","controlPlane":{"authorityAlias":"netcup","managedApplicationKey":"sample-production"},"targets":{"staging":{"image":"image","ip":"target.example.invalid","nonProduction":{"coordinationScope":"sample-staging"}}}}|}

let unmanaged_production =
  configuration
    {|{"__schema":"v0.4","project":"sample","targets":{"production":{"image":"image","ip":"target.example.invalid","production":{"coordinationScope":"sample-production"}}}}|}

let undeclared_profile =
  configuration
    {|{"__schema":"v0.4","project":"sample","targets":{"staging":{"image":"image","ip":"target.example.invalid"}}}|}

let () =
  assert_ok
    (Nixploy.Direct_mode.validate_configuration unmanaged_non_production ~target);
  let production_target =
    Nixploy.Target_name.of_string "production" |> assert_ok
  in
  assert_ok
    (Nixploy.Direct_mode.validate_configuration unmanaged_production
       ~target:production_target);
  let managed =
    Or_error.bind control_plane ~f:(fun configuration ->
        Nixploy.Direct_mode.validate_configuration configuration ~target)
    |> Result.error |> Option.value_exn |> Error.to_string_hum
  in
  assert (String.is_substring managed ~substring:"controlPlane");
  assert_ok
    (Nixploy.Direct_mode.validate_configuration undeclared_profile ~target)
