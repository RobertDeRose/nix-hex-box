# Apple Container Builder Spec

## Current State

- `services.container-builder` is a working `nix-darwin` module for an Apple Container based `aarch64-linux` Nix builder.
- It declares:
  - `nix.buildMachines`
  - SSH config for `container-builder`
  - helper scripts in `/Users/<username>/.local/state/nac`
  - a runtime user agent and optional bridge user agent
  - readiness checks before considering startup successful
  - idempotent builder start and generation-aware container recreation
  - a persistent `/nix` overlay volume for the guest store
  - guest-side idle shutdown based on active SSH sessions
- The default image is `ghcr.io/robertderose/nix-apple-container-builder:builder-latest`.
- The user-side SSH path wakes the builder on demand with `ProxyCommand ~/.local/state/nac/proxy.sh`.
- The root `nix-daemon` path still uses the localhost bridge as the compatible transport for daemon-driven builds.

## Runtime Model

- Durable state lives under `/Users/<username>/.local/state/nac`.
- The builder container is generation-stamped and reused across restarts when possible.
- `/nix` inside the guest is an overlay mount:
  - lower layer from the image
  - upper layer in the persistent Apple volume `nix-builder-store`
- The watchdog runs inside the guest, checks `ps -ef | grep 'sshd-sessio[n]'`, and stops `sshd` after the configured idle timeout.
- Once idle shutdown fires, the builder remains offline until the proxy path or helper starts it again.

## Operational Notes

- Main helper entrypoint: `nac`
- Important generated files live in `~/.local/state/nac/`, including:
  - `init.sh`
  - `proxy.sh`
  - `start-container.sh`
  - `stop-container.sh`
  - `ssh_config`
  - `ssh_config_root`
  - `container-runtime.log`
  - `container-readiness.log`
  - `container-builder-idle.log`
  - `init-debug.log`
- Typical health checks:
  - `nac status`
  - `nac repair`
  - `ssh container-builder true`
  - `nix store ping --store ssh-ng://container-builder`

## Known Constraints

- Apple `container` is still an external mutable runtime and can require operational recovery.
- The root daemon path still depends on the localhost bridge rather than direct published ports.
- Updating the builder image can require resetting the persistent overlay volume if the lower `/nix` changes incompatibly.
- macOS virtualization only offers partial memory ballooning, so reclaimed guest memory is returned reliably when the builder stops rather than continuously while it stays running.
