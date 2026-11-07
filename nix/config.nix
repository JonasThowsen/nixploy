{ lib, targetModule }:

let
  schema = "v0.5";

  configModule =
    { ... }:
    {
      options = {
        project = lib.mkOption {
          type = lib.types.str;
          description = "Human-readable project name used in nixploy resource names.";
          example = "my-app";
        };

        repositoryIdentity = lib.mkOption {
          type = lib.types.nullOr (lib.types.strMatching "[^\n]+");
          default = null;
          description = ''
            The repository identity in resource keys and ownership labels,
            instead of the checkout's Git origin. A project that moves to
            another repository sets its old origin here, so its running
            workloads, secrets and routes stay its own.
          '';
          example = "git@github.com:example/my-app.git";
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
    # An undeclared identity is left out, so the configuration of a project
    # that does not declare one is exactly as before.
    lib.filterAttrs (name: value: !(name == "repositoryIdentity" && value == null)) evaluated.config
    // {
      __schema = schema;
    };
}
