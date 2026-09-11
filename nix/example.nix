{
  image = "docker";
  ip = "203.0.113.10";
  user = "deploy";
  port = 22;
  run = {
    network = "host";
    environment.PORT = "{port}";
  };
  web = {
    domain = "app.example.com";
    healthPath = "/health";
    slots = {
      blue = 8080;
      green = 8081;
    };
  };
  runbook = {
    clock = {
      description = "Print the running application's UTC time";
      command = [
        "/bin/date"
        "-u"
      ];
    };
    console = {
      description = "Open a shell in the running application container";
      command = [ "/bin/sh" ];
      interactive = true;
    };
  };

  # Optional: reference a SOPS-encrypted dotenv file from your own repository.
  # secrets.app = ./secrets/production.env;
}
