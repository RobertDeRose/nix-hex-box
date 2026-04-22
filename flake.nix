{
  description = "HexBox: a nix-darwin Linux builder module";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    darwin = {
      url = "github:nix-darwin/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "aarch64-darwin" "x86_64-darwin" ];

      flake = {
        darwinModules.default = import ./modules/container-builder.nix;
        darwinModules.container-builder = import ./modules/container-builder.nix;
      };

      perSystem = { pkgs, ... }: {
        formatter = pkgs.nixfmt;
      };
    };
}
