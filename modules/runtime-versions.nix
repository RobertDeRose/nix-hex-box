{
  appleContainer = {
    version = "1.4.1";
    url = "https://github.com/apple/container/releases/download/1.4.1/container-1.4.1-installer-signed.pkg";
    hash = "sha256-wNJxav77sZTJP65mLpyufMGGvLz3RoFmCOxnPdZIpqQ=";
  };

  socktainer = {
    version = "v1.2.1";
    url = "https://github.com/socktainer/socktainer/releases/download/v1.2.1/socktainer-installer.pkg";
    hash = "sha256-m0fDb9yNZ01TfczJEK/v9WEDSWWZ/F4apiYJ1nLCHeA=";
  };

  builderImage = {
    repository = "ghcr.io/robertderose/nix-hex-box/hexbox-builder";
    version = "latest";
    releaseTag = "alpine-3.22-lix-2.95.2-2";
    lixVersion = "2.95.2";
  };
}
