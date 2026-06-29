# Network And Access Paths

The module uses one SSH transport for both user access and Nix daemon access.

## ProxyCommand path

The generated SSH config points `nix-builder` and `container-builder` at
`~/.local/state/hb/proxy.sh` as a `ProxyCommand`.

That proxy:

- sudoes back to the configured runtime-owning macOS user when invoked by root
- starts the Apple container system if needed
- creates or updates the builder machine when needed
- runs `container machine run --root -i -n <machine> socat STDIO TCP:127.0.0.1:<ssh-port>`
- relays SSH directly into guest `sshd` and closes the relay when SSH exits

Because the SSH connection enters through `container machine run`, the host does
not need to know the machine's current IP address. A stopped machine is booted on
demand before SSH reaches the guest.

## Root daemon path

The root `nix-daemon` uses the same host SSH config for `${cfg.hostAlias}`. The
macOS root process cannot operate the user-owned Apple container runtime
directly, so the proxy explicitly uses:

```text
sudo -n -u <runtimeUser> -H ... container machine run ...
```

After SSH reaches the guest, Nix connects as the `builder` user. The remote
program is the guest `nix-daemon` wrapper, which uses passwordless sudo inside
the guest to run the real Lix daemon as root.

This removes the old localhost bridge and avoids direct published SSH ports.
