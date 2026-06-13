# Design Notes

`nix-hex-box` currently follows these design choices:

- published Alpine/Lix based builder image in this repository's GHCR package
- optional local custom image builds from `imageContainerfile`
- persistent Apple `container machine` instead of generation-aware ordinary containers
- on-demand startup through SSH `ProxyCommand`
- no localhost bridge or published SSH port in the default builder path
- guest-side `builder` user with narrow passwordless sudo for the remote `nix-daemon`
- guest-side idle shutdown using a lightweight watchdog
- host-side `container machine run` executed as the runtime-owning macOS user, even when SSH is launched by root `nix-daemon`
- optional Socktainer sidecar for Docker-compatible local tooling

Known constraints:

- Apple `container` remains an external mutable runtime
- custom local builder image builds depend on the user's Containerfile inputs when configured
- deleting the container machine deletes guest-local `/nix` store contents
- host and guest behavior still depend on the health of Apple's virtualization and networking layers

Historical design notes from earlier overlay-based and bridge-based experiments
should no longer be treated as current behavior.
