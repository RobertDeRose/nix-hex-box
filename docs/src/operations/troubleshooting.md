# Troubleshooting

Each section starts with what you see. If yours isn't here, run
`hb builder repair`; it checks each piece in turn and suggests a next step.

## "Apple container is not installed" during a switch

HexBox couldn't find the `container` command. Install it (see
[Installation](../getting-started/installation.md#1-install-apples-container)),
then switch again.

If it is installed and HexBox still can't find it, it's probably somewhere the
Nix daemon doesn't look. HexBox checks your `PATH`, `/opt/homebrew/bin`,
`/usr/local/bin`, and your mise shims. With mise, make sure it's installed
globally (`mise use -g container`). Otherwise, set `containerBinary` to the
command's full path.

## "container-builder keys are missing" during a switch

You haven't created the builder's SSH keys yet. Run this once:

```bash
~/.local/state/hb/bootstrap-keys.sh
```

## Builds fail with "platform mismatch" or "local builds are disabled"

Nix couldn't use the builder, so it tried to build the Linux package on your
Mac, which can't. Check the builder:

```bash
hb builder repair
hb builder test
```

If `hb builder test` passes but your own build still fails, check whether you
used `--rebuild` or `--check`. Nix never sends those to a remote builder.

## The builder never becomes reachable

`hb builder repair` stops at "SSH handshake failed", or builds hang and then
fail. Look at what the machine did as it started:

```bash
hb builder logs boot
hb builder logs readiness
```

Look for an image that failed to build or download, a machine that didn't
finish booting, or SSH that never started. If you use a custom image, check
that it includes `socat`, `base64`, `getent`, and `/sbin/init`.

## Apple's `container` service is stuck

Apple's `container` is a separate service, and it occasionally gets into a bad
state that HexBox can't prevent. `hb doctor runtime` restarts it, and
`hb builder repair` does the same before anything else. If neither helps, try
`container system stop` and `container system start` yourself.

## Downloads from cache.nixos.org fail

The builder downloads prebuilt packages from `https://cache.nixos.org/`, so
it needs working DNS and internet access. Run:

```bash
hb doctor dns
```

It checks whether the builder can reach common websites, and restarts Apple's
`container` service if not. If it still fails, check your Mac's own network,
VPN, or proxy settings.

## Builds fail because `pasta` can't open `/dev/net/tun`

Sandboxed builds use `pasta` for networking, which needs `/dev/net/tun`. The
builder sets that up each time it boots. Run `hb builder repair` to restart
it, then check from inside:

```bash
hb builder ssh getent group nixbld
hb builder ssh stat -c '%a %U:%G' /dev/net/tun
```

## NixOS VM tests time out, or the builder's Nix daemon crashes

On M1 and M2 Macs, VM tests run in slow software emulation, and several at
once overload the builder. Set `maxJobs` to 1 or 2; see
[Configuration](../getting-started/configuration.md#on-m1-and-m2-macs-keep-maxjobs-low).

## Everything the builder had built is gone

The builder's `/nix` store survives stopping and starting. It's emptied when
the machine is replaced: by `hb builder reset`, or by HexBox after you change
the builder image. The next builds will download or rebuild what they need.

## Containers can't reach `host.container.internal`

HexBox sets up `host.container.internal` so Apple containers can reach
services on your Mac. Check it, and recreate it if it's missing:

```bash
hb doctor host        # can the name be found?
hb doctor host 8080   # can port 8080 on your Mac be reached?
```

The fix needs administrator rights, so it asks for your password. If you don't
want the name at all, set `exposeHostContainerInternal = false`.
