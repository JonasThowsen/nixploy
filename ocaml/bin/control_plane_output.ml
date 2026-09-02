open Core

let capabilities value =
  String.concat
    [
      "Control plane: "
      ^ value.Protocol.Control_plane_capabilities.control_plane_id;
      "Package revision: " ^ value.package_revision;
      sprintf "Protocol: %d.%d" value.protocol_major value.protocol_minor;
      "Configuration schemas: "
      ^ String.concat ~sep:", " value.deployment_config_schemas;
      "Capabilities: " ^ String.concat ~sep:", " value.capabilities;
      "";
    ]
    ~sep:"\n"
