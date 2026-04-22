# Apple Container Linux Builder for Nix — PoC

## Status: Working PoC, partially migrated into nix-darwin module

An `aarch64-linux` nix remote builder running in an Apple Container on
macOS, using the `nixos/nix` OCI image. The nix daemon (root) delegates
builds to the container via `ssh-ng://`.

This directory preserves the original PoC setup and investigation notes. The
repo now also contains a first-pass declarative module at
`modules/container-builder.nix`.

**Current transport**: socat TCP bridge (workaround for XPC + port publishing issues)
**Target transport**: direct port publishing (`-p 127.0.0.1:2222:22`) — pending container system fix

## Architecture

### Current (working, with socat bridge)

```
nix-daemon (root)
  → SSH to "container-builder" host alias
    → localhost:2222
      → socat (user-space, runs as login user)
        → container exec -i nix-builder
          → bash /dev/tcp/127.0.0.1/22 → sshd
            → nix-daemon (container) → builds aarch64-linux
```

### Notes

- The declarative module should be preferred for normal use.
- The manual PoC remains useful for isolated debugging and background context.
- The original PoC used `/tmp/container-builder`.
- The declarative module now uses `/Users/<username>/.local/state/container-builder`.

## Remaining PoC Questions

- Can direct port publishing replace the `socat` bridge?
- Can DNS/substituters work reliably inside the container?
- Can the builder support on-demand lifecycle cleanly?

See `../../apple-container_spec.md` for the current plan.
