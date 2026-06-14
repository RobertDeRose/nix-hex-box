# HexBox

<p align="center">
  <img src="assets/logo.png" alt="HexBox logo" width="240" />
</p>

`nix-hex-box` is a `nix-darwin` module that configures an Apple
`container machine` backed `aarch64-linux` remote builder for Nix.

Documentation site:

- <https://robertderose.github.io/nix-hex-box/>

Current design highlights:

- installs Apple `container` from the official signed GitHub release package
- pulls the published Alpine/Lix-based builder image by default, with an optional local custom image build
- creates a persistent Apple `container machine` instead of an ephemeral container
- configures `nix.buildMachines` for `ssh-ng://container-builder`
- uses `ProxyCommand` to auto-start the machine and relay SSH to guest `sshd`
- lets the macOS root `nix-daemon` sudo back to the runtime-owning user for the Apple container command
- connects as the guest `builder` user and uses a narrow passwordless sudo wrapper for the remote `nix-daemon`
- keeps the guest `/nix` store persistent across machine stops and starts
- powers the guest off after a configurable idle timeout with no active SSH connections
- manages durable host state under `~/.local/state/hb`
- can install and manage Socktainer as an optional Docker-compatible API layer
- installs host-side SSH aliases for both `nix-builder` and `container-builder`
- writes a generated `known_hosts` file under `~/.local/state/hb` so SSH verifies the builder host key
- exposes `host.container.internal` for Apple containers by default via `container system dns`
- waits for a real SSH handshake before considering the builder ready

## Module

The flake exports:

- `darwinModules.default`
- `darwinModules.container-builder`

The repo also contains a scheduled workflow that opens a Robborg-authored PR
for pinned runtime-version updates, validates it, and auto-merges it after the
lint workflow passes.

## Example

```nix
{
  inputs.hexbox.url = "github:RobertDeRose/nix-hex-box";

  outputs = inputs: {
    darwinConfigurations.my-host = inputs.darwin.lib.darwinSystem {
      system = "aarch64-darwin";
      modules = [
        inputs.hexbox.darwinModules.default
        {
          services.container-builder = {
            enable = true;
            cpus = 4;
            memory = "8G";
            maxJobs = 4;
            socktainer.enable = true;
            # Optional override if you do not want to use config.system.primaryUser.
            user = "myuser";
          };
        }
      ];
    };
  };
}
```

## Status

This module is functional but still in progress.

Known open areas:

- evaluating a smaller systemd-based image once Apple `container machine` handles
  larger systemd images reliably

## Runtime

The module uses the HexBox builder image published by this repository by default:

```text
ghcr.io/robertderose/nix-hex-box/hexbox-builder:latest
```

The image contains Alpine 3.22, OpenSSH, sudo, and Lix. The module creates a
persistent Apple container machine from that image and bootstraps the
host-specific SSH keys, `nix.conf`, sudoers rule, and idle timeout.

GitHub Actions rebuilds and publishes `latest` on the same weekly schedule as
the runtime-version updater so Alpine package updates, such as OpenSSH fixes,
flow into the default image. When the image definition changes on `main`, the
workflow also publishes the versioned release tag
`alpine-3.22-lix-2.95.2-1` for users who prefer to pin.

The builder uses `ssh-ng`. The host SSH path is a generated `ProxyCommand` that
runs Apple `container machine run -i ... nc 127.0.0.1 22`, so the machine starts
on demand and IP changes do not affect the Nix builder config.

The guest `/nix` store lives in the machine's persistent storage. Stop/start
keeps build outputs and downloaded substitutes. `hb builder reset` deletes and
recreates the machine, which also deletes the guest-local store.

Available image options:

- `services.container-builder.imageRepository`
- `services.container-builder.nixVersion`
- `services.container-builder.imageContainerfile`
- `services.container-builder.imageBuildContext`

Set `imageContainerfile` to build and use a local custom image instead of the
published GHCR image. Bump `nixVersion` or remove the local image when the
Containerfile changes.

Available machine options:

- `services.container-builder.cpus`
- `services.container-builder.memory`
- `services.container-builder.homeMount`
- `services.container-builder.idleShutdown.enable`
- `services.container-builder.idleShutdown.timeoutSeconds`

Available host/container integration options:

- `services.container-builder.exposeHostContainerInternal`
- `services.container-builder.socktainer.enable`
- `services.container-builder.socktainer.homeDirectory`
- `services.container-builder.socktainer.binary`
- `services.container-builder.socktainer.installer.url`
- `services.container-builder.socktainer.installer.hash`
- `services.container-builder.socktainer.installer.version`

The builder machine writes a minimal `nix.conf` with
`https://cache.nixos.org/` configured as a substituter.

Example:

```nix
services.container-builder = {
  enable = true;
};
```

## Socktainer

Set `services.container-builder.socktainer.enable = true;` to install the
official Socktainer pkg and manage a user launch agent for the current primary
user.

This exposes a Docker-compatible Unix socket at:

```text
$HOME/.socktainer/container.sock
```

Example:

```bash
export DOCKER_HOST=unix://$HOME/.socktainer/container.sock
docker ps
```

Set `services.container-builder.socktainer.setDockerHost = true;` if you want
the module to export that socket as `DOCKER_HOST` in the user environment.

## Helper

After activation, use:

```bash
hb builder status
hb builder repair
hb builder test
hb builder ssh
hb builder logs boot
hb builder logs idle
hb doctor
```

`hb builder repair` ensures the Apple container system is healthy, builds a
custom local OCI image when configured and missing, creates or updates the
container machine, verifies SSH, checks outbound connectivity, and pings the
remote store.

See `docs/spec.md` for the detailed design notes.
