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
        source = "/srv/test-app/data";
        destination = "/app/data";
      }
      {
        source = "/srv/test-app/config";
        destination = "/app/config";
      }
    ];
  };

  rejects = target: !(builtins.tryEval (builtins.deepSeq (evaluate target) true)).success;
in
assert defaultConfig.targets.production.run.readOnlyBinds == [ ];
assert
  configured.targets.production.run.readOnlyBinds == [
    {
      source = "/srv/test-app/data";
      destination = "/app/data";
    }
    {
      source = "/srv/test-app/config";
      destination = "/app/config";
    }
  ];
assert rejects {
  run.readOnlyBinds = [
    {
      source = "relative";
      destination = "/app/data";
    }
  ];
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
true
