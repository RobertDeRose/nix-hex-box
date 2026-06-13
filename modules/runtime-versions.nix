{
  appleContainer = {
    version = "1.0.0";
    url = "https://github.com/apple/container/releases/download/1.0.0/container-1.0.0-installer-signed.pkg";
    hash = "sha256-E/RfJtqUw1Sty+/h6PdjHn8SbpPF1N1qWlOKpmtPR50=";
  };

  socktainer = {
    version = "v1.0.0";
    url = "https://github.com/socktainer/socktainer/releases/download/v1.0.0/socktainer-installer.pkg";
    hash = "sha256-VeBxolTFItpdG/IxDr+MjXuMl8zrQFWwOJY46KzVQ+g=";
  };

  builderImage = {
    repository = "local/hexbox-builder";
    version = "alpine-3.22-lix-2.95.2-1";
  };
}
