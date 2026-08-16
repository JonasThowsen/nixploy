{ nixployLib }:

let
  baseTarget = {
    image = "docker";
    ip = "203.0.113.10";
  };

  evaluate =
    target:
    nixployLib.makeConfig {
      project = "test-app";
      targets.production = baseTarget // target;
    };

  defaultConfig = evaluate { };
  configured = evaluate {
    run.readOnlyBinds = [
      {
        source = "/srv/test-app/reference data";
        destination = "/app/reference data";
      }
      {
        source = "/srv/test-app/config";
        destination = "/app/config";
      }
    ];
  };
  legacyStyle = evaluate {
    user = "deploy";
    port = 2222;
    identityFile = "~/.ssh/id_nixploy";
    run = {
      command = [
        "/app/server"
        "--serve"
      ];
      environment = {
        EMPTY = "";
        PORT = "{port}";
      };
      preStart = [ [ "/app/migrate" ] ];
      network = "host";
      ports = [ "127.0.0.1:8080:8080" ];
      readOnlyBinds = [
        {
          source = "/srv/test-app/data";
          destination = "/app/data";
        }
      ];
    };
    web = {
      domain = "test-app.example.com";
      healthPath = "/ready";
      slots = {
        blue = 8080;
        green = 8081;
      };
    };
    secrets.app = ./config-test.nix;
  };

  rejects = target: !(builtins.tryEval (builtins.deepSeq (evaluate target) true)).success;
  rejectsBind = bind: rejects { run.readOnlyBinds = [ bind ]; };
  rejectsSource =
    source:
    rejectsBind {
      inherit source;
      destination = "/app/data";
    };
  rejectsDestination =
    destination:
    rejectsBind {
      source = "/srv/data";
      inherit destination;
    };

  delControl = builtins.fromJSON ''"\u007f"'';
  c1Control = builtins.fromJSON ''"\u0085"'';
in
assert nixployLib.schema == "v0.4";
assert defaultConfig.__schema == "v0.4";
assert defaultConfig.targets.production.run.readOnlyBinds == [ ];
assert !(builtins.hasAttr "tasks" defaultConfig.targets.production);
assert legacyStyle.targets.production.user == "deploy";
assert legacyStyle.targets.production.port == 2222;
assert legacyStyle.targets.production.identityFile == "~/.ssh/id_nixploy";
assert
  legacyStyle.targets.production.run.command == [
    "/app/server"
    "--serve"
  ];
assert
  legacyStyle.targets.production.run.environment == {
    EMPTY = "";
    PORT = "{port}";
  };
assert legacyStyle.targets.production.run.preStart == [ [ "/app/migrate" ] ];
assert legacyStyle.targets.production.run.network == "host";
assert legacyStyle.targets.production.run.ports == [ "127.0.0.1:8080:8080" ];
assert
  legacyStyle.targets.production.run.readOnlyBinds == [
    {
      source = "/srv/test-app/data";
      destination = "/app/data";
    }
  ];
assert legacyStyle.targets.production.web.domain == "test-app.example.com";
assert legacyStyle.targets.production.web.healthPath == "/ready";
assert
  legacyStyle.targets.production.web.slots == {
    blue = 8080;
    green = 8081;
  };
assert builtins.attrNames legacyStyle.targets.production.secrets == [ "app" ];
assert
  configured.targets.production.run.readOnlyBinds == [
    {
      source = "/srv/test-app/reference data";
      destination = "/app/reference data";
    }
    {
      source = "/srv/test-app/config";
      destination = "/app/config";
    }
  ];
assert rejectsSource "relative";
assert rejectsSource "/";
assert rejectsSource "/srv/data,ro=false";
assert rejectsSource "/srv/data\nother";
assert rejectsSource ("/srv/data" + delControl + "other");
assert rejectsSource ("/srv/data" + c1Control + "other");
assert rejectsSource "/srv//data";
assert rejectsSource "/srv/data/";
assert rejectsSource "/srv/./data";
assert rejectsSource "/srv/../data";
assert rejectsDestination "app/data";
assert rejectsDestination "/app/data,rw";
assert rejectsDestination "/app/../data";
assert rejectsBind {
  source = "/same";
  destination = "/same";
};
assert rejects {
  run.readOnlyBinds = [
    {
      source = "/srv/first";
      destination = "/app/data";
    }
    {
      source = "/srv/second";
      destination = "/app/data";
    }
  ];
};
assert rejectsBind {
  source = "/srv/data";
  destination = "/app/data";
  readOnly = false;
};
assert rejectsBind {
  source = "/srv/data";
  destination = "/app/data";
  options = [ "rw" ];
};
assert rejects {
  tasks.vacuum = {
    command = [ "/app/vacuum" ];
  };
};
true
