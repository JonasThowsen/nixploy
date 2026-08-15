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
  rejectsSource =
    source:
    rejects {
      run.readOnlyBinds = [
        {
          inherit source;
          destination = "/app/data";
        }
      ];
    };

  delControl = builtins.fromJSON ''"\u007f"'';
  c1Control = builtins.fromJSON ''"\u0085"'';
in
assert nixployLib.schema == "v0.3";
assert defaultConfig.__schema == "v0.3";
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
assert rejects {
  run.readOnlyBinds = [
    {
      source = "/same";
      destination = "/same";
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
