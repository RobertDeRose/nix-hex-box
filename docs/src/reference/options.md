# Options

The main option namespace is `services.container-builder`.

Important options:

- `enable`
- `hostAlias`
- `sshUser`
- `listenAddress`
- `port`
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
- `cpus`
- `memory`
- `dns.servers`
- `dns.search`
- `dns.options`
- `dns.domain`
- `dns.disable`
- `exposeHostContainerInternal`
- `systems`
- `supportedFeatures`
- `mandatoryFeatures`
- `maxJobs`
- `speedFactor`
- `protocol`
- `autoStart`
- `readiness.timeoutSeconds`
- `readiness.intervalSeconds`
- `idleShutdown.enable`
- `idleShutdown.timeoutSeconds`
- `bridge.enable`
- `socktainer.enable`
- `socktainer.binary`
- `socktainer.homeDirectory`
- `socktainer.setDockerHost`
- `socktainer.installer.url`
- `socktainer.installer.hash`
- `socktainer.installer.version`

See `modules/container-builder.nix` for the authoritative option defaults and
types.
