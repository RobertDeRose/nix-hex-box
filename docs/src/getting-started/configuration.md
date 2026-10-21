---
description: The HexBox settings most people change, from memory and CPUs to the idle timeout and a custom builder image.
---

# Configuration

Every setting lives under `services.container-builder`. Only `enable` is
required; everything else has a default. This page covers the settings most
people change. [Options](../reference/options.md) lists all of them.

## Machine size

```nix
services.container-builder = {
  enable = true;
  cpus = 4;        # the default
  memory = "8G";   # the default is "1G"
  maxJobs = 4;     # the default
};
```

`cpus` and `memory` size the builder machine. The 1 GB default is enough for
small packages, but compilers and linkers run out of memory quickly, so most
people want 4 to 8 GB or more. The memory is only in use while the machine is
running.

`maxJobs` is how many builds Nix runs on the builder at once. Keep it at or
below `cpus`.

### On M1 and M2 Macs, keep `maxJobs` low

The builder advertises the `kvm` and `nixos-test` features, so Nix sends NixOS
VM tests to it. Macs before the M3 can't run virtual machines inside virtual
machines, so those tests fall back to slow software emulation. Each one needs a
full CPU and about 1 GB of memory, and running several at once makes them time
out or crashes the builder's Nix daemon.

On those Macs, set `maxJobs` to 1 or 2. The builder logs
`/dev/kvm is unavailable` when this applies to you.

## When it shuts down

The builder powers off once no one has been connected to it for five minutes.
To wait longer, or never shut down:

```nix
services.container-builder.idleShutdown.timeoutSeconds = 1800;  # 30 minutes
# or
services.container-builder.idleShutdown.enable = false;
```

The builder checks every 30 seconds, so it may run up to half a minute past
the timeout. Shutting down doesn't lose anything: the `/nix` store is kept.

## Access to your home folder

By default, the builder can't see any of your files. Nix copies everything a
build needs, so most people never need to change this. If you have a reason to
let the builder read your home folder, or write to it:

```nix
services.container-builder.homeMount = "ro";  # read-only; "rw" allows writes
```

## Using your own builder image

By default, the builder runs an image published by this project:
`ghcr.io/robertderose/nix-hex-box/hexbox-builder:latest`. It's Alpine Linux
with OpenSSH, sudo, and Lix, and it's rebuilt weekly to pick up security
fixes. If you'd rather pin a version, the image is also published under tags
such as `alpine-3.22-lix-2.95.2-2`; set `nixVersion` to the tag you want.

To build your own image instead, point HexBox at a Containerfile:

```nix
services.container-builder = {
  imageContainerfile = ./builder.Containerfile;
  # Optional: a folder the build can COPY files from. It must be an absolute path.
  imageBuildContext = "/Users/me/builder-image";
};
```

HexBox builds it the first time the builder starts. Your image needs `socat`,
`base64`, `getent`, and a working `/sbin/init`, because HexBox uses them to
set up the machine and to relay SSH into it.

HexBox only rebuilds the image when its tag is missing. After changing your
Containerfile, change `nixVersion` too, or delete the old image, so the new one
gets built.

Changing the image recreates the builder machine, which empties its `/nix`
store. The next builds will download or rebuild what they need.

## Shell completions for `hb`

```nix
services.container-builder.cli.completions.enable = true;
```

This installs completions for bash, zsh, and fish where your shell already
looks for them. HexBox doesn't change your shell's startup files.

## Running as a different user

The builder machine belongs to one macOS user, who owns the `container`
runtime. That's your `nix-darwin` primary user unless you set `user`:

```nix
services.container-builder.user = "alex";
```
