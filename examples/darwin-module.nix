{ ... }:
{
  imports = [
    # Add this module from your flake inputs:
    # inputs.apple-container-builder.darwinModules.default
  ];

  services.container-builder = {
    enable = true;
    cpus = 4;
    maxJobs = 4;

    # Optional if you want to override config.system.primaryUser.
    # user = "myuser";
  };
}
