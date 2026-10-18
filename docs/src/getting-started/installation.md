# Installation

This page takes you from nothing to a working Linux build. Plan on about ten
minutes, most of it waiting for the first image download.

## Before you start

You need:

- an Apple silicon Mac,
- a `nix-darwin` configuration managed with flakes, and
- Apple's `container` tool, installed and running (covered in step 1).

## 1. Install Apple's `container`

HexBox doesn't install `container` for you, so you can use whichever
installer you prefer. Pick one:

```bash
# Homebrew
brew install container

# mise (install it globally; see the note below)
mise use -g container

# Apple's signed package, from https://github.com/apple/container/releases
gh release download --repo apple/container --pattern 'container-*-installer-signed.pkg'
sudo installer -pkg container-*-installer-signed.pkg -target /
```

Then start it:

```bash
container system start
```

HexBox looks for `container` on your `PATH`. Background processes such as the
Nix daemon have a much shorter `PATH`, so HexBox also checks
`/opt/homebrew/bin`, `/usr/local/bin`, and your mise shims.

If you use mise, install `container` globally, as above. A version that's only
set for one project directory is invisible to the Nix daemon. If you really
want a per-project version, set
[`containerBinary`](../reference/options.md) to the full path that
`mise which container` prints.

## 2. Add HexBox to your flake

Add the input and the module, and turn the builder on:

```nix
{
  inputs.hexbox.url = "github:RobertDeRose/nix-hex-box";

  outputs = inputs: {
    darwinConfigurations.my-host = inputs.darwin.lib.darwinSystem {
      system = "aarch64-darwin";
      modules = [
        inputs.hexbox.darwinModules.default
        {
          services.container-builder = {
            enable = true;
            memory = "8G";
          };
        }
      ];
    };
  };
}
```

The machine gets 4 CPUs and only 1 GB of memory unless you say otherwise.
8 GB is a sensible starting point; see
[Configuration](./configuration.md) for sizing advice.

## 3. Switch

```bash
sudo darwin-rebuild switch --flake .#my-host
```

If `container` can't be found, the switch still finishes, but prints
`error: Apple container is not installed`. Fix that before going on.

## 4. Create the builder's SSH keys

This step is only needed once:

```bash
~/.local/state/hb/bootstrap-keys.sh
```

It creates the key Nix uses to log in to the builder, the builder's own host
key, and a `known_hosts` file so your Mac can check it's talking to the right
machine. Until these exist, the builder can't start, and each switch reminds
you with a warning.

## 5. Start the builder and try a build

```bash
hb builder repair
hb builder test
```

`hb builder repair` creates the machine. The first time, it downloads the
builder image, so give it a few minutes. When it finishes, it prints
`Run hb builder test to verify remote builds.`

`hb builder test` then builds a tiny Linux package through the builder. You
should see a line like this:

```text
building '/nix/store/…-hexbox-builder-smoke.drv' on 'ssh-ng://builder@container-builder'...
```

That's it. From now on, any `aarch64-linux` build goes to the builder
automatically, and the machine starts and stops on its own.
