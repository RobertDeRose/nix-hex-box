# Runtime Model

Durable state lives under:

```text
~/.local/state/hb
```

The current runtime model is:

- the builder container is generation-aware
- helper scripts are rewritten declaratively on activation
- the user-side SSH path wakes the builder on demand with `ProxyCommand`
- the root `nix-daemon` path can use the localhost bridge when enabled
- idle shutdown runs inside the guest and stops `sshd` after inactivity

The builder uses the image's built-in `/nix` directly. Build outputs live in
the container's writable layer, so recreating the container loses any guest
local store writes that were not already available from substituters.

That design keeps the module simpler than the older overlay-based approach, but
it also means the builder should be treated as a cache-backed disposable guest,
not as a durable Linux machine image.
