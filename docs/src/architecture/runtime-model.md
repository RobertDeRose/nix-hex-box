# Runtime Model

Durable host state lives under:

```text
~/.local/state/hb
```

The current runtime model is:

- the builder is an Apple `container machine`, not an ordinary ephemeral container
- activation rewrites helper scripts and SSH config
- by default, the machine is created from the published HexBox GHCR image
- machine creation uses Apple Container's normal boot path for first-time user
  setup, then proves liveness with a bounded `machine run ... true` probe
- failed run probes are treated as stale machine state and retried after stopping
  the machine rather than trusting `machine inspect` alone
- custom `imageContainerfile` configurations build a local OCI image when the tag is missing
- the SSH path uses `ProxyCommand` to auto-start the machine on demand
- the same SSH path is usable by the root `nix-daemon`; it sudoes back to the runtime-owning macOS user before invoking Apple `container`
- the guest SSH user is `builder`
- the remote `nix-daemon` runs through a narrow passwordless sudo wrapper inside the guest
- boot-time preparation provisions the `nixbld` build users and makes `/dev/net/tun` available to sandboxed builds
- idle shutdown runs inside the guest and powers off the machine after the configured inactivity timeout
- Socktainer, when enabled, runs as a separate user launch agent and exposes a Docker-compatible Unix socket under `$HOME/.socktainer`

The builder machine owns a persistent guest `/nix` store. Build outputs and
substitutes survive machine stop/start cycles. They are deleted when the machine
is removed, including explicit `hb builder reset` and automatic recreation after
an image-contract generation change.

Socktainer is not part of the builder control path. It is an optional companion
daemon for Docker-compatible local tooling on top of the same Apple container
runtime.
