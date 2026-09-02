{ lib, targetModule }:

let
  schema = "v0.4";

  configModule =
    { ... }:
    {
      options = {
        project = lib.mkOption {
          type = lib.types.str;
          description = "Human-readable project name used in nixploy resource names.";
          example = "my-app";
        };

        controlPlane = lib.mkOption {
          default = null;
          description = "Managed control-plane identity; never a transport URI or credential.";
          type = lib.types.nullOr (lib.types.submodule {
            options = {
              authorityAlias = lib.mkOption {
                type = lib.types.str;
                description = "Alias resolved only from the protected operator authority record.";
              };
              managedApplicationKey = lib.mkOption {
                type = lib.types.str;
                description = "Managed application key authorized by the selected control plane.";
              };
            };
          });
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

  makeConfig =
    config:
    let
      evaluated = lib.evalModules {
        modules = [
          configModule
          config
        ];
      };
    in
    evaluated.config
    // {
      __schema = schema;
    };
}
