# Overview

`nix-hex-box` exports two identical module entry points:

- `darwinModules.default`
- `darwinModules.container-builder`

The main option namespace is `services.container-builder`.

When enabled, the module:

- installs the Apple Container runtime package when needed
- writes helper scripts and SSH configuration under `~/.local/state/hb`
- configures host-side SSH aliases for `container-builder`
- configures `nix.buildMachines` so the host daemon can use the builder for Linux derivations
- optionally loads a launch agent that exposes the localhost bridge used by the root daemon path

The helper entrypoint is `hb`, which provides status, repair, logs, and
inspection commands for the builder runtime.
