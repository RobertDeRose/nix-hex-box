# Options

The main option namespace is `services.container-builder`.

Important options:

- `enable`
- `hostAlias`
- `sshUser`
- `containerPort`
- `workingDirectory`
- `user`
- `containerBinary`
- `installer.url`
- `installer.hash`
- `installer.version`
- `containerName`
- `imageRepository`
- `nixVersion`
- `imageContainerfile`
- `imageBuildContext`
- `cpus`
- `memory`
- `homeMount`
- `exposeHostContainerInternal`
- `systems`
- `supportedFeatures`
- `mandatoryFeatures`
- `maxJobs`
- `speedFactor`
- `protocol`
- `readiness.timeoutSeconds`
- `readiness.intervalSeconds`
- `idleShutdown.enable`
- `idleShutdown.timeoutSeconds`
- `cli.completions.enable`
- `socktainer.enable`
- `socktainer.binary`
- `socktainer.homeDirectory`
- `socktainer.setDockerHost`
- `socktainer.installer.url`
- `socktainer.installer.hash`
- `socktainer.installer.version`

Machine notes:

- `containerName` is the Apple container machine name.
- `imageRepository` and `nixVersion` combine into the image reference used by
  `container machine create`.
- The default image is published by this repository as
  `ghcr.io/robertderose/nix-hex-box/hexbox-builder:alpine-3.22-lix-2.95.2-1`.
- Set `imageContainerfile` to build a local custom image instead of pulling the
  default image. `imageBuildContext` supplies an optional build context; without
  it, HexBox builds with an empty generated context.
- `homeMount` defaults to `none` so the builder does not mount the host home
  directory.
- `idleShutdown.timeoutSeconds` controls the guest watchdog that powers the
  machine off after no active SSH connections remain.

Host integration notes:

- `exposeHostContainerInternal` defaults to `true` and ensures
  `host.container.internal` exists through `container system dns`.
- The Nix builder path uses `ssh-ng` through generated SSH config and
  `ProxyCommand`; no stable machine IP or published host port is required.

Completion notes:

- `cli.completions.enable` defaults to `false`.
- When enabled, the module installs bash, zsh, and fish completion files into
  the standard Nix-managed completion directories.
- The module does not try to detect the user's shell or edit shell startup
  files.

See `modules/container-builder.nix` for the authoritative option defaults and
types.
