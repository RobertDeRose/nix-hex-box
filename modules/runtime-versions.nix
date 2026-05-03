{
  appleContainer = {
    version = "0.12.3";
    url = "https://github.com/apple/container/releases/download/0.12.3/container-0.12.3-installer-signed.pkg";
    hash = "sha256-g/NjEmrB8GRYjeOc1rR0NA1InBkmSSosTlnE1Uqm2OM=";
  };

  socktainer = {
    version = "v0.12.0";
    url = "https://github.com/socktainer/socktainer/releases/download/v0.12.0/socktainer-installer.pkg";
    hash = "sha256-Yg5OlZ5M4PwnFbBoUpp23JfpN4uNgngG8xIX37hohS4=";
  };

  nixImage = {
    repository = "docker.io/nixos/nix";
    version = "2.34.6";
  };
}
