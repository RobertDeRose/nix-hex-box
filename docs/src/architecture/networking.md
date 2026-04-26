# Network And Access Paths

The module uses two related access paths.

## User-side SSH path

The user SSH config points at `~/.local/state/hb/proxy.sh` as a `ProxyCommand`.
That proxy:

- starts the Apple container system if needed
- starts the builder on demand
- waits for guest `sshd`
- resolves the current container IP
- relays SSH directly into the guest

This path is used for helper access such as `ssh container-builder true`.

## Root daemon path

The root `nix-daemon` path still uses the localhost bridge as the compatible
transport for daemon-driven builds on current hosts.

When `bridge.enable = true`, the bridge agent exposes:

```text
127.0.0.1:2222
```

and forwards incoming connections into the wake-and-relay path.

This split exists because the direct user path and the daemon-driven path have
different compatibility constraints on macOS.
