# Overview

`nix-hex-box` exports two identical module entry points:

- `darwinModules.default`
- `darwinModules.container-builder`

The main option namespace is `services.container-builder`.

When enabled, the module:

- installs the Apple Container runtime package when needed
- pulls the published Alpine/Lix-based builder image by default, with an optional local custom image build
- creates a persistent Apple `container machine` for Linux builds
- can optionally install Socktainer to expose a Docker-compatible local socket
- writes helper scripts and SSH configuration under `~/.local/state/hb`
- configures host-side SSH aliases for `nix-builder` and `container-builder`, backed by a generated `known_hosts` file for builder host-key verification
- configures `nix.buildMachines` so the host daemon can use the builder for Linux derivations
- uses SSH `ProxyCommand` to auto-start the machine and avoid depending on a stable machine IP

The helper entrypoint is `hb`, which provides status, repair, logs, and
inspection commands for the builder runtime.

If you enable Socktainer, the same helper also exposes Socktainer-specific
status and log commands. See [Socktainer](./socktainer.md).
