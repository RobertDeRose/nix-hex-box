# Verification And Recovery

Main helper entrypoint:

```bash
hb status
```

Recovery-aware verification path:

```bash
hb repair
```

Useful checks after activation:

```bash
hb status
hb repair
ssh nix-builder true
nix store ping --store ssh-ng://container-builder
nix build --max-jobs 0 --rebuild nixpkgs#legacyPackages.aarch64-linux.hello
```

`hb repair` attempts to recover the Apple container system before retrying the
builder startup path. It also verifies:

- container system health
- bridge agent presence
- current builder container status
- SSH handshake success
- cache reachability inside the guest
- remote store reachability from the host side

Other useful helper commands:

- `hb reset`
- `hb restart`
- `hb ssh`
- `hb inspect`
- `hb gc`

If Socktainer is enabled, useful checks include:

```bash
hb socktainer-status
hb socktainer-logs err
DOCKER_HOST=unix://$HOME/.socktainer/container.sock docker ps
```
