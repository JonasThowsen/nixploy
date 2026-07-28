# Tailscale identity authentication tracer

## Intended deployment

Nixploy is intended to be a private, self-hosted control plane exposed as a
Tailscale Service. The stable application identity is `svc:nixploy`; the
machine hosting it may change independently. Phoenix listens only on loopback
behind Tailscale Serve.

Packaged NixOS services default to `authMode = "tailscale"`. Password mode is
for local development and explicit recovery workflows, not the normal
production login boundary.

## Observable behavior

A provisioned operator opens the private Tailscale Service and reaches the
LiveView dashboard without entering a second password. The dashboard displays
the operator email supplied by Tailscale.

## Acceptance criterion

Given a database operator whose normalized email matches
`Tailscale-User-Login`:

1. `GET /` through Tailscale Serve returns the authenticated dashboard.
2. The operator identity is copied into the Phoenix session for LiveView.
3. A login audit event records `authentication=tailscale`.
4. A request without the trusted header, or for an unprovisioned identity,
   receives HTTP 403.
5. `POST /login` receives HTTP 403 in Tailscale mode.
6. `/health` and `/ready` remain independent of operator authentication.

## Trust boundary

Tailscale Serve strips client-supplied identity headers before adding its own
`Tailscale-User-Login`, `Tailscale-User-Name`, and profile headers. Nixploy only
uses the login header. This is safe only while the backend remains inaccessible
except through the trusted local proxy; the production NixOS service therefore
keeps Phoenix on loopback.

Tailnet policy remains the first authorization layer. Nixploy adds a second,
application-level check by requiring the Tailscale login to match a provisioned
operator. Tagged client devices do not receive user identity headers and are
therefore rejected from the dashboard.

## Deliberately deferred

- Group and role mapping beyond provisioned operator emails
- Identity-only operator records; the current bootstrap still stores an unused
  recovery password because the existing operator schema requires it
- A separately secured break-glass login endpoint
- Session revocation and multi-device session management
- Persisted display name and profile picture from optional Tailscale headers
