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
true
