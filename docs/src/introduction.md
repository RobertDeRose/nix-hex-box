# Introduction

<p align="center">
  <img src="hexbox-logo.png" alt="HexBox logo" width="240" />
</p>

`nix-hex-box` is a `nix-darwin` module that configures an Apple
`container machine` backed `aarch64-linux` remote builder for Nix.

The module is designed for Darwin hosts that want to offload Linux derivations
to a local virtualized builder while keeping the host configuration declarative.

Current design highlights:

- installs Apple `container` from the official signed release package
- builds a local Alpine/Lix based OCI image for the builder machine
- can optionally install Socktainer to expose a Docker-compatible local API socket
- configures `nix.buildMachines` for `ssh-ng://container-builder`
- manages durable state under `~/.local/state/hb`
- wakes the builder machine on demand through SSH `ProxyCommand`
- keeps guest `/nix` persistent across machine stop/start cycles
- supports guest-side idle shutdown and recovery-oriented health checks

This book documents the module itself. If you use `nix-hex-box` from another
repo, that repo should only need a high-level integration guide.
