# nix-apple-container-builder

<p align="center">
  <img src="assets/logo.png" alt="nix-apple-container-builder logo" width="240" />
</p>

`nix-apple-container-builder` is a `nix-darwin` module that configures an
Apple Container based `aarch64-linux` remote builder for Nix.

Current design highlights:

- installs Apple `container` from the official signed GitHub release package
- configures `nix.buildMachines` for `ssh-ng://container-builder`
- manages a durable state directory under `~/.local/state/container-builder`
- installs launch agents for the container runtime and the SSH bridge
- configures container DNS explicitly for cache resolution
- waits for a real SSH handshake before considering the builder ready
- currently uses a `socat` bridge into `container exec`

## Module

The flake exports:

- `darwinModules.default`
- `darwinModules.container-builder`

## Example

```nix
{
  inputs.apple-container-builder.url = "github:RobertDeRose/nix-apple-container-builder";

  outputs = inputs: {
    darwinConfigurations.my-host = inputs.darwin.lib.darwinSystem {
      system = "aarch64-darwin";
      modules = [
        inputs.apple-container-builder.darwinModules.default
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

- live runtime verification on a real machine
- possible direct port publishing instead of `socat`
- on-demand lifecycle

## DNS

The module now exposes container DNS settings directly and defaults to public
recursive resolvers so the builder can resolve `cache.nixos.org`.

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
- the active container is stamped with its expected generation label and recreated if it drifts
- the builder container is started as ephemeral with `--rm`

What it cannot fully handle:

- Apple `container` itself is still an external mutable runtime
- launchd/XPC/vmnet state can become unhealthy independently of the Nix module
- first-run Apple runtime bootstrap may still require operational recovery
- the module can reconcile builder containers and launch-agent wiring, but it cannot guarantee the Apple runtime substrate is always healthy

In practice, this means the module is close to idempotent for the configuration it owns, but not perfectly idempotent for every possible runtime failure inside Apple `container`.

## Verification And Recovery

After activation, the main verification entrypoint is:

```bash
~/.local/state/container-builder/verify-builder.sh
```

Suggested validation after activation:

The generated helper checks:

- `container system status`
- SSH connectivity to `container-builder`
- Nix cache reachability inside the builder
- `ssh-ng://container-builder` reachability from the host daemon side

If the Apple container system is hung, the helper attempts recovery by:

1. unloading `~/Library/LaunchAgents/org.nixos.container-builder-runtime.plist`
2. running `container system start --enable-kernel-install`
3. reloading `~/Library/LaunchAgents/org.nixos.container-builder-runtime.plist`

The runtime launch agent also tries to avoid a hard crash loop. If it detects that Apple `container` is unhealthy, it attempts recovery once and exits cleanly instead of repeatedly hammering launchd.

What this recovery can do:

- restore Apple `container` after a hung apiserver/bootstrap state
- stop the module's own runtime launch agent from thrashing while recovery is attempted
- re-enable the runtime launch agent after successful recovery

What it cannot do:

- guarantee Apple `container` will always recover automatically
- fix every possible launchd/XPC/vmnet failure without user involvement
- replace upstream runtime debugging when Apple `container` itself is broken

See `apple-container_spec.md` and `docs/poc/README.md` for the detailed design
notes and migration history.
