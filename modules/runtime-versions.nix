{
  appleContainer = {
    version = "1.0.0";
    url = "https://github.com/apple/container/releases/download/1.0.0/container-1.0.0-installer-signed.pkg";
    hash = "sha256-E/RfJtqUw1Sty+/h6PdjHn8SbpPF1N1qWlOKpmtPR50=";
  };

  socktainer = {
    version = "v0.12.0";
    url = "https://github.com/socktainer/socktainer/releases/download/v0.12.0/socktainer-installer.pkg";
    hash = "sha256-Yg5OlZ5M4PwnFbBoUpp23JfpN4uNgngG8xIX37hohS4=";
  };

  nixImage = {
    repository = "docker.io/nixos/nix";
    version = "2.34.7";
  };
}
