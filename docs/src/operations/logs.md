# Logs And Diagnostics

Runtime logs live in `~/.local/state/hb` and inside the builder machine.

Common host log files:

- `hexbox-readiness.log`

Common guest log files:

- `/var/log/hexbox-idle.log`
- `/var/log/nix-daemon.log`

Use the helper to read the most important logs:

```bash
hb builder logs readiness
hb builder logs boot
hb builder logs idle
hb socktainer logs
hb socktainer logs -f
```

These logs are usually the fastest way to determine whether a failure is in:

- Apple `container` runtime startup
- container machine boot
- guest bootstrap
- SSH readiness
- idle shutdown behavior
