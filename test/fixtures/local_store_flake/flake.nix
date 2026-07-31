{
  description = "No-secret nixploy local-store tracer fixture";

  outputs = { self }:
    {
      nixploy = {
        __schema = "v0.2";
        project = "local-store-tracer";
        targets.production = {
          image = "fixtureImage";
          ip = "127.0.0.1";
          user = "nixploy";
          port = 22;
          identityFile = null;
          run = {
            command = null;
            environment = { };
            preStart = [ ];
            network = "host";
            ports = [ ];
          };
          secrets = { };
          web = {
            domain = "fixture.nixploy.test";
            healthPath = "/health";
            slots = {
              blue = 18080;
              green = 18081;
            };
          };
        };
      };
    };
}
