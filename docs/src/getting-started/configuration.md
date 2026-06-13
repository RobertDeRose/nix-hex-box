# Configuration

Minimal example:

```nix
services.container-builder = {
  enable = true;
  cpus = 4;
  memory = "8G";
  maxJobs = 4;
  # Optional Docker API compatibility layer:
  # socktainer.enable = true;
};
```

Common settings to review first:

- `hostAlias`
- `cpus`
- `memory`
- `homeMount`
- `maxJobs`
- `protocol`
- `idleShutdown.enable`
- `idleShutdown.timeoutSeconds`
- `imageRepository`
- `nixVersion`
- `socktainer.enable`

The default image is built locally from the generated Containerfile:

```text
local/hexbox-builder:alpine-3.22-lix-2.95.2-1
```

The image contains Alpine 3.22, OpenSSH, sudo, and Lix. Runtime
bootstrap writes a minimal `nix.conf` that uses `https://cache.nixos.org/` by
default.

Current default behavior to keep in mind:

- `protocol = "ssh-ng"`
- `hostAlias = "container-builder"`
- `containerName = "nix-builder"`
- `homeMount = "none"`
- `idleShutdown.enable = true`
- `idleShutdown.timeoutSeconds = 300`
- `exposeHostContainerInternal = true`
- `cli.completions.enable = false`

The builder machine does not mount the host home directory by default. Set
`homeMount = "ro"` or `homeMount = "rw"` only when the builder needs explicit
access to host files.

If you want shell completions for `hb`, enable:

```nix
services.container-builder.cli.completions.enable = true;
```

This installs bash, zsh, and fish completion files through standard Nix
completion directories. It does not detect your current shell or modify shell
startup files.
