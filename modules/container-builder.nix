{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.services.container-builder;
  runtimeVersions = import ./runtime-versions.nix;
  owner = cfg.user;

  workDir = cfg.workingDirectory;
  containerExecutable = "/usr/local/bin/container";
  hostContainerInternalDomain = "host.container.internal";
  hostContainerInternalLoopback = "203.0.113.113";
  socktainerAgentName = "hexbox-socktainer";
  socktainerAgentLabel = "org.nixos.${socktainerAgentName}";
  socktainerStateDirectory = "${cfg.socktainer.homeDirectory}/.socktainer";
  socktainerSocketPath = "${socktainerStateDirectory}/container.sock";
  socktainerApiUrl = "http://localhost/_ping";
  sshKeyPath = "${workDir}/builder_ed25519";
  hostKeyPath = "${workDir}/ssh_host_ed25519_key";
  knownHostsPath = "${workDir}/known_hosts";
  readinessLogPath = "${workDir}/hexbox-readiness.log";
  idleLogPath = "${workDir}/hexbox-idle.log";
  machineName = cfg.containerName;
  builderImageTag = "${cfg.imageRepository}:${cfg.nixVersion}";
  remoteStore = "${cfg.protocol}://${cfg.hostAlias}";

  containerInstallerPkg = pkgs.fetchurl {
    url = cfg.installer.url;
    hash = cfg.installer.hash;
  };

  socktainerInstallerPkg = pkgs.fetchurl {
    url = cfg.socktainer.installer.url;
    hash = cfg.socktainer.installer.hash;
  };

  reconcileHostContainerInternalScript = pkgs.writeShellScript "hexbox-reconcile-host-container-internal" ''
    set -euo pipefail

    if [ "$(/usr/bin/id -u)" -ne 0 ]; then
      echo "must run as root" >&2
      exit 1
    fi

    if ${boolToString cfg.exposeHostContainerInternal}; then
      if ${escapeShellArg cfg.containerBinary} system dns list 2>/dev/null | /usr/bin/grep -qx ${escapeShellArg hostContainerInternalDomain}; then
        echo "Apple container DNS entry already present for ${hostContainerInternalDomain}" >&2
      else
        echo "creating Apple container DNS entry for ${hostContainerInternalDomain}" >&2
        ${escapeShellArg cfg.containerBinary} system dns create ${escapeShellArg hostContainerInternalDomain} --localhost ${escapeShellArg hostContainerInternalLoopback}
      fi
    elif ${escapeShellArg cfg.containerBinary} system dns list 2>/dev/null | /usr/bin/grep -qx ${escapeShellArg hostContainerInternalDomain}; then
      echo "removing Apple container DNS entry for ${hostContainerInternalDomain}" >&2
      ${escapeShellArg cfg.containerBinary} system dns delete ${escapeShellArg hostContainerInternalDomain}
    fi
  '';

  bootstrapKeysScript = pkgs.writeShellScript "hexbox-bootstrap-keys" ''
    set -euo pipefail

    workdir=${escapeShellArg workDir}
    known_hosts_path=${escapeShellArg knownHostsPath}
    mkdir -p "$workdir"

    if [ ! -f "$workdir/builder_ed25519" ]; then
      /usr/bin/ssh-keygen -t ed25519 -f "$workdir/builder_ed25519" -N "" -C ${escapeShellArg cfg.hostAlias}
    fi

    if [ ! -f "$workdir/ssh_host_ed25519_key" ]; then
      /usr/bin/ssh-keygen -t ed25519 -f "$workdir/ssh_host_ed25519_key" -N "" -C ${escapeShellArg "${machineName}-host"}
    fi

    if [ -f "$workdir/ssh_host_ed25519_key.pub" ]; then
      host_key=$(/usr/bin/cut -d ' ' -f 1-2 "$workdir/ssh_host_ed25519_key.pub")
      /bin/cat > "$known_hosts_path" <<EOF
    ${cfg.hostAlias},nix-builder,${machineName} $host_key
    EOF
      /bin/chmod 0644 "$known_hosts_path"
    fi
  '';

  builderImageContainerfile = pkgs.writeText "hexbox-builder-Containerfile" ''
    FROM alpine:3.22

    RUN apk add --no-cache \
          bash \
          ca-certificates \
          coreutils \
          curl \
          findutils \
          gcompat \
          iproute2 \
          netcat-openbsd \
          openssh-client \
          openssh-server \
          procps \
          shadow \
          sudo \
          tar \
          xz

    SHELL ["/bin/bash", "-o", "pipefail", "-c"]

    RUN curl -sSf -L https://install.lix.systems/lix | sh -s -- install linux --no-confirm --init none

    RUN mkdir -p /etc/hexbox /etc/machine /run/sshd /usr/local/bin /var/empty && \
        adduser -D -s /bin/bash builder && \
        passwd -d builder

    RUN cat > /etc/machine/create-user.sh <<'EOF'
    #!/bin/sh
    set -eu
    group_name=$(getent group "$CONTAINER_GID" | cut -d: -f1 || true)
    if [ -z "$group_name" ]; then
      group_name="$CONTAINER_USER"
      addgroup -g "$CONTAINER_GID" "$group_name"
    fi
    if ! id "$CONTAINER_USER" >/dev/null 2>&1; then
      adduser -D -u "$CONTAINER_UID" -G "$group_name" -h "/home/$CONTAINER_USER" -s /bin/bash "$CONTAINER_USER"
      passwd -d "$CONTAINER_USER" >/dev/null 2>&1 || true
    fi
    EOF
    RUN chmod 0755 /etc/machine/create-user.sh

    RUN cat > /usr/local/bin/hexbox-nix-daemon <<'EOF'
    #!/bin/sh
    set -eu
    if [ "$(id -u)" -eq 0 ]; then
      exec /nix/var/nix/profiles/default/bin/nix-daemon "$@"
    fi
    exec sudo -n /nix/var/nix/profiles/default/bin/nix-daemon "$@"
    EOF
    RUN chmod 0755 /usr/local/bin/hexbox-nix-daemon && \
        ln -sf /usr/local/bin/hexbox-nix-daemon /usr/local/bin/nix-daemon

    RUN cat > /usr/local/bin/hexbox-idle-watchdog <<'EOF'
    #!/bin/sh
    set -eu
    timeout_seconds=300
    if [ -f /etc/hexbox/idle-timeout-seconds ]; then
      timeout_seconds=$(cat /etc/hexbox/idle-timeout-seconds)
    fi
    interval_seconds=30
    idle_seconds=0
    log_file=/var/log/hexbox-idle.log
    touch "$log_file"
    exec >> "$log_file" 2>&1
    echo "[$(date)] idle watchdog started timeout=$timeout_seconds"

    while true; do
      sleep "$interval_seconds"
      if ss -H -tn state established '( sport = :22 )' 2>/dev/null | grep -q .; then
        idle_seconds=0
        echo "[$(date)] active ssh connection detected"
        continue
      fi
      idle_seconds=$((idle_seconds + interval_seconds))
      echo "[$(date)] idle=$idle_seconds"
      if [ "$idle_seconds" -ge "$timeout_seconds" ]; then
        echo "[$(date)] idle timeout reached; stopping sshd"
        sshd_pid=$(cat /run/sshd/sshd.pid 2>/dev/null || true)
        if [ -n "$sshd_pid" ] && kill -0 "$sshd_pid" 2>/dev/null; then
          kill -TERM "$sshd_pid"
        fi
        exit 0
      fi
    done
    EOF
    RUN chmod 0755 /usr/local/bin/hexbox-idle-watchdog

    RUN rm -f /sbin/init
    RUN cat > /sbin/init <<'EOF'
    #!/bin/sh
    set -eu
    mkdir -p /run/sshd /var/empty /var/log
    ssh-keygen -A >/dev/null 2>&1 || true
    /nix/var/nix/profiles/default/bin/nix-daemon >/var/log/nix-daemon.log 2>&1 &
    if [ "$(cat /etc/hexbox/idle-enable 2>/dev/null || echo true)" = true ]; then
      /usr/local/bin/hexbox-idle-watchdog &
    fi
    exec /usr/sbin/sshd -D -e
    EOF
    RUN chmod 0755 /sbin/init
  '';

  machineBootstrapScript = pkgs.writeShellScript "hexbox-bootstrap-machine" ''
    set -euo pipefail

    container_bin=${escapeShellArg cfg.containerBinary}
    machine_name=${escapeShellArg machineName}
    workdir=${escapeShellArg workDir}
    timeout_seconds=${escapeShellArg (toString cfg.idleShutdown.timeoutSeconds)}
    idle_enable=${boolToString cfg.idleShutdown.enable}

    if [ ! -f "$workdir/builder_ed25519.pub" ] || [ ! -f "$workdir/ssh_host_ed25519_key" ]; then
      echo "container-builder keys missing in $workdir; run $workdir/bootstrap-keys.sh first" >&2
      exit 1
    fi

    auth_key_b64=$(/usr/bin/base64 < "$workdir/builder_ed25519.pub" | /usr/bin/tr -d '\n')
    host_key_b64=$(/usr/bin/base64 < "$workdir/ssh_host_ed25519_key" | /usr/bin/tr -d '\n')
    host_key_pub_b64=$(/usr/bin/base64 < "$workdir/ssh_host_ed25519_key.pub" | /usr/bin/tr -d '\n')

    "$container_bin" machine run -i -n "$machine_name" --root -- /bin/bash -s <<EOF
    set -euo pipefail

    mkdir -p /etc/hexbox /etc/nix /etc/ssh /home/${cfg.sshUser}/.ssh /run/sshd /var/log
    printf '%s' '$auth_key_b64' | base64 -d > /home/${cfg.sshUser}/.ssh/authorized_keys
    printf '%s' '$host_key_b64' | base64 -d > /etc/ssh/ssh_host_ed25519_key
    printf '%s' '$host_key_pub_b64' | base64 -d > /etc/ssh/ssh_host_ed25519_key.pub
    chmod 0700 /home/${cfg.sshUser}/.ssh
    chmod 0600 /home/${cfg.sshUser}/.ssh/authorized_keys /etc/ssh/ssh_host_ed25519_key
    chown -R ${cfg.sshUser}:${cfg.sshUser} /home/${cfg.sshUser}/.ssh
    passwd -d ${cfg.sshUser} >/dev/null 2>&1 || true

    cat > /etc/nix/nix.conf <<'NIXCONF'
    trusted-users = root ${cfg.sshUser}
    experimental-features = nix-command flakes
    build-users-group =
    substituters = https://cache.nixos.org/
    trusted-substituters = https://cache.nixos.org/
    trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
    narinfo-cache-positive-ttl = 3600
    narinfo-cache-negative-ttl = 60
    NIXCONF

    cat > /etc/sudoers.d/hexbox-builder <<'SUDOERS'
    ${cfg.sshUser} ALL=(root) NOPASSWD: /nix/var/nix/profiles/default/bin/nix-daemon *
    SUDOERS
    chmod 0440 /etc/sudoers.d/hexbox-builder

    cat > /etc/ssh/sshd_config <<'SSHCONF'
    Port ${toString cfg.containerPort}
    ListenAddress 0.0.0.0
    HostKey /etc/ssh/ssh_host_ed25519_key
    PermitRootLogin no
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    X11Forwarding no
    AllowTcpForwarding yes
    PrintMotd no
    SetEnv PATH=/usr/local/sbin:/usr/local/bin:/nix/var/nix/profiles/default/bin:/usr/sbin:/usr/bin:/sbin:/bin
    Subsystem sftp internal-sftp
    MaxStartups 64:30:128
    MaxSessions 64
    SSHCONF

    printf '%s\n' '$timeout_seconds' > /etc/hexbox/idle-timeout-seconds

    printf '%s\n' '$idle_enable' > /etc/hexbox/idle-enable
    EOF
  '';

  startScript = pkgs.writeShellScript "hexbox-start-machine" ''
    set -euo pipefail

    if [ "$(/usr/bin/id -un)" != ${escapeShellArg owner} ]; then
      exec /usr/bin/sudo -n -u ${escapeShellArg owner} -H "$0"
    fi

    container_bin=${escapeShellArg cfg.containerBinary}
    machine_name=${escapeShellArg machineName}
    image_tag=${escapeShellArg builderImageTag}
    image_dir=${escapeShellArg "${workDir}/builder-image"}
    bootstrap_machine=${escapeShellArg machineBootstrapScript}

    if ! "$container_bin" system status >/dev/null 2>&1; then
      echo "Apple container system unhealthy; attempting recovery" >&2
      "$container_bin" system start --enable-kernel-install >/dev/null
    else
      "$container_bin" system start >/dev/null 2>&1 || true
    fi

    if ! "$container_bin" image inspect "$image_tag" >/dev/null 2>&1; then
      echo "building HexBox machine image $image_tag" >&2
      "$container_bin" build --pull --progress plain -t "$image_tag" "$image_dir"
    fi

    if ! "$container_bin" machine inspect "$machine_name" >/dev/null 2>&1; then
      echo "creating HexBox container machine $machine_name" >&2
      "$container_bin" machine create "$image_tag" \
        --name "$machine_name" \
        --cpus ${escapeShellArg (toString cfg.cpus)} \
        --memory ${escapeShellArg cfg.memory} \
        --home-mount ${escapeShellArg cfg.homeMount}
      "$bootstrap_machine"
      "$container_bin" machine stop "$machine_name" >/dev/null 2>&1 || true
      "$container_bin" machine run -n "$machine_name" --root -- true >/dev/null
    else
      "$container_bin" machine set -n "$machine_name" \
        cpus=${escapeShellArg (toString cfg.cpus)} \
        memory=${escapeShellArg cfg.memory} \
        home-mount=${escapeShellArg cfg.homeMount} >/dev/null
      "$container_bin" machine run -n "$machine_name" --root -- true >/dev/null
      "$bootstrap_machine"
      "$container_bin" machine stop "$machine_name" >/dev/null 2>&1 || true
      "$container_bin" machine run -n "$machine_name" --root -- true >/dev/null
    fi
  '';

  stopScript = pkgs.writeShellScript "hexbox-stop-machine" ''
    set -euo pipefail
    if [ "$(/usr/bin/id -un)" != ${escapeShellArg owner} ]; then
      exec /usr/bin/sudo -n -u ${escapeShellArg owner} -H "$0"
    fi
    exec ${escapeShellArg cfg.containerBinary} machine stop ${escapeShellArg machineName}
  '';

  resetScript = pkgs.writeShellScript "hexbox-reset-machine" ''
    set -euo pipefail
    if [ "$(/usr/bin/id -un)" != ${escapeShellArg owner} ]; then
      exec /usr/bin/sudo -n -u ${escapeShellArg owner} -H "$0"
    fi
    ${escapeShellArg cfg.containerBinary} machine rm ${escapeShellArg machineName} >/dev/null 2>&1 || true
    exec ${escapeShellArg "${workDir}/start-container.sh"}
  '';

  proxyScript = pkgs.writeShellScript "hexbox-machine-proxy" ''
    set -euo pipefail

    if [ "$(/usr/bin/id -un)" != ${escapeShellArg owner} ]; then
      exec /usr/bin/sudo -n -u ${escapeShellArg owner} -H /bin/sh -lc 'exec "$0"' "$0"
    fi

    ${escapeShellArg "${workDir}/start-container.sh"} >/dev/null 2>&1 || true
    exec ${escapeShellArg cfg.containerBinary} machine run -i -n ${escapeShellArg machineName} --root -- /usr/bin/nc 127.0.0.1 ${toString cfg.containerPort}
  '';

  readinessScript = pkgs.writeShellScript "hexbox-readiness" ''
    set -euo pipefail

    host_alias=${escapeShellArg cfg.hostAlias}
    ssh_config=${escapeShellArg "${workDir}/ssh_config_root"}
    timeout_seconds=${escapeShellArg (toString cfg.readiness.timeoutSeconds)}
    interval_seconds=${escapeShellArg (toString cfg.readiness.intervalSeconds)}
    deadline=$(( $(/bin/date +%s) + timeout_seconds ))

    echo "[$(/bin/date)] waiting for SSH readiness on $host_alias" >> ${escapeShellArg readinessLogPath}

    while [ "$(( $(/bin/date +%s) ))" -lt "$deadline" ]; do
      if /usr/bin/ssh -F "$ssh_config" -o BatchMode=yes -o ConnectTimeout=2 "$host_alias" true >/dev/null 2>&1; then
        echo "[$(/bin/date)] SSH is ready on $host_alias" >> ${escapeShellArg readinessLogPath}
        exit 0
      fi

      /bin/sleep "$interval_seconds"
    done

    echo "[$(/bin/date)] timed out waiting for SSH readiness on $host_alias" >> ${escapeShellArg readinessLogPath}
    exit 1
  '';

  socktainerHealthScript = pkgs.writeShellScript "hexbox-socktainer-health" ''
    set -euo pipefail

    socket_path=${escapeShellArg socktainerSocketPath}

    if [ ! -S "$socket_path" ]; then
      echo "socktainer socket not found: $socket_path" >&2
      exit 1
    fi

    exec /usr/bin/curl --silent --show-error --fail --unix-socket "$socket_path" ${escapeShellArg socktainerApiUrl}
  '';

  socktainerLaunchScript = pkgs.writeShellScript "hexbox-socktainer" ''
    set -euo pipefail

    export HOME=${escapeShellArg cfg.socktainer.homeDirectory}
    ${pkgs.coreutils}/bin/mkdir -p ${escapeShellArg socktainerStateDirectory}
    exec ${escapeShellArg cfg.socktainer.binary} --no-check-compatibility
  '';

  userSshConfig = pkgs.writeText "container-builder-ssh-config" ''
    Host nix-builder
      HostName ${machineName}
      User ${cfg.sshUser}
      IdentityFile ${sshKeyPath}
      ProxyCommand ${proxyScript}
      BatchMode yes
      StrictHostKeyChecking yes
      UserKnownHostsFile ${knownHostsPath}
      LogLevel ERROR

    Host ${cfg.hostAlias}
      HostName ${machineName}
      User ${cfg.sshUser}
      IdentityFile ${sshKeyPath}
      ProxyCommand ${proxyScript}
      BatchMode yes
      StrictHostKeyChecking yes
      UserKnownHostsFile ${knownHostsPath}
      LogLevel ERROR
  '';

  rootSshConfig = userSshConfig;

  sshWrapperScript = pkgs.writeShellScript "container-builder-ssh-wrapper" ''
    exec ssh -F ${escapeShellArg "${workDir}/ssh_config"} "$@"
  '';

  helperScript = pkgs.writeShellScript "hb" ''
    set -euo pipefail

    export HB_HOST_ALIAS=${escapeShellArg cfg.hostAlias}
    export HB_SSH_CONFIG=${escapeShellArg "${workDir}/ssh_config_root"}
    export HB_CONTAINER_BIN=${escapeShellArg cfg.containerBinary}
    export HB_CONTAINER_NAME=${escapeShellArg machineName}
    export HB_RECONCILE_HOST_CONTAINER_INTERNAL=${escapeShellArg "${workDir}/reconcile-host-container-internal.sh"}
    export HB_SOCKTAINER_ENABLED=${boolToString cfg.socktainer.enable}
    export HB_SOCKTAINER_AGENT_LABEL=${escapeShellArg socktainerAgentLabel}
    export HB_SOCKTAINER_SOCKET=${escapeShellArg socktainerSocketPath}
    export HB_SOCKTAINER_HEALTH=${escapeShellArg socktainerHealthScript}
    export HB_SOCKTAINER_ERR_LOG=${escapeShellArg "${socktainerStateDirectory}/socktainer.err.log"}
    export HB_SOCKTAINER_OUT_LOG=${escapeShellArg "${socktainerStateDirectory}/socktainer.out.log"}
    export HB_READINESS_LOG=${escapeShellArg readinessLogPath}
    export HB_IDLE_LOG=${escapeShellArg idleLogPath}
    export HB_REMOTE_STORE=${escapeShellArg remoteStore}
    export HB_START_SCRIPT=${escapeShellArg startScript}
    export HB_STOP_SCRIPT=${escapeShellArg stopScript}
    export HB_RESET_SCRIPT=${escapeShellArg resetScript}
    export HB_READINESS_SCRIPT=${escapeShellArg readinessScript}
    export HB_EXPOSE_HOST_CONTAINER_INTERNAL=${boolToString cfg.exposeHostContainerInternal}

    exec ${escapeShellArg ./../assets/hb.sh} "$@"
  '';

  completionPackage = pkgs.stdenvNoCC.mkDerivation {
    pname = "hb-completions";
    version = "1";
    dontUnpack = true;
    nativeBuildInputs = [
      pkgs.installShellFiles
    ];
    installPhase = ''
      runHook preInstall
      installShellCompletion \
        --bash --name hb ${./../assets/completions/hb.bash} \
        --zsh --name _hb ${./../assets/completions/hb.zsh} \
        --fish --name hb.fish ${./../assets/completions/hb.fish}
      runHook postInstall
    '';
  };
in
{
  options.services.container-builder = {
    enable = mkEnableOption "Apple container-machine Linux remote builder";

    hostAlias = mkOption {
      type = types.str;
      default = "container-builder";
      description = "SSH host alias used by Nix for the remote builder.";
    };

    sshUser = mkOption {
      type = types.str;
      default = "builder";
      description = "User Nix connects to over SSH inside the container machine.";
    };

    workingDirectory = mkOption {
      type = types.str;
      default = "/Users/${owner}/.local/state/hb";
      description = "Directory holding persistent builder state such as keys, generated helper scripts, image sources, and logs.";
    };

    user = mkOption {
      type = types.str;
      default = config.system.primaryUser;
      defaultText = literalExpression "config.system.primaryUser";
      description = "Primary macOS user that owns the Apple container runtime and builder state directory.";
    };

    containerBinary = mkOption {
      type = types.str;
      default = containerExecutable;
      description = "Path to Apple's container CLI binary installed by the official pkg.";
    };

    installer.url = mkOption {
      type = types.str;
      default = runtimeVersions.appleContainer.url;
      description = "Official Apple container installer package URL.";
    };

    installer.hash = mkOption {
      type = types.str;
      default = runtimeVersions.appleContainer.hash;
      description = "Hash of the Apple container installer package.";
    };

    installer.version = mkOption {
      type = types.str;
      default = runtimeVersions.appleContainer.version;
      description = "Expected `container --version` string suffix used for activation checks.";
    };

    containerName = mkOption {
      type = types.str;
      default = "nix-builder";
      description = "Name of the Apple container machine used for Linux builds.";
    };

    imageRepository = mkOption {
      type = types.str;
      default = runtimeVersions.builderImage.repository;
      description = "OCI repository or local image name used for the Linux builder container machine image.";
    };

    nixVersion = mkOption {
      type = types.str;
      default = runtimeVersions.builderImage.version;
      description = "Version tag of the HexBox builder image. For the default local image this also controls when `container build` rebuilds the image.";
    };

    cpus = mkOption {
      type = types.ints.positive;
      default = 4;
      description = "CPU count assigned to the container machine.";
    };

    memory = mkOption {
      type = types.str;
      default = "1G";
      description = "Memory value assigned to the container machine.";
    };

    homeMount = mkOption {
      type = types.enum [
        "none"
        "ro"
        "rw"
      ];
      default = "none";
      description = "Apple container machine home mount mode. The builder defaults to no host home mount.";
    };

    containerPort = mkOption {
      type = types.port;
      default = 22;
      description = "SSH port listened to inside the container machine.";
    };

    exposeHostContainerInternal = mkOption {
      type = types.bool;
      default = true;
      description = "Expose `host.container.internal` to Apple containers by ensuring the `container system dns` entry exists during activation.";
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
      description = "Nix builder features advertised for the container-machine builder.";
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

    readiness.timeoutSeconds = mkOption {
      type = types.ints.positive;
      default = 60;
      description = "How long startup waits for the builder SSH service to become reachable.";
    };

    readiness.intervalSeconds = mkOption {
      type = types.ints.positive;
      default = 1;
      description = "Polling interval for builder SSH readiness checks.";
    };

    idleShutdown.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Stop the builder machine automatically after a period with no SSH connections.";
    };

    idleShutdown.timeoutSeconds = mkOption {
      type = types.ints.positive;
      default = 300;
      description = "How long the builder may remain idle before the guest powers itself off.";
    };

    cli.completions.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Install opt-in bash, zsh, and fish completion files for `hb` into the standard Nix-managed shell completion directories.";
    };

    socktainer.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Install and manage Socktainer as an optional Docker API compatibility layer on top of Apple container.";
    };

    socktainer.binary = mkOption {
      type = types.str;
      default = "/opt/socktainer/bin/socktainer";
      description = "Path to the Socktainer binary installed by its official pkg.";
    };

    socktainer.homeDirectory = mkOption {
      type = types.str;
      default = "/Users/${owner}";
      description = "macOS home directory used when launching Socktainer; Socktainer stores its socket and logs under `$HOME/.socktainer`.";
    };

    socktainer.setDockerHost = mkOption {
      type = types.bool;
      default = false;
      description = "Export `DOCKER_HOST` in the user session environment so Docker-compatible clients use Socktainer by default.";
    };

    socktainer.installer.url = mkOption {
      type = types.str;
      default = runtimeVersions.socktainer.url;
      description = "Official Socktainer installer package URL.";
    };

    socktainer.installer.hash = mkOption {
      type = types.str;
      default = runtimeVersions.socktainer.hash;
      description = "Hash of the Socktainer installer package.";
    };

    socktainer.installer.version = mkOption {
      type = types.str;
      default = runtimeVersions.socktainer.version;
      description = "Expected Socktainer release version used for activation checks.";
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
    ]
    ++ optional cfg.cli.completions.enable completionPackage;

    environment.variables = mkIf (cfg.socktainer.enable && cfg.socktainer.setDockerHost) {
      DOCKER_HOST = "unix://${socktainerSocketPath}";
    };

    environment.etc."ssh/ssh_config.d/201-container-builder.conf".source = rootSshConfig;

    system.activationScripts.extraActivation.text = mkAfter ''
      if [ ! -x ${escapeShellArg containerExecutable} ] || ! ${escapeShellArg containerExecutable} --version 2>/dev/null | /usr/bin/grep -q ${escapeShellArg cfg.installer.version}; then
        echo "installing Apple container ${cfg.installer.version} from official pkg..." >&2
        /usr/sbin/installer -pkg ${escapeShellArg containerInstallerPkg} -target /
      fi

      ${optionalString cfg.socktainer.enable ''
        if [ ! -x ${escapeShellArg cfg.socktainer.binary} ] || ! ${escapeShellArg cfg.socktainer.binary} --version 2>/dev/null | /usr/bin/grep -q ${escapeShellArg cfg.socktainer.installer.version}; then
          echo "installing Socktainer ${cfg.socktainer.installer.version} from official pkg..." >&2
          /usr/sbin/installer -pkg ${escapeShellArg socktainerInstallerPkg} -target /
        fi
      ''}

      if ${escapeShellArg cfg.containerBinary} system status >/dev/null 2>&1; then
        ${reconcileHostContainerInternalScript}
      else
        echo "warning: Apple container system is not running; skipping ${hostContainerInternalDomain} DNS reconciliation" >&2
      fi

      ${pkgs.coreutils}/bin/mkdir -p ${escapeShellArg workDir} ${escapeShellArg "${workDir}/builder-image"}
      /usr/sbin/chown ${escapeShellArg owner}:staff ${escapeShellArg workDir} ${escapeShellArg "${workDir}/builder-image"}
      /bin/chmod 0700 ${escapeShellArg workDir}
      ${pkgs.coreutils}/bin/install -m 0644 ${builderImageContainerfile} ${escapeShellArg "${workDir}/builder-image/Containerfile"}
      ${pkgs.coreutils}/bin/install -m 0755 ${bootstrapKeysScript} ${escapeShellArg "${workDir}/bootstrap-keys.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${machineBootstrapScript} ${escapeShellArg "${workDir}/bootstrap-machine.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${proxyScript} ${escapeShellArg "${workDir}/proxy.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${startScript} ${escapeShellArg "${workDir}/start-container.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${stopScript} ${escapeShellArg "${workDir}/stop-container.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${resetScript} ${escapeShellArg "${workDir}/reset-container.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${reconcileHostContainerInternalScript} ${escapeShellArg "${workDir}/reconcile-host-container-internal.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${socktainerLaunchScript} ${escapeShellArg "${workDir}/socktainer.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${sshWrapperScript} ${escapeShellArg "${workDir}/ssh-wrapper.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${helperScript} /usr/local/bin/hb
      ${pkgs.coreutils}/bin/install -m 0644 ${userSshConfig} ${escapeShellArg "${workDir}/ssh_config"}
      ${pkgs.coreutils}/bin/install -m 0644 ${rootSshConfig} ${escapeShellArg "${workDir}/ssh_config_root"}
      : > ${escapeShellArg knownHostsPath}
      /bin/chmod 0644 ${escapeShellArg knownHostsPath}
      if [ -e ${escapeShellArg "${hostKeyPath}.pub"} ]; then
        host_key=$(${pkgs.coreutils}/bin/cut -d ' ' -f 1-2 ${escapeShellArg "${hostKeyPath}.pub"})
        /bin/cat > ${escapeShellArg knownHostsPath} <<EOF
      ${cfg.hostAlias},nix-builder,${machineName} $host_key
      EOF
      fi
      /usr/sbin/chown -R ${escapeShellArg owner}:staff ${escapeShellArg workDir}

      ${optionalString cfg.socktainer.enable ''
        ${pkgs.coreutils}/bin/mkdir -p ${escapeShellArg socktainerStateDirectory}
        /usr/sbin/chown ${escapeShellArg owner}:staff ${escapeShellArg socktainerStateDirectory}
      ''}

      if [ ! -e ${escapeShellArg sshKeyPath} ] || [ ! -e ${escapeShellArg "${sshKeyPath}.pub"} ] || [ ! -e ${escapeShellArg hostKeyPath} ] || [ ! -e ${escapeShellArg "${hostKeyPath}.pub"} ]; then
        echo "warning: container-builder keys are missing in ${workDir}; run ${workDir}/bootstrap-keys.sh" >&2
      fi
    '';

    launchd.user.agents."${socktainerAgentName}" = mkIf cfg.socktainer.enable {
      serviceConfig = {
        KeepAlive = true;
        RunAtLoad = true;
        ProgramArguments = [ "${workDir}/socktainer.sh" ];
        StandardErrorPath = "${socktainerStateDirectory}/socktainer.err.log";
        StandardOutPath = "${socktainerStateDirectory}/socktainer.out.log";
        WorkingDirectory = socktainerStateDirectory;
      };
      managedBy = "services.container-builder.socktainer.enable";
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
