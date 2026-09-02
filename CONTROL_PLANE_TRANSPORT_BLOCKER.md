# Control-plane transport blocker

## Decision

Managed CLI reads and mutations remain fail-closed with
`NIXPLOY_PIN_UNSUPPORTED`. The packaged RPC WebSocket client does not expose the
TLS peer for the connection on which it sends the WebSocket upgrade and RPC
bytes. A separate probe, an OpenSSL subprocess, or ordinary system TLS cannot
prove the configured SPKI pin for that connection.

## Required upstream seams

A maintained implementation needs all of these public APIs:

1. **Async_ssl:** obtain the SHA-256 digest of the DER-encoded
   `SubjectPublicKeyInfo` for the peer certificate on the live TLS connection.
   The canonical result must be the base64 encoding of the 32 raw digest bytes,
   which is the value configured as `pinned_server_spki_sha256`.
2. **cohttp_async_websocket:** perform its existing client WebSocket upgrade and
   framing over caller-owned encrypted `Reader` and `Writer` values. It must not
   open a second connection or follow redirects, and its close ownership must be
   explicit.
3. **async_rpc_websocket:** create its RPC connection from that WebSocket
   transport. This must be an upstream-supported construction rather than a
   copy of the RPC protocol setup into nixploy.

The current `Rpc_websocket.Rpc.client` path owns TLS internally and returns only
an RPC transport, so it cannot meet this contract.

## Verification requirements

The control-plane client must establish one TLS connection to the exact
protected authority, retain normal certificate-chain and hostname verification,
and compare the configured SHA-256 SPKI pin before sending an HTTP upgrade or
RPC byte. A matching pin augments, not replaces, certificate and hostname
validation. Missing or malformed pins, absent peer certificates, validation
failures, pin mismatches, redirects, and authority changes are terminal errors.

## Rejected workarounds

- `openssl s_client` or another preflight connection;
- a separate TLS probe before `Rpc_websocket.Rpc.client`;
- system trust or Cohttp/Conduit TLS validation without exact-session SPKI
  comparison;
- redirect following; and
- a local WebSocket or RPC protocol implementation.

Each either verifies a different connection, weakens the protected authority
contract, or creates an unmaintained security protocol surface.

## Next action

Request and version-lock the three upstream APIs above. Once they are available,
compile a small CLI-bound transport adapter against the resolved Nix packages.
Its integration test must prove that a matching pin permits one TLS WebSocket
connection, while a mismatched pin sends no upgrade or RPC byte; it must also
prove that an invalid hostname or certificate chain fails even with a matching
pin. Until then, retain `NIXPLOY_PIN_UNSUPPORTED` for managed transport.
