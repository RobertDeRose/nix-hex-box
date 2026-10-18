# Socktainer

`nix-hex-box` can optionally manage
[Socktainer](https://github.com/socktainer/socktainer), which exposes a
Docker-compatible local API socket on top of Apple `container`.

Enable it with:

```nix
services.container-builder.socktainer = {
  enable = true;
};
```

Install Socktainer yourself first. The module creates a user launch agent and
starts the daemon in the current primary user's session. The agent resolves
`socktainer` through PATH and falls back to `/opt/homebrew/bin`,
`/usr/local/bin`, and `/opt/socktainer/bin`; set `socktainer.binary` to use an
explicit path. Activation prints an error if Socktainer cannot be found.

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
The module still manages the builder machine directly through Apple
`container machine`.
