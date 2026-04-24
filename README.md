# HexBox

<p align="center">
  <img src="assets/logo.png" alt="HexBox logo" width="240" />
</p>

`nix-hex-box` is a `nix-darwin` module that configures an Apple Container based
`aarch64-linux` remote builder for Nix.

Current design highlights:

- installs Apple `container` from the official signed GitHub release package
- configures `nix.buildMachines` for `ssh-ng://container-builder`
- uses a published GHCR builder image
- manages durable builder state under `~/.local/state/hb`
- installs launch agents for the container runtime and the optional host-side SSH bridge
- uses direct `ProxyCommand` via `~/.local/state/hb/proxy.sh` for user-side helper access, while the localhost bridge remains the compatible path for the root `nix-daemon`
- configures container DNS explicitly for cache resolution
- waits for a real SSH handshake before considering the builder ready
- wakes the builder on demand and relays SSH directly to the current container IP
- supports guest-side idle shutdown with in-container logging under `~/.local/state/hb/hexbox-idle.log`

## Module

The flake exports:

- `darwinModules.default`
- `darwinModules.container-builder`

The repo also contains a builder image definition under `images/builder` and a
GitHub Actions workflow that publishes it to GHCR.

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

By default the module uses the published builder image:

`ghcr.io/robertderose/nix-hex-box:builder-latest`

Available options:

- `services.container-builder.dns.servers`
- `services.container-builder.dns.search`
- `services.container-builder.dns.options`
- `services.container-builder.dns.domain`
- `services.container-builder.dns.disable`

The builder container also writes a minimal `nix.conf` with
`https://cache.nixos.org/` configured as a substituter.

Example:

```nix
services.container-builder = {
  enable = true;
  dns.servers = [ "1.1.1.1" "8.8.8.8" ];
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

The default builder image extends `docker.io/nixos/nix:latest` and preinstalls
`procps` for idle session detection.

The publish workflow pushes image tags to GHCR on changes under
`images/builder/**` or on manual dispatch.

Expected tags:

- `ghcr.io/robertderose/nix-hex-box:builder-latest`
- `ghcr.io/robertderose/nix-hex-box:builder-<git-sha>`

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
- `hb logs [runtime|readiness|bridge|bridge-out|boot|idle]`
- `hb gc`
- `hb reset`
- `hb restart`
- `hb ssh`
- `hb inspect`

The helper's user-side SSH path uses `ProxyCommand ${HOME}/.local/state/hb/proxy.sh`
to wake the builder and relay directly to the current container IP. The root
daemon path can still use the localhost bridge, which remains the supported path
for remote builds on the current host setup.

When idle shutdown is enabled, the watchdog runs inside the container and logs
its decisions to `~/.local/state/hb/hexbox-idle.log`. It resets its timer
whenever active SSH sessions exist and terminates `sshd` after the configured
idle timeout.

The helper checks:

- `container system status`
- current builder container inspect output
- SSH connectivity to `container-builder`
- Nix cache reachability inside the builder
- `ssh-ng://container-builder` reachability from the host daemon side

If the Apple container system is hung, the helper attempts recovery by:

1. unloading `~/Library/LaunchAgents/org.nixos.hexbox-runtime.plist`
2. running `container system start --enable-kernel-install`
3. reloading `~/Library/LaunchAgents/org.nixos.hexbox-runtime.plist`

The runtime launch agent also tries to avoid a hard crash loop. If it detects
that Apple `container` is unhealthy, it attempts recovery once and exits
cleanly instead of repeatedly hammering launchd.

See `docs/spec.md` for the detailed design notes.
