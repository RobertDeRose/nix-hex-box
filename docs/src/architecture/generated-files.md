---
description: The scripts, SSH configuration, and keys HexBox keeps in ~/.local/state/hb, and which ones each switch rewrites.
---

# Files HexBox manages

HexBox keeps its files in `~/.local/state/hb`. Every switch rewrites the
scripts and SSH configuration there from your Nix configuration, so don't edit
them by hand; change your configuration instead.

## Keys

The first switch creates these, and later switches never overwrite them:

| File | What it is |
|---|---|
| `builder_ed25519`, `builder_ed25519.pub` | The key Nix logs in to the builder with |
| `ssh_host_ed25519_key`, `ssh_host_ed25519_key.pub` | The builder's own host key |
| `known_hosts` | Lets SSH check it's talking to your builder |

Deleting the keys locks your Mac out of the builder. If you need new keys,
delete them, switch again to create new ones, and then run `hb builder reset`,
so the machine is recreated with the new keys.

## Scripts

| File | What it does |
|---|---|
| `bootstrap-keys.sh` | Creates any missing keys above; each switch runs it |
| `start-container.sh` | Starts the builder, creating or updating it as needed |
| `stop-container.sh` | Stops the builder |
| `reset-container.sh` | Deletes the builder and creates a fresh one |
| `bootstrap-machine.sh` | Sets up a new machine (used by `start-container.sh`) |
| `proxy.sh` | The SSH `ProxyCommand` described in [How Nix reaches the builder](./networking.md) |
| `ssh-wrapper.sh` | Runs SSH with HexBox's configuration |
| `reconcile-host-container-internal.sh` | Creates or removes the `host.container.internal` name |

## Configuration and state

| File | What it is |
|---|---|
| `ssh_config`, `ssh_config_root` | SSH settings for the two builder host names |
| `machine-generation` | Which image the current machine was built from; a mismatch makes HexBox recreate it |
| `hexbox-readiness.log` | What `hb builder repair` and `hb builder reset` saw while waiting for SSH |
| `builder-image/Containerfile` | A copy of your Containerfile, if you set `imageContainerfile` |

## Elsewhere

- `/usr/local/bin/hb` is the `hb` helper.
- `/etc/ssh/ssh_config.d/201-container-builder.conf` makes `ssh nix-builder`
  work from any terminal, and lets the Nix daemon find the builder.
