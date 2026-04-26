# Generated Files

Activation writes the operational helper files into `~/.local/state/hb`.

Important files include:

- `bootstrap-keys.sh`
- `hexbox-bridge`
- `init.sh`
- `proxy.sh`
- `start-container.sh`
- `stop-container.sh`
- `ssh-wrapper.sh`
- `ssh_config`
- `ssh_config_root`
- `hexbox-readiness.log`
- `hexbox-idle.log`
- `init-debug.log`
- `hb`

These files are the practical runtime interface to the builder. They are
generated from the active Nix configuration and should not be edited manually.
