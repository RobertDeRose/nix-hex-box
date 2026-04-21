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
  overlayMountDir = "/nix-overlay";
  overlayUpperDir = "${overlayMountDir}/upper";
  overlayWorkDir = "${overlayMountDir}/work";
  containerConfigSpec = pkgs.writeText "container-builder-config.json" (builtins.toJSON {
    inherit owner;
    containerName = cfg.containerName;
    hostAlias = cfg.hostAlias;
    sshUser = cfg.sshUser;
    listenAddress = cfg.listenAddress;
    port = cfg.port;
    containerPort = cfg.containerPort;
    workingDirectory = cfg.workingDirectory;
    image = cfg.image;
    cpus = cfg.cpus;
    memory = cfg.memory;
    dns = cfg.dns;
    bridgeEnable = cfg.bridge.enable;
    installerVersion = cfg.installer.version;
    protocol = cfg.protocol;
    systems = cfg.systems;
    supportedFeatures = cfg.supportedFeatures;
    mandatoryFeatures = cfg.mandatoryFeatures;
    maxJobs = cfg.maxJobs;
    speedFactor = cfg.speedFactor;
    autoStart = cfg.autoStart;
    inherit overlayMountDir overlayUpperDir overlayWorkDir;
  });
  containerVersion = builtins.substring 0 12 (builtins.baseNameOf containerConfigSpec);
  effectiveContainerName = "${cfg.containerName}-${containerVersion}";
  overlayVolumeName = "${cfg.containerName}-nix-overlay-${containerVersion}";
  containerConfigStamp = "generation=${containerVersion}";

  workDir = cfg.workingDirectory;
  cacheDir = "${workDir}/cache";
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
      /usr/bin/ssh-keygen -t ed25519 -f "$workdir/ssh_host_ed25519_key" -N "" -C ${escapeShellArg "${effectiveContainerName}-host"}
    fi
  '';

  initScript = pkgs.writeShellScript "container-builder-init" ''
    set -e
    export PATH="/root/.nix-profile/bin:$PATH"

    overlay_root=${escapeShellArg overlayMountDir}
    overlay_upper=${escapeShellArg overlayUpperDir}
    overlay_work=${escapeShellArg overlayWorkDir}

    # Preserve the image's built-in /nix as the lower layer and keep builder
    # writes in a persistent Apple container volume mounted at $overlay_root.
    mkdir -p "$overlay_root" "$overlay_upper" /nix-lower /nix-merged
    rm -rf "$overlay_work"
    mkdir -p "$overlay_work"
    mount --bind /nix /nix-lower
    mount -t overlay overlay -o "lowerdir=/nix-lower,upperdir=$overlay_upper,workdir=$overlay_work" /nix-merged
    mount --move /nix-merged /nix

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
    narinfo-cache-positive-ttl = 3600
    narinfo-cache-negative-ttl = 60
    narinfo-cache-dir = /var/cache/nix/narinfo
    EOF

    mkdir -p /var/cache/nix/narinfo

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
    fi
    mkdir -p /var/empty

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
    exec /root/.nix-profile/bin/sshd -D -e
  '';

  proxyScript = pkgs.writeShellScript "container-builder-proxy" ''
    exec ${escapeShellArg cfg.containerBinary} exec -i ${escapeShellArg effectiveContainerName} \
      bash -c ${escapeShellArg "exec 3<>/dev/tcp/127.0.0.1/${toString cfg.containerPort}; cat <&3 & cat >&3; kill %1 2>/dev/null"}
  '';

  readinessScript = pkgs.writeShellScript "container-builder-readiness" ''
    set -euo pipefail

    host_alias=${escapeShellArg cfg.hostAlias}
    ssh_config=${escapeShellArg "${workDir}/ssh_config_root"}
    timeout_seconds=${escapeShellArg (toString cfg.readiness.timeoutSeconds)}
    interval_seconds=${escapeShellArg (toString cfg.readiness.intervalSeconds)}
    deadline=$(( $(/bin/date +%s) + timeout_seconds ))

    echo "[$(/bin/date)] waiting for SSH readiness on $host_alias"

    while [ "$(( $(/bin/date +%s) ))" -lt "$deadline" ]; do
      if /usr/bin/ssh -F "$ssh_config" -o BatchMode=yes -o ConnectTimeout=2 "$host_alias" true >/dev/null 2>&1; then
        echo "[$(/bin/date)] SSH is ready on $host_alias"
        exit 0
      fi

      /bin/sleep "$interval_seconds"
    done

    echo "[$(/bin/date)] timed out waiting for SSH readiness on $host_alias" >&2
    exit 1
  '';

  startScript = pkgs.writeShellScript "container-builder-start" ''
    set -euo pipefail

    container_bin=${escapeShellArg cfg.containerBinary}
    workdir=${escapeShellArg workDir}
    container_base=${escapeShellArg cfg.containerName}
    container_name=${escapeShellArg effectiveContainerName}
    overlay_volume=${escapeShellArg overlayVolumeName}

    if [ ! -f "$workdir/builder_ed25519" ] || [ ! -f "$workdir/ssh_host_ed25519_key" ]; then
      echo "container-builder keys missing in $workdir; run $workdir/bootstrap-keys.sh first" >&2
      exit 1
    fi

    while IFS= read -r line; do
      set -- $line
      existing_name="$1"

      if [ -z "$existing_name" ] || [ "$existing_name" = "ID" ]; then
        continue
      fi

      case "$existing_name" in
        "$container_name")
          ;;
        "$container_base")
          echo "removing stale unversioned container-builder container"
          "$container_bin" rm -f "$existing_name" >/dev/null 2>&1 || true
          ;;
        "$container_base"-*)
          echo "removing stale container-builder generation $existing_name"
          "$container_bin" rm -f "$existing_name" >/dev/null 2>&1 || true
          ;;
      esac
    done < <("$container_bin" list --all 2>/dev/null || true)

    while IFS= read -r line; do
      set -- $line
      existing_volume="$1"

      if [ -z "$existing_volume" ] || [ "$existing_volume" = "NAME" ]; then
        continue
      fi

      case "$existing_volume" in
        "$overlay_volume")
          ;;
        "$container_base"-nix-overlay-*)
          echo "removing stale container-builder overlay volume $existing_volume"
          "$container_bin" volume delete "$existing_volume" >/dev/null 2>&1 || true
          ;;
      esac
    done < <("$container_bin" volume list 2>/dev/null || true)

    container_info="$($container_bin inspect "$container_name" 2>/dev/null || true)"

    if [ -n "$container_info" ]; then
      if ! printf '%s' "$container_info" | ${pkgs.gnugrep}/bin/grep -q ${escapeShellArg containerConfigStamp}; then
        echo "existing container-builder container does not match current config generation; recreating"
        "$container_bin" rm -f "$container_name" >/dev/null 2>&1 || true
        container_info=""
      fi
    fi

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

    if ! "$container_bin" volume inspect "$overlay_volume" >/dev/null 2>&1; then
      echo "creating persistent builder overlay volume $overlay_volume"
      "$container_bin" volume create \
        --label ${escapeShellArg "org.nixos.container-builder.overlay=true"} \
        "$overlay_volume" >/dev/null
    fi

    args=(
      run
      -d
      --rm
      --name "$container_name"
      --label ${escapeShellArg "org.nixos.container-builder.${containerConfigStamp}"}
      --cpus ${escapeShellArg (toString cfg.cpus)}
      -m ${escapeShellArg cfg.memory}
      -v ${escapeShellArg "${workDir}:/config"}
      -v ${escapeShellArg "${overlayVolumeName}:${overlayMountDir}"}
      -v ${escapeShellArg "${cacheDir}:/var/cache/nix/narinfo"}
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
    exec ${escapeShellArg cfg.containerBinary} rm -f ${escapeShellArg effectiveContainerName}
  '';

  statusScript = pkgs.writeShellScript "container-builder-status" ''
    set -euo pipefail

    mode="status"
    if [ "''${1:-}" = "--verify" ]; then
      mode="verify"
      shift
    elif [ "''${1:-}" = "--help" ] || [ "''${1:-}" = "-h" ]; then
      cat <<'EOF'
Usage: container-builder-status [--verify]

  No flag    Show non-destructive builder status.
  --verify   Perform full verification and attempt runtime recovery if needed.
EOF
      exit 0
    elif [ "$#" -gt 0 ]; then
      echo "unknown argument: $1" >&2
      exit 2
    fi

    host_alias=${escapeShellArg cfg.hostAlias}
    ssh_config=${escapeShellArg "${workDir}/ssh_config_root"}
    container_bin=${escapeShellArg cfg.containerBinary}
    container_name=${escapeShellArg effectiveContainerName}
    runtime_plist="$HOME/Library/LaunchAgents/org.nixos.container-builder-runtime.plist"

    recover_container_system() {
      printf '\n==> container system recovery\n'

      if [ -f "$runtime_plist" ]; then
        launchctl unload "$runtime_plist" || true
      fi

      "$container_bin" system start --enable-kernel-install

      if [ -f "$runtime_plist" ]; then
        launchctl load "$runtime_plist" || true
      fi
    }

    printf '==> Apple container system\n'
    if ! "$container_bin" system status; then
      if [ "$mode" = "verify" ]; then
        recover_container_system
        printf '\n==> Apple container system (after recovery)\n'
        "$container_bin" system status
      else
        exit 1
      fi
    fi

    printf '\n==> Builder container\n'
    "$container_bin" inspect "$container_name" 2>/dev/null || printf 'container %s not found\n' "$container_name"

    printf '\n==> SSH handshake\n'
    if /usr/bin/ssh -F "$ssh_config" -o BatchMode=yes -o ConnectTimeout=2 "$host_alias" true >/dev/null 2>&1; then
      printf 'ok\n'
    else
      printf 'failed\n'
      if [ "$mode" = "status" ]; then
        exit 1
      fi
    fi

    printf '\n==> Remote store ping\n'
    if [ "$mode" = "verify" ]; then
      /usr/bin/ssh -F "$ssh_config" -o BatchMode=yes "$host_alias" 'nix store ping --store https://cache.nixos.org'
      nix store ping --store ${escapeShellArg "${cfg.protocol}://${cfg.hostAlias}"}
      printf '\ncontainer-builder verification succeeded\n'
    else
      nix store ping --store ${escapeShellArg "${cfg.protocol}://${cfg.hostAlias}"} || true
    fi
  '';

  runtimeScript = pkgs.writeShellScript "container-builder-runtime" ''
    set -euo pipefail

    workdir=${escapeShellArg workDir}
    log_file=${escapeShellArg runtimeLogPath}
    readiness_log=${escapeShellArg readinessLogPath}
    runtime_plist="$HOME/Library/LaunchAgents/org.nixos.container-builder-runtime.plist"

    mkdir -p "$workdir"
    exec >> "$log_file" 2>&1

    echo "[$(/bin/date)] ensuring container builder runtime"

    ${bootstrapKeysScript}

    if ! ${escapeShellArg cfg.containerBinary} system status >/dev/null 2>&1; then
      echo "[$(/bin/date)] Apple container system is unhealthy; attempting recovery"

      if [ -f "$runtime_plist" ]; then
        launchctl unload "$runtime_plist" || true
      fi

      if ! ${escapeShellArg cfg.containerBinary} system start --enable-kernel-install; then
        echo "[$(/bin/date)] Apple container recovery failed; runtime agent unloaded to avoid crash loop" >&2
        exit 0
      fi
    fi

    ${escapeShellArg cfg.containerBinary} system start || true

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
      BatchMode yes
      StrictHostKeyChecking no
      UserKnownHostsFile /dev/null
      LogLevel ERROR
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
      default = "ghcr.io/robertderose/nix-apple-container-builder:builder-latest";
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

    system.activationScripts.extraActivation.text = mkAfter ''
      if [ ! -x ${escapeShellArg containerExecutable} ] || ! ${escapeShellArg containerExecutable} --version 2>/dev/null | /usr/bin/grep -q ${escapeShellArg cfg.installer.version}; then
        echo "installing Apple container ${cfg.installer.version} from official pkg..." >&2
        /usr/sbin/installer -pkg ${escapeShellArg containerInstallerPkg} -target /
      fi

      ${pkgs.coreutils}/bin/mkdir -p ${escapeShellArg workDir}
      ${pkgs.coreutils}/bin/mkdir -p ${escapeShellArg cacheDir}
      /usr/sbin/chown ${escapeShellArg owner}:staff ${escapeShellArg workDir}
      /usr/sbin/chown ${escapeShellArg owner}:staff ${escapeShellArg cacheDir}
      /bin/chmod 0700 ${escapeShellArg workDir}
      /bin/chmod 0700 ${escapeShellArg cacheDir}
      ${pkgs.coreutils}/bin/install -m 0755 ${bootstrapKeysScript} ${escapeShellArg "${workDir}/bootstrap-keys.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${initScript} ${escapeShellArg "${workDir}/init.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${proxyScript} ${escapeShellArg "${workDir}/proxy.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${startScript} ${escapeShellArg "${workDir}/start-container.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${stopScript} ${escapeShellArg "${workDir}/stop-container.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${sshWrapperScript} ${escapeShellArg "${workDir}/ssh-wrapper.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${statusScript} /usr/local/bin/container-builder-status
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
