# Design notes

Why HexBox works the way it does, and what it can't do.

## Decisions

**A persistent machine, not a container.** An ordinary container starts fresh
each time, which would throw away the builder's `/nix` store. An Apple
`container` machine keeps its disk, so the builder can shut down when idle and
still have everything it built when it comes back.

**SSH through `container`, not over the network.** The machine's IP address
changes on every boot. Connecting through `container machine run` instead
means Nix never needs to know the address, and no port is opened on your Mac.

**Your user owns the runtime, even for root.** Apple's `container` runs per
user, and the Nix daemon runs as root. Rather than run a second runtime as
root, the SSH proxy switches to your user before calling `container`.

**A narrow sudo rule inside the guest.** Nix logs in as an ordinary `builder`
user, which can run one command as root: the Nix daemon. That's the least
access a remote builder needs.

**The idle watchdog lives in the guest.** The machine decides for itself when
nobody is using it, by watching its own SSH connections. Your Mac doesn't need
a background service to stop it.

**Bring your own `container`.** HexBox doesn't install Apple's `container`, so
you can use Homebrew, mise, or Apple's installer, and keep it up to date
however you like.

## Limits

- The builder only builds `aarch64-linux`.
- HexBox depends on Apple's `container`, which is still young and sometimes
  needs a restart. `hb builder repair` handles the common cases.
- On M1 and M2 Macs, NixOS VM tests run in software emulation, because those
  chips can't run virtual machines inside virtual machines.
- The default image comes from GitHub's container registry, so the first start
  needs to reach it.
- Replacing the machine, with `hb builder reset` or by changing the image,
  deletes everything in its `/nix` store.
- macOS only partly reclaims memory from a running machine. The memory is
  returned in full when the builder shuts down.

## Working on HexBox

The `hb` helper's source is `scripts/hb.sh`. `assets/hb.sh` is built from it
with `argc --argc-build`, so edit the script and rebuild, rather than editing
the built copy. The shell completions in `assets/completions/` are written by
hand; update them when you add or rename a command.
