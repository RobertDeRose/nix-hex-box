{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.services.container-builder;
  owner = cfg.user;

  workDir = cfg.workingDirectory;
  containerExecutable = "/usr/local/bin/container";
  sshKeyPath = "${workDir}/builder_ed25519";
  hostKeyPath = "${workDir}/ssh_host_ed25519_key";
  runtimeLogPath = "${workDir}/container-runtime.log";
  readinessLogPath = "${workDir}/container-readiness.log";
  containerInstallerPkg = pkgs.fetchurl {
    url = cfg.installer.url;
    hash = cfg.installer.hash;
  };

  bootstrapKeysScript = pkgs.writeShellScript "container-builder-bootstrap-keys" ''
    set -euo pipefail

    workdir=${escapeShellArg workDir}
    mkdir -p "$workdir"

    if [ ! -f "$workdir/builder_ed25519" ]; then
      /usr/bin/ssh-keygen -t ed25519 -f "$workdir/builder_ed25519" -N "" -C ${escapeShellArg cfg.hostAlias}
    fi

    if [ ! -f "$workdir/ssh_host_ed25519_key" ]; then
      /usr/bin/ssh-keygen -t ed25519 -f "$workdir/ssh_host_ed25519_key" -N "" -C ${escapeShellArg "${cfg.containerName}-host"}
    fi
  '';

  initScript = pkgs.writeShellScript "container-builder-init" ''
    set -e
    export PATH="/root/.nix-profile/bin:$PATH"

    if ! id builder > /dev/null 2>&1; then
      echo "builder:x:1000:1000:builder:/home/builder:/bin/sh" >> /etc/passwd
      echo "builder:x:1000:" >> /etc/group
      mkdir -p /home/builder
      chown 1000:1000 /home/builder
    fi

    mkdir -p /etc/nix
    cat > /etc/nix/nix.conf << 'EOF'
    trusted-users = root builder
    experimental-features = nix-command flakes
    build-users-group =
    substituters = https://cache.nixos.org/
    trusted-substituters = https://cache.nixos.org/
    trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
    EOF

    mkdir -p /home/builder/.ssh
    cp /config/builder_ed25519.pub /home/builder/.ssh/authorized_keys
    chmod 700 /home/builder/.ssh
    chmod 600 /home/builder/.ssh/authorized_keys
    chown -R 1000:1000 /home/builder/.ssh

    mkdir -p /home/builder/.nix-profile/bin
    ln -sf /root/.nix-profile/bin/* /home/builder/.nix-profile/bin/ 2> /dev/null || true

    mkdir -p /etc/ssh
    cp /config/ssh_host_ed25519_key /etc/ssh/
    chmod 600 /etc/ssh/ssh_host_ed25519_key

    if ! id sshd > /dev/null 2>&1; then
      echo "sshd:x:74:74:sshd privsep:/var/empty:/bin/false" >> /etc/passwd
      echo "sshd:x:74:" >> /etc/group
      mkdir -p /var/empty
    fi

    mkdir -p /run/sshd
    cat > /etc/ssh/sshd_config << 'EOF'
    ListenAddress 0.0.0.0:${toString cfg.containerPort}
    HostKey /etc/ssh/ssh_host_ed25519_key
    PermitRootLogin no
    PubkeyAuthentication yes
    PasswordAuthentication no
    ChallengeResponseAuthentication no
    UsePAM no
    PrintMotd no
    AcceptEnv LANG LC_*
    SetEnv PATH=/root/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin:/usr/sbin:/sbin
    Subsystem sftp /root/.nix-profile/libexec/sftp-server
    MaxStartups 64:30:128
    MaxSessions 64
    EOF

    nix-daemon &
    exec $(which sshd) -D -e
  '';

  proxyScript = pkgs.writeShellScript "container-builder-proxy" ''
    exec ${escapeShellArg cfg.containerBinary} exec -i ${escapeShellArg cfg.containerName} \
      bash -c ${escapeShellArg "exec 3<>/dev/tcp/127.0.0.1/${toString cfg.containerPort}; cat <&3 & cat >&3; kill %1 2>/dev/null"}
  '';

  readinessScript = pkgs.writeShellScript "container-builder-readiness" ''
    set -euo pipefail

    host=${escapeShellArg cfg.listenAddress}
    port=${escapeShellArg (toString cfg.port)}
    timeout_seconds=${escapeShellArg (toString cfg.readiness.timeoutSeconds)}
    interval_seconds=${escapeShellArg (toString cfg.readiness.intervalSeconds)}
    deadline=$(( $(/bin/date +%s) + timeout_seconds ))

    echo "[$(/bin/date)] waiting for SSH on $host:$port"

    while [ "$(( $(/bin/date +%s) ))" -lt "$deadline" ]; do
      if ${pkgs.netcat}/bin/nc -z "$host" "$port" >/dev/null 2>&1; then
        echo "[$(/bin/date)] SSH port is reachable on $host:$port"
        exit 0
      fi

      /bin/sleep "$interval_seconds"
    done

    echo "[$(/bin/date)] timed out waiting for SSH on $host:$port" >&2
    exit 1
  '';

  startScript = pkgs.writeShellScript "container-builder-start" ''
    set -euo pipefail

    container_bin=${escapeShellArg cfg.containerBinary}
    workdir=${escapeShellArg workDir}
    container_name=${escapeShellArg cfg.containerName}

    if [ ! -f "$workdir/builder_ed25519" ] || [ ! -f "$workdir/ssh_host_ed25519_key" ]; then
      echo "container-builder keys missing in $workdir; run $workdir/bootstrap-keys.sh first" >&2
      exit 1
    fi

    container_info="$($container_bin inspect "$container_name" --format json 2>/dev/null || true)"

    if [ -n "$container_info" ]; then
      if printf '%s' "$container_info" | ${pkgs.gnugrep}/bin/grep -q '"state"[[:space:]]*:[[:space:]]*"running"'; then
        echo "container-builder container already running"
        exit 0
      fi

      echo "attempting to start existing container-builder container"
      if "$container_bin" start "$container_name"; then
        exit 0
      fi

      echo "existing container-builder container is stale; recreating"
      "$container_bin" rm -f "$container_name" >/dev/null 2>&1 || true
    fi

    args=(
      run
      -d
      --name "$container_name"
      --cpus ${escapeShellArg (toString cfg.cpus)}
      -m ${escapeShellArg cfg.memory}
      -v ${escapeShellArg "${workDir}:/config"}
    )

    ${optionalString (cfg.dns.servers != [ ]) ''
      ${concatMapStringsSep "\n" (server: "args+=( --dns ${escapeShellArg server} )") cfg.dns.servers}
    ''}

    ${optionalString (cfg.dns.search != [ ]) ''
      ${concatMapStringsSep "\n" (domain: "args+=( --dns-search ${escapeShellArg domain} )") cfg.dns.search}
    ''}

    ${optionalString (cfg.dns.options != [ ]) ''
      ${concatMapStringsSep "\n" (option: "args+=( --dns-option ${escapeShellArg option} )") cfg.dns.options}
    ''}

    ${optionalString (cfg.dns.domain != null) ''
      args+=( --dns-domain ${escapeShellArg cfg.dns.domain} )
    ''}

    ${optionalString cfg.dns.disable ''
      args+=( --no-dns )
    ''}

    ${optionalString (!cfg.bridge.enable) ''
      args+=( -p ${escapeShellArg "${cfg.listenAddress}:${toString cfg.port}:${toString cfg.containerPort}"} )
    ''}

    args+=(
      ${escapeShellArg cfg.image}
      sh
      -c
      ${escapeShellArg "sh /config/init.sh"}
    )

    exec "$container_bin" "''${args[@]}"
  '';

  stopScript = pkgs.writeShellScript "container-builder-stop" ''
    set -euo pipefail
    exec ${escapeShellArg cfg.containerBinary} rm -f ${escapeShellArg cfg.containerName}
  '';

  runtimeScript = pkgs.writeShellScript "container-builder-runtime" ''
    set -euo pipefail

    workdir=${escapeShellArg workDir}
    log_file=${escapeShellArg runtimeLogPath}
    readiness_log=${escapeShellArg readinessLogPath}

    mkdir -p "$workdir"
    exec >> "$log_file" 2>&1

    echo "[$(/bin/date)] ensuring container builder runtime"

    ${bootstrapKeysScript}

    ${escapeShellArg cfg.containerBinary} system start

    ${startScript}

    ${readinessScript} >> "$readiness_log" 2>&1
  '';

  userSshConfig = pkgs.writeText "container-builder-ssh-config" ''
    Host nix-builder
      User ${cfg.sshUser}
      IdentityFile ${sshKeyPath}
      ProxyCommand ${workDir}/proxy.sh
      StrictHostKeyChecking no
      UserKnownHostsFile /dev/null
      LogLevel ERROR
  '';

  rootSshConfig = pkgs.writeText "container-builder-root-ssh-config" ''
    Host ${cfg.hostAlias}
      HostName ${cfg.listenAddress}
      Port ${toString cfg.port}
      User ${cfg.sshUser}
      IdentityFile ${sshKeyPath}
      StrictHostKeyChecking no
      UserKnownHostsFile /dev/null
  '';

  sshWrapperScript = pkgs.writeShellScript "container-builder-ssh-wrapper" ''
    exec ssh -F ${escapeShellArg "${workDir}/ssh_config"} "$@"
  '';
in
{
  options.services.container-builder = {
    enable = mkEnableOption "Apple container-based Linux remote builder";

    hostAlias = mkOption {
      type = types.str;
      default = "container-builder";
      description = "SSH host alias used by Nix for the remote builder.";
    };

    sshUser = mkOption {
      type = types.str;
      default = "builder";
      description = "User Nix connects to over SSH inside the container.";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Host address for the builder bridge or published SSH port.";
    };

    port = mkOption {
      type = types.port;
      default = 2222;
      description = "Host port exposed to the nix-daemon for builder SSH.";
    };

    containerPort = mkOption {
      type = types.port;
      default = 22;
      description = "SSH port listened to inside the container.";
    };

    workingDirectory = mkOption {
      type = types.str;
      default = "/Users/${owner}/.local/state/container-builder";
      description = "Directory holding keys, helper scripts, and bridge logs.";
    };

    user = mkOption {
      type = types.str;
      default = config.system.primaryUser;
      defaultText = literalExpression "config.system.primaryUser";
      description = "Primary macOS user that owns the builder state directory and user launch agents.";
    };

    containerBinary = mkOption {
      type = types.str;
      default = containerExecutable;
      description = "Path to Apple's container CLI binary installed by the official pkg.";
    };

    installer.url = mkOption {
      type = types.str;
      default = "https://github.com/apple/container/releases/download/0.11.0/container-0.11.0-installer-signed.pkg";
      description = "Official Apple container installer package URL.";
    };

    installer.hash = mkOption {
      type = types.str;
      default = "sha256-kGNqRgOmaeurQZuuHh2dMijAFWxJAiY8ksGdBQMPQEo=";
      description = "Hash of the Apple container installer package.";
    };

    installer.version = mkOption {
      type = types.str;
      default = "0.11.0";
      description = "Expected `container --version` string suffix used for activation checks.";
    };

    containerName = mkOption {
      type = types.str;
      default = "nix-builder";
      description = "Name of the Apple container used for Linux builds.";
    };

    image = mkOption {
      type = types.str;
      default = "docker.io/nixos/nix:latest";
      description = "OCI image used for the Linux builder container.";
    };

    cpus = mkOption {
      type = types.ints.positive;
      default = 4;
      description = "CPU count passed to `container run`.";
    };

    memory = mkOption {
      type = types.str;
      default = "1G";
      description = "Memory value passed to `container run -m`.";
    };

    dns.servers = mkOption {
      type = types.listOf types.str;
      default = [
        "1.1.1.1"
        "8.8.8.8"
      ];
      description = "DNS servers passed to `container run --dns` for the builder container.";
    };

    dns.search = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "DNS search domains passed to `container run --dns-search`.";
    };

    dns.options = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Resolver options passed to `container run --dns-option`.";
    };

    dns.domain = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Default DNS domain passed to `container run --dns-domain`.";
    };

    dns.disable = mkOption {
      type = types.bool;
      default = false;
      description = "Disable container DNS configuration with `container run --no-dns`.";
    };

    systems = mkOption {
      type = types.listOf types.str;
      default = [ "aarch64-linux" ];
      description = "Systems this remote builder can execute.";
    };

    supportedFeatures = mkOption {
      type = types.listOf types.str;
      default = [
        "benchmark"
        "big-parallel"
        "kvm"
        "nixos-test"
      ];
      description = "Nix builder features advertised for the container builder.";
    };

    mandatoryFeatures = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Nix builder features required for this builder to be selected.";
    };

    maxJobs = mkOption {
      type = types.ints.positive;
      default = 4;
      description = "Maximum concurrent jobs reported for this builder.";
    };

    speedFactor = mkOption {
      type = types.ints.positive;
      default = 1;
      description = "Relative builder speed used by Nix scheduling.";
    };

    protocol = mkOption {
      type = types.str;
      default = "ssh-ng";
      description = "Remote store protocol used by Nix to talk to the builder.";
    };

    autoStart = mkOption {
      type = types.bool;
      default = true;
      description = "Start the Apple container system and builder container automatically via a user launch agent.";
    };

    readiness.timeoutSeconds = mkOption {
      type = types.ints.positive;
      default = 30;
      description = "How long startup waits for the builder SSH port to become reachable.";
    };

    readiness.intervalSeconds = mkOption {
      type = types.ints.positive;
      default = 1;
      description = "Polling interval for builder SSH readiness checks.";
    };

    bridge.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Run a user launch agent with socat to bridge host SSH traffic into `container exec`.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin && pkgs.stdenv.hostPlatform.isAarch64;
        message = "`services.container-builder` is currently only supported on aarch64-darwin.";
      }
    ];

    environment.systemPackages = [
      pkgs.netcat
      pkgs.socat
    ];

    environment.etc."ssh/ssh_config.d/201-container-builder.conf".source = rootSshConfig;

    system.activationScripts.containerBuilder.text = ''
      if [ ! -x ${escapeShellArg containerExecutable} ] || ! ${escapeShellArg containerExecutable} --version 2>/dev/null | /usr/bin/grep -q ${escapeShellArg cfg.installer.version}; then
        echo "installing Apple container ${cfg.installer.version} from official pkg..." >&2
        /usr/sbin/installer -pkg ${escapeShellArg containerInstallerPkg} -target /
      fi

      ${pkgs.coreutils}/bin/mkdir -p ${escapeShellArg workDir}
      /usr/sbin/chown ${escapeShellArg owner}:staff ${escapeShellArg workDir}
      /bin/chmod 0700 ${escapeShellArg workDir}
      ${pkgs.coreutils}/bin/install -m 0755 ${bootstrapKeysScript} ${escapeShellArg "${workDir}/bootstrap-keys.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${initScript} ${escapeShellArg "${workDir}/init.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${proxyScript} ${escapeShellArg "${workDir}/proxy.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${startScript} ${escapeShellArg "${workDir}/start-container.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${stopScript} ${escapeShellArg "${workDir}/stop-container.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${sshWrapperScript} ${escapeShellArg "${workDir}/ssh-wrapper.sh"}
      ${pkgs.coreutils}/bin/install -m 0644 ${userSshConfig} ${escapeShellArg "${workDir}/ssh_config"}
      ${pkgs.coreutils}/bin/install -m 0644 ${rootSshConfig} ${escapeShellArg "${workDir}/ssh_config_root"}
      /usr/sbin/chown ${escapeShellArg owner}:staff \
        ${escapeShellArg "${workDir}/bootstrap-keys.sh"} \
        ${escapeShellArg "${workDir}/init.sh"} \
        ${escapeShellArg "${workDir}/proxy.sh"} \
        ${escapeShellArg "${workDir}/start-container.sh"} \
        ${escapeShellArg "${workDir}/stop-container.sh"} \
        ${escapeShellArg "${workDir}/ssh-wrapper.sh"} \
        ${escapeShellArg "${workDir}/ssh_config"} \
        ${escapeShellArg "${workDir}/ssh_config_root"}

      if [ ! -e ${escapeShellArg sshKeyPath} ] || [ ! -e ${escapeShellArg "${sshKeyPath}.pub"} ] || [ ! -e ${escapeShellArg hostKeyPath} ] || [ ! -e ${escapeShellArg "${hostKeyPath}.pub"} ]; then
        echo "warning: container-builder keys are missing in ${workDir}; run ${workDir}/bootstrap-keys.sh" >&2
      fi
    '';

    launchd.user.agents.container-builder-bridge = mkIf cfg.bridge.enable {
      serviceConfig = {
        KeepAlive = true;
        RunAtLoad = true;
        ProgramArguments = [
          "${pkgs.socat}/bin/socat"
          "TCP-LISTEN:${toString cfg.port},bind=${cfg.listenAddress},reuseaddr,fork"
          "EXEC:${workDir}/proxy.sh"
        ];
        StandardErrorPath = "${workDir}/socat-bridge.err.log";
        StandardOutPath = "${workDir}/socat-bridge.out.log";
        WorkingDirectory = workDir;
      };
      managedBy = "services.container-builder.bridge.enable";
    };

    launchd.user.agents.container-builder-runtime = mkIf cfg.autoStart {
      serviceConfig = {
        ProgramArguments = [ "${runtimeScript}" ];
        KeepAlive = true;
        RunAtLoad = true;
        ProcessType = "Background";
        StandardErrorPath = "${workDir}/container-runtime.err.log";
        StandardOutPath = "${workDir}/container-runtime.out.log";
        WorkingDirectory = workDir;
      };
      managedBy = "services.container-builder.autoStart";
    };

    nix.distributedBuilds = true;
    nix.settings.builders-use-substitutes = true;
    nix.buildMachines = [
      ({
        hostName = cfg.hostAlias;
        sshUser = cfg.sshUser;
        sshKey = sshKeyPath;
        inherit (cfg)
          mandatoryFeatures
          maxJobs
          protocol
          speedFactor
          supportedFeatures
          systems
          ;
      })
    ];
  };
}
