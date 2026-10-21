---
description: "The builder is a persistent Apple container machine: it keeps its disk when it stops, so it can sleep when idle without losing work."
---

# The builder machine

The builder is an Apple `container` machine named `nix-builder`. Unlike an
ordinary container, a machine is a persistent virtual machine: it keeps its
disk when it stops, and boots back into the same state. That's what lets the
builder shut down when idle without losing its work.

## What's inside

The machine runs the builder image (Alpine Linux with OpenSSH and Lix, unless
you [use your own](../getting-started/configuration.md#using-your-own-builder-image)).
When HexBox first creates it, a setup script:

- installs your Mac's SSH key for the `builder` user, and the machine's host
  key,
- writes a short `nix.conf` that uses `https://cache.nixos.org/`, so builds can
  download what's already been built instead of compiling it,
- adds a sudo rule that lets `builder` run only the Nix daemon as root, which
  Nix needs to build, and
- installs the idle watchdog that shuts the machine down.

On every boot, the machine also creates the `nixbld` build users and makes
`/dev/net/tun` available, which sandboxed builds need for networking.

## Its `/nix` store is kept

Everything the builder builds or downloads stays in its `/nix` store. Stopping
and starting the machine keeps it. Two things delete it, because both replace
the machine:

- running `hb builder reset`, and
- changing the image, for example a new `nixVersion` or a different
  Containerfile. HexBox notices the change on the next start and recreates the
  machine.

Changing other settings, such as the idle timeout, updates the machine in
place and keeps the store.

## Starting and stopping

You never start or stop the machine yourself. The first SSH connection boots
it ([How Nix reaches the builder](./networking.md) explains how), and the idle
watchdog inside it shuts it down.

The watchdog checks for open SSH connections every 30 seconds. Once there have
been none for the idle timeout (five minutes by default), it stops the
machine. Its log is `/var/log/hexbox-idle.log` inside the machine, which you
can read with `hb builder logs idle`.

When the machine starts, HexBox doesn't trust its reported status alone. It
runs a quick command inside the machine to prove it actually works, and if
that fails, stops the machine and boots it again. This recovers from the
occasional machine that Apple's `container` reports as running but isn't
responding.

## Memory

macOS gives memory back from a running virtual machine only partly. The
memory you give the builder is reliably returned to your Mac when the machine
shuts down, which is one more reason the idle shutdown is on by default.
