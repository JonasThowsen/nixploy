{
  image = "docker";
  ip = "203.0.113.10";
  user = "root";
  port = 22;
  # Values are decrypted locally from these files and copied into the remote
  # Podman secret store. Do not put plaintext secret values in Nix.
  #
  # Each top-level key in each file becomes available in the pod as a secret.
  secrets = {
    app = ./secrets/prod.yaml;
  };
}
