{ lib, targetModule }:

let
  schema = "v0.3";

  configModule =
    { ... }:
    {
      options = {
        project = lib.mkOption {
          type = lib.types.str;
          description = "Human-readable project name used in nixploy resource names.";
          example = "my-app";
        };

        targets = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule targetModule);
          default = { };
          description = "Deployment targets managed by nixploy.";
        };
      };
    };
in
{
  inherit schema;

  makeConfig = config:
    let
      evaluated = lib.evalModules {
        modules = [ configModule config ];
      };
    in
    evaluated.config
    // {
      __schema = schema;
    };
}
