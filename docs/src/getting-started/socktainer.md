# Socktainer

`nix-hex-box` can optionally install and manage
[Socktainer](https://github.com/socktainer/socktainer), which exposes a
Docker-compatible local API socket on top of Apple `container`.

Enable it with:

```nix
services.container-builder.socktainer = {
  enable = true;
};
```

The module installs the official Socktainer pkg, creates a user launch agent,
and starts the daemon in the current primary user's session.

Socktainer stores its socket and logs under:

```text
$HOME/.socktainer
```

The Docker-compatible socket path is:

```text
$HOME/.socktainer/container.sock
```

To point Docker-compatible clients at that socket manually:

```bash
export DOCKER_HOST=unix://$HOME/.socktainer/container.sock
docker ps
```

To export `DOCKER_HOST` automatically for user sessions:

```nix
services.container-builder.socktainer = {
  enable = true;
  setDockerHost = true;
};
```

This integration is optional and independent from the Nix remote builder path.
The module still manages the builder container directly through Apple
`container`.
