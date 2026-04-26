# Logs And Diagnostics

Runtime logs live in `~/.local/state/hb`.

Common log files:

- `hexbox-readiness.log`
- `hexbox-idle.log`
- `init-debug.log`
- `hexbox-bridge.out.log`
- `hexbox-bridge.err.log`

Use the helper to read the most important logs:

```bash
hb logs readiness
hb logs bridge
hb logs bridge-out
hb logs boot
hb logs idle
```

These logs are usually the fastest way to determine whether a failure is in:

- Apple `container` runtime startup
- guest init/bootstrap
- SSH readiness
- bridge/proxy relay behavior
