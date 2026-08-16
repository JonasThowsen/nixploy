open Core
module Static_route = Nixploy_rpc_mapping.Static_route

let () =
  List.iter
    [
      "";
      "/";
      "/index.html";
      "/apps";
      "/apps/";
      "/apps/example";
      "/apps/example_2-prod/";
      "/telemetry";
      "/telemetry/";
    ] ~f:(fun path -> assert (Static_route.serves_spa_shell path));
  List.iter
    [
      "/main.js/missing";
      "/app.css/missing";
      "/arbitrary";
      "/apps/Upper";
      "/apps/-bad";
      "/apps/example/more";
      "/telemetry/more";
    ] ~f:(fun path -> assert (not (Static_route.serves_spa_shell path)))
