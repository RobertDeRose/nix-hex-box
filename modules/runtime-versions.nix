{
  appleContainer = {
    version = "1.5.0";
    url = "https://github.com/apple/container/releases/download/1.5.0/container-1.5.0-installer-signed.pkg";
    hash = "sha256-okgIyyAjGPocO77gxsaIf+EiX+iZ17aHoN3ZOb1lc/g=";
  };

  socktainer = {
    version = "v1.5.3";
    url = "https://github.com/socktainer/socktainer/releases/download/v1.5.3/socktainer-installer.pkg";
    hash = "sha256-1mjm/X/4P9d4wgmeRNlMREO2WSGxZbb3IljjpH8McqU=";
  };

  builderImage = {
    repository = "ghcr.io/robertderose/nix-hex-box/hexbox-builder";
    version = "latest";
    releaseTag = "alpine-3.22-lix-2.95.2-2";
    lixVersion = "2.95.2";
  };
}
