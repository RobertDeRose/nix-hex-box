# HexBox Specification

## Scope

`nix-hex-box` provides a `nix-darwin` module that turns Apple `container` into a
local `aarch64-linux` remote builder for Nix.

The module declares and manages:

- `nix.buildMachines`
- SSH config for `nix-builder` and `container-builder`
- helper scripts in `/Users/<username>/.local/state/hb`
- an optional custom builder-image Containerfile
- a persistent Apple `container machine`
- readiness checks before considering startup successful
- guest-side idle shutdown based on active SSH connections

The default image is pulled from this repository's GitHub Container Registry
package as
`ghcr.io/robertderose/nix-hex-box/hexbox-builder:latest`.

Scheduled builds refresh `latest` for Alpine package updates. Image-definition
changes on `main` also publish the versioned tag
`alpine-3.22-lix-2.95.2-2`.

Users can set `services.container-builder.imageContainerfile` to build a local
custom image instead.

## Runtime Model

- Durable host state lives under `/Users/<username>/.local/state/hb`.
- The builder is a persistent Apple `container machine` named by
  `services.container-builder.containerName`.
- Machine creation uses Apple's normal boot path for first-time user setup;
  startup then proves liveness with a bounded `container machine run ... true`
  probe and retries stale machine state after stopping it.
- The guest `/nix` store lives in the machine's persistent storage and survives
  stop/start cycles.
- `hb builder reset` removes and recreates the machine, which deletes guest-local
  store contents.
- SSH access uses `ProxyCommand ~/.local/state/hb/proxy.sh`.
- The proxy uses `container machine run --root -i ... socat STDIO TCP:127.0.0.1:<containerPort>`,
  so it starts the machine on demand, closes cleanly when SSH finishes, and does
  not depend on a stable machine IP.
- When invoked by macOS root, the proxy sudoes back to the runtime-owning user
  before running Apple `container`.
- The guest SSH user is `builder`.
- The remote `nix-daemon` is reached through a narrow passwordless sudo wrapper
  inside the guest.
- Boot-time guest preparation provisions the standard `nixbld` build users and
  makes `/dev/net/tun` available to Lix sandbox networking.
- When idle shutdown is enabled, a guest watchdog watches active SSH
  connections and stops `sshd` after the configured timeout, which powers the machine off.

## Helper Commands

The `hb` helper exposes:

- `hb builder status`
- `hb builder repair`
- `hb builder test`
- `hb builder reset`
- `hb builder ssh`
- `hb builder inspect`
- `hb builder logs readiness`
- `hb builder logs boot`
- `hb builder logs idle`
- `hb doctor`
- `hb doctor runtime`
- `hb doctor dns`
- `hb doctor host [PORT]`

## Known Constraints

- Apple `container` is still an external mutable runtime and can require
  operational recovery.
- The default builder image depends on GHCR availability. Custom local image
  builds depend on the configured Containerfile inputs.
- Removing the builder machine removes guest-local build outputs.
- macOS virtualization only offers partial memory ballooning, so reclaimed guest
  memory is returned reliably when the builder powers off rather than
  continuously while it stays running.
