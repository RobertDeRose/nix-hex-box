# Configuration

Minimal example:

```nix
services.container-builder = {
  enable = true;
  cpus = 4;
  memory = "8G";
  maxJobs = 4;
  bridge.enable = true;
};
```

Common settings to review first:

- `cpus`
- `memory`
- `maxJobs`
- `bridge.enable`
- `idleShutdown.enable`
- `idleShutdown.timeoutSeconds`
- `dns.*`
- `imageRepository`
- `nixVersion`

The default image is the upstream pinned image:

```text
docker.io/nixos/nix:2.34.6
```

The container guest writes a minimal `nix.conf` that uses
`https://cache.nixos.org/` by default.
