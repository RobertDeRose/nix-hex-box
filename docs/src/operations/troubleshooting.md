# Troubleshooting

## Builder does not become SSH-ready

Start with:

```bash
hb builder repair
hb builder logs readiness
hb builder logs boot
```

Look for image build failures, container machine boot failures, guest bootstrap
failures, SSH startup problems, or `ProxyCommand` errors.

## Apple container runtime looks unhealthy

The Apple `container` runtime is still an external mutable subsystem. The module
can reconcile configuration and machines, but it cannot guarantee the runtime
substrate is always healthy.

`hb doctor runtime` checks the Apple container runtime and attempts recovery for
known failure boundaries. `hb builder repair` uses the same runtime recovery path
before retrying the builder. `hb doctor dns` also restarts the Apple container
runtime and retries once if external reachability probes fail.

## Cache resolution fails inside the guest

The guest writes a minimal `nix.conf` and depends on working DNS and network
reachability to `cache.nixos.org`. If substitute downloads fail, check:

- guest DNS settings
- upstream cache availability
- host networking state

## The machine changed IP address

This is expected after stop/start. The Nix builder path does not use the machine
IP directly; it connects through the generated SSH `ProxyCommand`, which runs
`container machine run` and relays to guest `sshd` inside the machine.

## Previous build outputs disappeared

The guest `/nix` store persists across normal machine stop/start cycles. If
outputs disappeared, the machine was probably removed and recreated. `hb builder
reset` is destructive for guest-local store contents.
