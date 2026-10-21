---
description: Every HexBox option under services.container-builder, with its default and what it does.
---

# Options

All options live under `services.container-builder`. For the settings most
people change, and why, see [Configuration](../getting-started/configuration.md).

## The basics

| Option | Default | What it does |
|---|---|---|
| `enable` | `false` | Turns the builder on. |
| `user` | your `nix-darwin` primary user | The macOS user who owns the `container` runtime and the builder. |
| `containerBinary` | `"container"` | The `container` command to run. A bare name is looked up on your `PATH`, then in `/opt/homebrew/bin`, `/usr/local/bin`, and your mise shims; a full path is used as-is. |
| `cli.completions.enable` | `false` | Installs bash, zsh, and fish completions for `hb`. |

## The machine

| Option | Default | What it does |
|---|---|---|
| `cpus` | `4` | CPUs for the builder machine. |
| `memory` | `"1G"` | Memory for the builder machine, for example `"8G"`. |
| `homeMount` | `"none"` | Whether the builder can see your home folder: `"none"`, `"ro"` (read-only), or `"rw"`. |
| `containerName` | `"nix-builder"` | The machine's name in Apple `container`. |
| `idleShutdown.enable` | `true` | Shuts the builder down when no one is connected. |
| `idleShutdown.timeoutSeconds` | `300` | How long the builder waits, with no connections, before shutting down. |

## The image

| Option | Default | What it does |
|---|---|---|
| `imageRepository` | `"ghcr.io/robertderose/nix-hex-box/hexbox-builder"` | Where the builder image comes from. |
| `nixVersion` | `"latest"` | The image tag. Despite the name, it's the tag of the builder image, not a Nix version. Change it to pin an image, or to rebuild a custom one. |
| `imageContainerfile` | `null` | A Containerfile to build your own image from. The image must include `socat`, `base64`, `getent`, and a working `/sbin/init`. |
| `imageBuildContext` | `null` | An absolute path to a folder your Containerfile can copy files from. Without it, the build has an empty context. |

Changing any of these replaces the builder machine, which empties its `/nix`
store.

## How Nix uses the builder

These end up in `nix.buildMachines`.

| Option | Default | What it does |
|---|---|---|
| `maxJobs` | `4` | How many builds Nix runs on the builder at once. On M1 and M2 Macs, use 1 or 2. |
| `speedFactor` | `1` | How strongly Nix prefers this builder over others you have. |
| `systems` | `[ "aarch64-linux" ]` | What the builder can build. |
| `supportedFeatures` | `[ "benchmark" "big-parallel" "kvm" "nixos-test" ]` | Build features the builder offers. |
| `mandatoryFeatures` | `[ ]` | Features a build must ask for to be sent to this builder. |
| `protocol` | `"ssh-ng"` | The remote store protocol Nix uses. |

## SSH and networking

| Option | Default | What it does |
|---|---|---|
| `hostAlias` | `"container-builder"` | The SSH host name Nix uses for the builder. |
| `sshUser` | `"builder"` | The user Nix logs in as inside the builder. |
| `containerPort` | `22` | The SSH port inside the builder. |
| `exposeHostContainerInternal` | `true` | Lets Apple containers reach your Mac at `host.container.internal`. |
| `readiness.timeoutSeconds` | `60` | How long each SSH readiness check waits for a login to succeed. `hb builder reset` runs one check; `hb builder repair` retries up to three times. |
| `readiness.intervalSeconds` | `1` | How often they try. |

## Files

| Option | Default | What it does |
|---|---|---|
| `workingDirectory` | `"~/.local/state/hb"` | Where HexBox keeps its keys, scripts, and logs. See [Files HexBox manages](../architecture/generated-files.md). |

## Removed options

The `installer.*` and `socktainer.*` options were removed when HexBox stopped
installing Apple `container` and managing Socktainer. Setting any of them stops
your configuration from building, with a message saying what to do instead.
