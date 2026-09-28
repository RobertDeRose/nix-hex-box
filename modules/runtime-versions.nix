{
  appleContainer = {
    version = "1.4.1";
    url = "https://github.com/apple/container/releases/download/1.4.1/container-1.4.1-installer-signed.pkg";
    hash = "sha256-wNJxav77sZTJP65mLpyufMGGvLz3RoFmCOxnPdZIpqQ=";
  };

  socktainer = {
    version = "v1.4.0";
    url = "https://github.com/socktainer/socktainer/releases/download/v1.4.0/socktainer-installer.pkg";
    hash = "sha256-Sq/6ZRaZ0bEIldX885kr5k2eJS/gMPXem5S9puuFQf0=";
  };

  builderImage = {
    repository = "ghcr.io/robertderose/nix-hex-box/hexbox-builder";
    version = "latest";
    releaseTag = "alpine-3.22-lix-2.95.2-2";
    lixVersion = "2.95.2";
  };
}
