set shell := ["bash", "-uc"]

# List available recipes.
_default:
  @just --list

# Run the Phoenix server with the development environment from SOPS.
dev:
  set -a; \
  source <(sops -d secrets/dev.env); \
  set +a; \
  mix phx.server

# Run the Phoenix server inside IEx with the development environment from SOPS.
dev-iex:
  set -a; \
  source <(sops -d secrets/dev.env); \
  set +a; \
  iex -S mix phx.server
