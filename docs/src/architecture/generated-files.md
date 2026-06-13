# Generated Files

Activation writes the operational helper files into `~/.local/state/hb`.

Important files include:

- `bootstrap-keys.sh`
- `bootstrap-machine.sh`
- `builder-image/Containerfile`
- `proxy.sh`
- `start-container.sh`
- `stop-container.sh`
- `reset-container.sh`
- `ssh-wrapper.sh`
- `ssh_config`
- `ssh_config_root`
- `known_hosts`
- `hexbox-readiness.log`
- `hb`

These files are the practical runtime interface to the builder. They are
generated from the active Nix configuration and should not be edited manually.

The generated Containerfile is the source for the local `local/hexbox-builder`
OCI image. `hb builder repair` and `start-container.sh` build that image when it
is missing.

The repository copy of `assets/hb.sh` is also generated. Edit `scripts/hb.sh`
and regenerate `assets/hb.sh` instead of changing the built helper directly.

The checked-in shell completion assets under `assets/completions/` are part of
the `hb` distribution path. The module installs them through Nix's
`installShellCompletion` hook into the standard shell completion directories
instead of mutating user shell dotfiles.
