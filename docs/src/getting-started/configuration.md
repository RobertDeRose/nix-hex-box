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
- `imageContainerfile`
- `imageBuildContext`
- `socktainer.enable`

The default image is pulled from this repository's GitHub Container Registry
package:

```text
ghcr.io/robertderose/nix-hex-box/hexbox-builder:latest
```

Scheduled builds refresh `latest` for Alpine package updates, such as OpenSSH
fixes. Builder image publishing is skipped until the configured Lix tag is at
least seven days old. Image-definition changes on `main` also publish the
versioned tag `alpine-3.22-lix-2.95.2-1` for users who prefer a pinned image.

The image contains Alpine 3.22, OpenSSH, sudo, and Lix. Set
`imageContainerfile` to build a local custom image instead. Set
`imageBuildContext` to an absolute host path string when the custom image needs
a build context. Custom images must provide an `nc` implementation with `-N`
support and a working `/sbin/init`, because HexBox uses them for the SSH proxy
and machine boot path. Runtime bootstrap writes a minimal `nix.conf` that uses
`https://cache.nixos.org/` by default.

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
