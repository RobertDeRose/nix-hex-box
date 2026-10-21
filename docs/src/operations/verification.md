---
description: Use the hb command to check the builder, repair it, and run a real build through it.
---

# Checking and repairing the builder

The `hb` command is how you look after the builder. Most days you won't need
it; this page is for when you do.

## Is it working?

```bash
hb builder status
```

`hb builder` on its own does the same. You'll see four lines:

```text
🔨 Builder status
container system   ✅ running
builder machine    ✅ running
ssh handshake      ✅ ready
remote store       ✅ reachable
```

- **container system** is Apple's `container` service on your Mac.
- **builder machine** is the Linux machine. `stopped` is normal when nothing
  has been built for a while; the next build starts it.
- **ssh handshake** and **remote store** are only checked while the machine is
  running. They confirm your Mac can log in and that Nix can talk to the
  builder.

To prove a build actually works end to end, run:

```bash
hb builder test
```

It builds a tiny Linux package on the builder, starting the machine first if
needed, and gives up after 60 seconds.

## Fixing problems

```bash
hb builder repair
```

Run this whenever something seems wrong. It works through each piece in turn
and stops at the first one it can't fix, telling you what to try next:

1. It checks Apple's `container` service, and restarts it if it isn't
   healthy.
2. It starts the builder, building your custom image first if you use one and
   it's missing.
3. It waits for a real SSH login to succeed, retrying a few times.
4. It checks that the builder can reach the internet.
5. It checks that Nix on your Mac can reach the builder.

When it succeeds, run `hb builder test`.

### Starting over

```bash
hb builder reset
```

This deletes the builder machine and creates a new one. It also deletes the
builder's `/nix` store, so everything it built or downloaded is gone, and the
next builds start from scratch. Use it when `repair` can't fix things.

## Other commands

| Command | What it does |
|---|---|
| `hb builder ssh` | Opens a shell on the builder. Add a command to run just that, for example `hb builder ssh df -h`. |
| `hb builder gc` | Deletes everything unused from the builder's `/nix` store (`nix-collect-garbage -d`). |
| `hb builder inspect` | Shows Apple `container`'s raw details about the machine. |
| `hb builder logs` | Shows the builder's logs; see [Logs](./logs.md). |
| `hb doctor` | Runs the three checks below, one after another. |
| `hb doctor runtime` | Checks Apple's `container` service and restarts it if needed. |
| `hb doctor dns` | Checks the builder can reach common websites. If not, restarts Apple's `container` service and tries once more. |
| `hb doctor host` | Checks the builder can find your Mac at `host.container.internal`, and recreates that name if it's missing (this asks for your password). |
| `hb doctor host 8080` | The same, and also checks the builder can connect to port 8080 on your Mac. |

The `hb builder ssh`, `gc`, and `logs idle` commands connect to the builder,
so they start it if it's stopped.

## Without `hb`

The builder is an ordinary Nix remote builder, so the usual tools work too:

```bash
ssh nix-builder true
nix store ping --store ssh-ng://container-builder
```

To send a real build to it:

```bash
nix build --max-jobs 0 nixpkgs#legacyPackages.aarch64-linux.hello
```

`--max-jobs 0` stops your Mac from building anything itself. If the package is
already in your store, Nix has nothing to build; `hb builder test` avoids that
by making a fresh package each time. Don't add `--rebuild` to force a build:
Nix never sends rebuilds to a remote builder.
