open Core

let assert_route path expected canonical_path =
  let parsed = Route.parse_path path in
  [%test_eq: Route.t] expected parsed.route;
  [%test_eq: string option] canonical_path parsed.canonical_path;
  match expected with
  | Route.Not_found _ -> ()
  | route ->
      [%test_eq: string]
        (Option.value canonical_path ~default:path)
        (Route.to_path route)

let () =
  assert_route "/" Route.Home None;
  assert_route "/index.html" Route.Home (Some "/");
  assert_route "/apps" Route.Apps None;
  assert_route "/apps/" Route.Apps (Some "/apps");
  assert_route "/telemetry///" Route.Telemetry (Some "/telemetry");
  let example =
    Route.Application_key.of_string "app_2-prod" |> Or_error.ok_exn
  in
  assert_route "/apps/app_2-prod" (Route.Application example) None;
  assert_route "/apps/app_2-prod/" (Route.Application example)
    (Some "/apps/app_2-prod");
  assert_route "/apps/Upper" (Route.Not_found "/apps/Upper") None;
  assert_route "/apps/-bad" (Route.Not_found "/apps/-bad") None;
  assert_route "/apps/extra/path" (Route.Not_found "/apps/extra/path") None;
  assert_route "/arbitrary" (Route.Not_found "/arbitrary") None;
  assert (Result.is_ok (Route.Application_key.of_string "a"));
  assert (Result.is_ok (Route.Application_key.of_string (String.make 63 'a')));
  assert (Result.is_error (Route.Application_key.of_string ""));
  assert (Result.is_error (Route.Application_key.of_string (String.make 64 'a')));
  assert (Result.is_error (Route.Application_key.of_string "a.b"))
