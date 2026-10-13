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

## Sandboxed builds cannot start `pasta`

If a remote build reports a sandbox-network setup failure or `pasta` cannot
open `/dev/net/tun`, run `hb builder repair` so the guest bootstrap is applied.
The boot-time preparation provisions the standard `nixbld` build users and
restores the tunnel device group and mode before starting the Nix daemon. Check
that state from `hb builder ssh` with:

```bash
getent group nixbld
stat -c '%a %U:%G' /dev/net/tun
```

## NixOS VM tests time out or the guest daemon crashes

The default `supportedFeatures` include `kvm` and `nixos-test`, so Nix schedules
NixOS VM tests on the builder. Apple offers nested virtualization only on M3 and
later chips, so on earlier Macs the guest has no `/dev/kvm` and QEMU runs each
test VM in software emulation. Each VM then needs a full CPU and about 1 GB of
memory, and several at once overload the machine: test steps hit their
timeouts and the guest Nix daemon can run out of memory. The guest bootstrap
logs `/dev/kvm is unavailable` when this applies.

On those hosts, set `maxJobs` to 1 or 2 so only that many VM tests run at once.

## The machine changed IP address

This is expected after stop/start. The Nix builder path does not use the machine
IP directly; it connects through the generated SSH `ProxyCommand`, which runs
`container machine run` and relays to guest `sshd` inside the machine.

## Previous build outputs disappeared

The guest `/nix` store persists across normal machine stop/start cycles. If
outputs disappeared, the machine was probably removed and recreated. `hb builder
reset` is destructive for guest-local store contents.
