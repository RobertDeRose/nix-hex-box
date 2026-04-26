# Installation

Add the flake input and import the module into your Darwin host:

```nix
{
  inputs.hexbox.url = "github:RobertDeRose/nix-hex-box";

  outputs = inputs: {
    darwinConfigurations.my-host = inputs.darwin.lib.darwinSystem {
      system = "aarch64-darwin";
      modules = [
        inputs.hexbox.darwinModules.default
      ];
    };
  };
}
```

The module is intended for `nix-darwin` hosts running Apple Container capable
macOS systems. The builder guest is always `aarch64-linux`.
