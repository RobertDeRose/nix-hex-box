---
description: Where to find the HexBox logs, and what each one tells you when hb builder repair isn't enough.
---

# Logs

When something goes wrong, `hb builder repair` usually says where. These logs
tell you more.

```bash
hb builder logs boot        # the machine's boot output
hb builder logs readiness   # waiting for SSH during repair or reset
hb builder logs idle        # the idle watchdog
```

Each shows the last 100 lines. Add `-n 500` for more, or `-f` to keep
watching as new lines arrive.

## Which log to read

**`boot`** is the machine's console output as it starts. Read it when the
machine won't start, or starts but never becomes reachable. It shows the
guest setup too, including the `/dev/kvm is unavailable` line on Macs without
nested virtualization.

**`readiness`** records each attempt to log in over SSH during
`hb builder repair` and `hb builder reset`, and whether it timed out. It lives
on your Mac, at `~/.local/state/hb/hexbox-readiness.log`.

**`idle`** is the watchdog that shuts the builder down. Every 30 seconds it
writes whether anyone is connected and how long it has been idle. Read it if
the builder shuts down too soon, or never does. It lives inside the machine,
so reading it starts the machine.

## The builder's Nix daemon

The Nix daemon inside the builder writes to `/var/log/nix-daemon.log`. There's
no shortcut for it, but you can read it over SSH:

```bash
hb builder ssh tail -n 100 /var/log/nix-daemon.log
```
