---
description: How Nix reaches the builder over SSH, when container-builder is a script that wakes the machine rather than a network address.
---

# How Nix reaches the builder

Nix talks to the builder the way it talks to any remote builder: over SSH,
using `ssh-ng://builder@container-builder`. The trick is that
`container-builder` isn't a network address.

## The SSH host is a script

HexBox installs an SSH configuration, in
`/etc/ssh/ssh_config.d/201-container-builder.conf`, that defines two host
names, `container-builder` and `nix-builder`. Both point at a `ProxyCommand`:
a script at `~/.local/state/hb/proxy.sh`. When SSH connects, it runs that
script and talks to whatever the script connects it to.

The script:

1. Starts the builder machine if it isn't running, and recovers Apple's
   `container` services first if they aren't healthy.
2. Waits up to 30 seconds for the machine's SSH server to accept connections.
3. Runs `container machine run … socat`, which connects SSH straight to the
   SSH server inside the machine.

Because the connection goes through `container`, your Mac never needs to know
the machine's IP address, which changes every time it boots, and no port is
opened on your Mac.

The host key is checked against `~/.local/state/hb/known_hosts`, so SSH knows
it's talking to your builder and not something else.

You can use the same path yourself:

```bash
ssh nix-builder
```

## When root connects

Nix builds are started by the Nix daemon, which runs as root. Apple's
`container` runtime belongs to your user, and root can't use it directly. So
when root runs the proxy, the proxy switches to your user before calling
`container`.

## Inside the machine

SSH logs in as the `builder` user. Nix then starts the machine's own Nix
daemon through a sudo rule that allows only that one command, and the build
runs there. When it finishes, Nix copies the results back to your Mac's store
over the same connection.
