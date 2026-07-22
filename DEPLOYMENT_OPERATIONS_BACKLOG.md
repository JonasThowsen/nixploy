# TODO

## Deployment ergonomics

- Add `nixploy status -t <target>`
  - Show target identity, active blue/green slot, inactive slot, container names, image, Caddy route/upstream, health URL, and last deploy metadata.

- Add `nixploy logs -t <target>`
  - Default to the active slot for web deployments.
  - Support `--slot blue|green`, `--previous`, `--tail <n>`, and `--follow`.

- Add `nixploy exec -t <target> -- <command...>`
  - Default to the active slot for web deployments.
  - Support `--slot blue|green`.
  - Make common shell-less image workflows easy, e.g. `/app/bin/erp eval ...`.

- Add a Phoenix-specific remote helper or documented recipe.
  - Example: `nixploy exec -t production --remote-iex` or `nixploy phoenix remote -t production`.
  - Detect active slot port and inject the matching release env, e.g. `RELEASE_NODE=erp_4000` / `erp_4001`.
  - This avoids manual commands like:
    ```bash
    podman exec -it \
      -e RELEASE_DISTRIBUTION=sname \
      -e RELEASE_NODE=erp_4000 \
      <container> \
      /app/bin/erp remote
    ```

## Health check/debugging

- Improve health-check failure output.
  - Print container state and exit code.
  - Print recent container logs.
  - Print verbose health check output (`curl -v`).
  - Include the exact container name and slot that failed.

- Consider configurable health check host.
  - Current checks use `127.0.0.1`.
  - Allow overriding host/scheme if an app only binds IPv6 or a non-loopback interface.

## One-off tasks

- Add first-class task definitions in flake config.
  - Example:
    ```nix
    tasks.seed = [ "/app/bin/erp" "eval" "Erp.Release.seed" ];
    tasks.migrate = [ "/app/bin/erp-migrate" ];
    ```
  - CLI:
    ```bash
    nixploy task -t production seed
    ```

## Phoenix/Nix image documentation

- Document a recommended Phoenix deployment shape:
  - stable `/app/bin/*` paths in the image
  - `/health` endpoint
  - `PORT = "{port}"`
  - `PHX_HOST` from secrets/env matching the public domain
  - CA certificates in Nix-built images (`pkgs.cacert` and `/etc/ssl/certs` symlinks)
  - optional shell/debug tools for non-minimal production images
  - Erlang distribution notes for remote IEx in blue/green deployments
