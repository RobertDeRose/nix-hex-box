{ ... }:
{
  imports = [
    # Add this module from your flake inputs:
    # inputs.hexbox.darwinModules.default
  ];

  services.container-builder = {
    enable = true;
    cpus = 4;
    maxJobs = 4;
    # Optional Docker API compatibility layer on top of Apple container.
    # socktainer.enable = true;

    # Optional if you want to override config.system.primaryUser.
    # user = "myuser";
  };
}
