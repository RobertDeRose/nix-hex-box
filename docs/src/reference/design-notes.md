# Design Notes

`nix-hex-box` currently follows these design choices:

- upstream pinned `nixos/nix` image instead of a custom prebuilt image
- generation-aware container recreation
- on-demand user-side startup through `ProxyCommand`
- optional bridge for the root daemon path, with direct published-port mode available when disabled
- guest-side idle shutdown using a lightweight watchdog
- explicit DNS configuration support for builder cache resolution

Known constraints:

- Apple `container` remains an external mutable runtime
- the daemon path still depends on the localhost bridge in current deployments
- recreating the container loses guest-local build outputs
- host and guest behavior still depend on the health of Apple's virtualization and networking layers

Historical design notes from earlier overlay-based experiments should no longer
be treated as current behavior.
