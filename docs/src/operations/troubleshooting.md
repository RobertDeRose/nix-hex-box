# Troubleshooting

## Builder does not become SSH-ready

Start with:

```bash
hb repair
hb logs readiness
hb logs boot
```

Look for guest init failures, SSH startup problems, or bridge/proxy timeouts.

## Apple container runtime looks unhealthy

The Apple `container` runtime is still an external mutable subsystem. The
module can reconcile configuration and containers, but it cannot guarantee the
runtime substrate is always healthy.

`hb repair` attempts a recovery by starting the container system with kernel
install enabled before retrying the builder.

## Cache resolution fails inside the guest

The guest writes a minimal `nix.conf` and depends on working DNS and network
reachability to `cache.nixos.org`. If substitute downloads fail, check:

- guest DNS settings
- upstream cache availability
- host networking state

## Container recreation lost previous build outputs

This is expected in the current runtime model. The guest store is not preserved
across recreation; outputs are expected to come back from substituters.

## Direct port mode behaves differently from bridge mode

If `bridge.enable = false`, the host connects through the directly published
container port instead of the bridge agent. Troubleshooting should then focus on
the published host socket and container port mapping rather than the launchd
bridge path.
