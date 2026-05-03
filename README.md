# HexBox

<p align="center">
  <img src="assets/logo.png" alt="HexBox logo" width="240" />
</p>

`nix-hex-box` is a `nix-darwin` module that configures an Apple Container based
`aarch64-linux` remote builder for Nix.

Documentation site:

- <https://robertderose.github.io/nix-hex-box/>

Current design highlights:

- installs Apple `container` from the official signed GitHub release package
- configures `nix.buildMachines` for `ssh-ng://container-builder`
- pulls a pinned upstream `nixos/nix` builder image
- manages durable builder state under `~/.local/state/hb`
- installs a launch agent for the optional host-side SSH bridge
- can install and manage Socktainer as an optional Docker-compatible API layer
- uses direct `ProxyCommand` via `~/.local/state/hb/proxy.sh` for user-side helper access, while the localhost bridge remains the compatible path for the root `nix-daemon`
- configures container DNS explicitly for cache resolution
- exposes `host.container.internal` for Apple containers by default via `container system dns`
- waits for a real SSH handshake before considering the builder ready
- wakes the builder on demand and relays SSH directly to the current container IP
- supports guest-side idle shutdown with in-container logging under `~/.local/state/hb/hexbox-idle.log`

## Module

The flake exports:

- `darwinModules.default`
- `darwinModules.container-builder`

The repo also contains a scheduled workflow that updates the pinned Apple
Container installer version and upstream `nixos/nix` image tag.

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

- possible direct port publishing instead of the host bridge for the root daemon path
- broader validation of when bridge-free operation is safe for daemon-driven builds

## DNS

The module exposes container DNS settings directly and defaults to public
recursive resolvers so the builder can resolve `cache.nixos.org`.

The builder keeps the container generation-aware. The image's built-in `/nix`
is used directly; build outputs live in the container's writable layer and are
re-fetched from substituters if the container is recreated.

By default the module uses the upstream builder image:

`docker.io/nixos/nix:2.34.6`

Available image version options:

- `services.container-builder.imageRepository`
- `services.container-builder.nixVersion`

Available options:

- `services.container-builder.dns.servers`
- `services.container-builder.dns.search`
- `services.container-builder.dns.options`
- `services.container-builder.dns.domain`
- `services.container-builder.dns.disable`
- `services.container-builder.exposeHostContainerInternal`
- `services.container-builder.socktainer.enable`
- `services.container-builder.socktainer.homeDirectory`
- `services.container-builder.socktainer.binary`
- `services.container-builder.socktainer.installer.url`
- `services.container-builder.socktainer.installer.hash`
- `services.container-builder.socktainer.installer.version`

The builder container also writes a minimal `nix.conf` with
`https://cache.nixos.org/` configured as a substituter.

Example:

```nix
services.container-builder = {
  enable = true;
  dns.servers = [ "1.1.1.1" "8.8.8.8" ];
};
```

By default the module also ensures Apple's documented host alias is available:

```text
host.container.internal
```

This is managed with `container system dns create host.container.internal --localhost 203.0.113.113`.
Set `services.container-builder.exposeHostContainerInternal = false;` to opt out.

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

The helper also exposes:

- `hb socktainer-status`
- `hb socktainer-logs [err|out]`

To export `DOCKER_HOST` automatically for user sessions, set:

```nix
services.container-builder.socktainer = {
  enable = true;
  setDockerHost = true;
};
```

## Idempotency

The module tries to be idempotent at the builder-configuration layer.

What it handles:

- the Apple `container` pkg is only installed when missing or on version change
- the durable state directory and helper scripts are reinstalled safely on each activation
- the builder container name is derived from a derivation-backed configuration spec
- when relevant builder settings change, the derived generation changes too
- stale older `nix-builder-*` generations are removed automatically
- the builder container is reused across restarts when possible; cached build outputs survive as long as the container exists
- the active container is stamped with its expected generation label and recreated if it drifts
- the builder container runs with Apple `container --init`

What it cannot fully handle:

- Apple `container` itself is still an external mutable runtime
- launchd/XPC/vmnet state can become unhealthy independently of the Nix module
- first-run Apple runtime bootstrap may still require operational recovery
- the module can reconcile builder containers and launch-agent wiring, but it cannot guarantee the Apple runtime substrate is always healthy

## Builder Image

The module now uses the upstream `nixos/nix` image directly. When idle
shutdown is enabled, `procps` is installed lazily in the background on first
boot so the watchdog can use `ps` without blocking container startup.

## Verification And Recovery

After activation, the main helper entrypoint is:

```bash
hb status
```

For full verification and recovery-aware checks, use:

```bash
hb repair
```

The helper supports:

- `hb status`
- `hb repair`
- `hb logs [readiness|bridge|bridge-out|boot|idle]`
- `hb gc`
- `hb reset`
- `hb restart`
- `hb ssh`
- `hb inspect`
- `hb host-check <port>`

The helper's user-side SSH path uses `ProxyCommand ${HOME}/.local/state/hb/proxy.sh`
to wake the builder and relay directly to the current container IP. The root
daemon path can still use the localhost bridge, which remains the supported path
for remote builds on the current host setup.

To verify that Apple’s `host.container.internal` forwarding can reach a host
service, run:

```bash
hb host-check 8000
```

This starts a short-lived test container and checks TCP connectivity to
`host.container.internal:<port>`. It tries the probe first without elevation,
then re-applies Apple's localhost forwarding with `sudo` only if the first
probe fails.

When idle shutdown is enabled, the watchdog runs inside the container and logs
its decisions to `~/.local/state/hb/hexbox-idle.log`. It resets its timer
whenever active SSH sessions exist and terminates `sshd` after the configured
idle timeout.

The helper checks:

- `container system status`
- current builder container inspect output
- SSH connectivity to `nix-builder`
- Nix cache reachability inside the builder
- `ssh-ng://container-builder` reachability from the host daemon side

If the Apple container system is hung, the on-demand start path and `hb repair`
attempt recovery by running `container system start --enable-kernel-install`
before retrying the builder container.

See `docs/spec.md` for the detailed design notes.
