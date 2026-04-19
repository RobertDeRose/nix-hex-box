# nix-apple-container-builder

`nix-apple-container-builder` is a `nix-darwin` module that configures an
Apple Container based `aarch64-linux` remote builder for Nix.

Current design highlights:

- installs Apple `container` from the official signed GitHub release package
- configures `nix.buildMachines` for `ssh-ng://container-builder`
- manages a durable state directory under `~/.local/state/container-builder`
- installs launch agents for the container runtime and the SSH bridge
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
- DNS/substituter behavior inside the container
- possible direct port publishing instead of `socat`
- on-demand lifecycle

See `apple-container_spec.md` and `docs/poc/README.md` for the detailed design
notes and migration history.
