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
  knownHostsAliases = concatStringsSep "," [
    cfg.hostAlias
    "nix-builder"
    machineName
    "[${cfg.hostAlias}]:${toString cfg.containerPort}"
    "[nix-builder]:${toString cfg.containerPort}"
    "[${machineName}]:${toString cfg.containerPort}"
  ];
  readinessLogPath = "${workDir}/hexbox-readiness.log";
  machineName = cfg.containerName;
  builderImageTag = "${cfg.imageRepository}:${cfg.nixVersion}";
  bootstrapVersion = builtins.hashString "sha256" (
    builtins.toJSON {
      recipeVersion = "2026-06-26-machine-bootstrap-v4";
      sshUser = cfg.sshUser;
      containerPort = cfg.containerPort;
      idleShutdownEnable = cfg.idleShutdown.enable;
      idleShutdownTimeoutSeconds = cfg.idleShutdown.timeoutSeconds;
      hostAlias = cfg.hostAlias;
    }
  );
  hasCustomImageContainerfile = cfg.imageContainerfile != null;
  customImageBuildContext =
    if cfg.imageBuildContext != null then cfg.imageBuildContext else "${workDir}/builder-image/context";
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
      /usr/bin/printf '%s %s\n' ${escapeShellArg knownHostsAliases} "$host_key" > "$known_hosts_path"
      /bin/chmod 0644 "$known_hosts_path"
    fi
  '';

  idleWatchdogScript = pkgs.writeShellScript "hexbox-idle-watchdog" ''
    set -eu
    ssh_port=${escapeShellArg (toString cfg.containerPort)}
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

    if ! command -v ss >/dev/null 2>&1; then
      echo "[$(date)] ss not found; idle watchdog disabled"
      exit 0
    fi

    while true; do
      sleep "$interval_seconds"
      if ss -H -tn state established "( sport = :$ssh_port )" 2>/dev/null | grep -q .; then
        idle_seconds=0
        echo "[$(date)] active ssh connection detected"
        continue
      fi
      idle_seconds=$((idle_seconds + interval_seconds))
      echo "[$(date)] idle=$idle_seconds"
      if [ "$idle_seconds" -ge "$timeout_seconds" ]; then
        echo "[$(date)] idle timeout reached; stopping machine"
        kill -TERM 1
        sleep 5
        kill -KILL 1 2>/dev/null || true
        exit 0
      fi
    done
  '';

  machineBootstrapScript = pkgs.writeShellScript "hexbox-bootstrap-machine" ''
    set -euo pipefail

    container_bin=${escapeShellArg cfg.containerBinary}
    machine_name=${escapeShellArg machineName}
    workdir=${escapeShellArg workDir}
    timeout_seconds=${escapeShellArg (toString cfg.idleShutdown.timeoutSeconds)}
    idle_enable=${boolToString cfg.idleShutdown.enable}
    /bin/mkdir -p "$workdir"
    cd "$workdir"

    if [ ! -f "$workdir/builder_ed25519.pub" ] || [ ! -f "$workdir/ssh_host_ed25519_key" ] || [ ! -f "$workdir/ssh_host_ed25519_key.pub" ]; then
      echo "container-builder keys missing in $workdir; run $workdir/bootstrap-keys.sh first" >&2
      exit 1
    fi

    if ! preflight_output=$({
      /usr/bin/printf '%s\n' \
        'command -v base64 >/dev/null 2>&1 || { echo "base64 is required inside the builder image for HexBox bootstrap" >&2; exit 1; }' \
        'command -v nc >/dev/null 2>&1 || { echo "nc is required inside the builder image for HexBox SSH proxy" >&2; exit 1; }' \
        'nc_probe=$(nc -N -h 2>&1 || true)' \
        'case "$nc_probe" in' \
        '  *"invalid option"* | *"illegal option"* | *"unrecognized option"* ) echo "OpenBSD nc with -N support is required inside the builder image for HexBox SSH proxy" >&2; exit 1 ;;' \
        '  * ) ;;' \
        'esac'
    } | "$container_bin" machine run --root -i -n "$machine_name" /bin/sh -s 2>&1); then
      echo "hexbox: failed to run bootstrap preflight in builder machine $machine_name" >&2
      echo "hexbox: container machine run output:" >&2
      printf '%s\n' "$preflight_output" >&2
      exit 1
    fi

    auth_key_b64=$(/usr/bin/base64 < "$workdir/builder_ed25519.pub" | /usr/bin/tr -d '\n')
    host_key_pub_b64=$(/usr/bin/base64 < "$workdir/ssh_host_ed25519_key.pub" | /usr/bin/tr -d '\n')
    watchdog_b64=$(/usr/bin/base64 < ${escapeShellArg idleWatchdogScript} | /usr/bin/tr -d '\n')
    if ! host_key_output=$({
      /bin/cat <<'HOST_KEY_TRANSFER'
    set -eu
    mkdir -p /nix/var/hexbox
    base64 -d > /nix/var/hexbox/ssh_host_ed25519_key <<'HOST_KEY_PAYLOAD'
    HOST_KEY_TRANSFER
      /usr/bin/base64 < "$workdir/ssh_host_ed25519_key"
      /usr/bin/printf '\nHOST_KEY_PAYLOAD\n'
    } | "$container_bin" machine run --root -i -n "$machine_name" /bin/sh -s 2>&1); then
      echo "hexbox: failed to transfer builder SSH host key into $machine_name" >&2
      echo "hexbox: container machine run output:" >&2
      printf '%s\n' "$host_key_output" >&2
      exit 1
    fi

    if ! bootstrap_output=$("$container_bin" machine run --root -i -n "$machine_name" /bin/sh -s "$auth_key_b64" "$host_key_pub_b64" "$watchdog_b64" "$timeout_seconds" "$idle_enable" <<'EOF'
    set -eu
    auth_key_b64=$1
    host_key_pub_b64=$2
    watchdog_b64=$3
    timeout_seconds=$4
    idle_enable=$5

    ssh_user=${escapeShellArg cfg.sshUser}
    ssh_shell=/bin/bash
    if [ ! -x "$ssh_shell" ]; then
      ssh_shell=/bin/sh
    fi

    if ! command -v base64 >/dev/null 2>&1; then
      echo "base64 is required inside the builder image for HexBox bootstrap" >&2
      exit 1
    fi

    if ! command -v getent >/dev/null 2>&1; then
      echo "getent is required inside the builder image for HexBox bootstrap" >&2
      exit 1
    fi

    mkdir -p /etc/hexbox /etc/nix /etc/ssh /etc/sudoers.d /nix/var/hexbox /run/sshd /usr/local/bin /var/log
    if ! getent group "$ssh_user" >/dev/null 2>&1; then
      if command -v addgroup >/dev/null 2>&1; then
        addgroup "$ssh_user"
      elif command -v groupadd >/dev/null 2>&1; then
        groupadd "$ssh_user"
      else
        echo "cannot create missing group: $ssh_user" >&2
        exit 1
      fi
    fi
    if ! id -u "$ssh_user" >/dev/null 2>&1; then
      if command -v adduser >/dev/null 2>&1; then
        adduser -D -G "$ssh_user" -s "$ssh_shell" "$ssh_user"
      elif command -v useradd >/dev/null 2>&1; then
        useradd -m -g "$ssh_user" -s "$ssh_shell" "$ssh_user"
      else
        echo "cannot create missing user: $ssh_user" >&2
        exit 1
      fi
    fi

    ssh_home=$(getent passwd "$ssh_user" | cut -d: -f6)
    if [ -z "$ssh_home" ]; then
      ssh_home="/home/$ssh_user"
    fi
    mkdir -p "$ssh_home/.ssh"
    printf '%s' "$auth_key_b64" | base64 -d > /nix/var/hexbox/authorized_keys
    if [ ! -s /nix/var/hexbox/ssh_host_ed25519_key ]; then
      echo "builder SSH host private key was not transferred" >&2
      exit 1
    fi
    printf '%s' "$host_key_pub_b64" | base64 -d > /nix/var/hexbox/ssh_host_ed25519_key.pub
    cp /nix/var/hexbox/authorized_keys "$ssh_home/.ssh/authorized_keys"
    cp /nix/var/hexbox/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key
    cp /nix/var/hexbox/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ed25519_key.pub
    chmod 0700 "$ssh_home/.ssh"
    chmod 0600 "$ssh_home/.ssh/authorized_keys" /etc/ssh/ssh_host_ed25519_key /nix/var/hexbox/ssh_host_ed25519_key
    chmod 0644 /nix/var/hexbox/authorized_keys /nix/var/hexbox/ssh_host_ed25519_key.pub
    chown -R "$ssh_user:$ssh_user" "$ssh_home/.ssh"
    passwd -d "$ssh_user" >/dev/null 2>&1 || true

    cat > /nix/var/hexbox/nix.conf <<'NIXCONF'
    trusted-users = root ${cfg.sshUser}
    experimental-features = nix-command flakes
    build-users-group =
    substituters = https://cache.nixos.org/
    trusted-substituters = https://cache.nixos.org/
    trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
    narinfo-cache-positive-ttl = 3600
    narinfo-cache-negative-ttl = 60
    NIXCONF
    cp /nix/var/hexbox/nix.conf /etc/nix/nix.conf

    cat > /nix/var/hexbox/hexbox-builder.sudoers <<'SUDOERS'
    ${cfg.sshUser} ALL=(root) NOPASSWD: /nix/var/nix/profiles/default/bin/nix-daemon --stdio
    SUDOERS
    cp /nix/var/hexbox/hexbox-builder.sudoers /etc/sudoers.d/hexbox-builder
    chmod 0440 /etc/sudoers.d/hexbox-builder /nix/var/hexbox/hexbox-builder.sudoers

    cat > /nix/var/hexbox/sshd_config <<'SSHCONF'
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
    cp /nix/var/hexbox/sshd_config /etc/ssh/sshd_config

    printf '%s' "$watchdog_b64" | base64 -d > /nix/var/hexbox/hexbox-idle-watchdog
    cp /nix/var/hexbox/hexbox-idle-watchdog /usr/local/bin/hexbox-idle-watchdog
    chmod 0755 /nix/var/hexbox/hexbox-idle-watchdog /usr/local/bin/hexbox-idle-watchdog

    printf '%s\n' "$timeout_seconds" > /nix/var/hexbox/idle-timeout-seconds
    printf '%s\n' "$idle_enable" > /nix/var/hexbox/idle-enable
    printf '%s\n' ${escapeShellArg bootstrapVersion} > /nix/var/hexbox/bootstrap-version
    cp /nix/var/hexbox/idle-timeout-seconds /etc/hexbox/idle-timeout-seconds
    cp /nix/var/hexbox/idle-enable /etc/hexbox/idle-enable
    cp /nix/var/hexbox/bootstrap-version /etc/hexbox/bootstrap-version

    if [ "$(ps -p 1 -o comm= 2>/dev/null || true)" = sshd ]; then
      kill -HUP 1 2>/dev/null || true
    fi
    EOF
    ); then
      echo "hexbox: failed to apply builder machine bootstrap to $machine_name" >&2
      echo "hexbox: container machine run output:" >&2
      printf '%s\n' "$bootstrap_output" >&2
      exit 1
    fi
  '';

  startScript = pkgs.writeShellScript "hexbox-start-machine" ''
    set -euo pipefail

    if [ "$(/usr/bin/id -un)" != ${escapeShellArg owner} ]; then
      exec /usr/bin/sudo -n -u ${escapeShellArg owner} -H "$0"
    fi

    lock_dir=${escapeShellArg "${workDir}/start.lock"}
    lock_pid_file="$lock_dir/pid"
    lock_stale_seconds=30
    while ! /bin/mkdir "$lock_dir" 2>/dev/null; do
      lock_pid=""
      if [ -f "$lock_pid_file" ]; then
        lock_pid="$(/bin/cat "$lock_pid_file" 2>/dev/null || true)"
      fi
      if [ -n "$lock_pid" ]; then
        if ! /bin/kill -0 "$lock_pid" 2>/dev/null; then
          /bin/rm -f "$lock_pid_file" 2>/dev/null || true
          /bin/rmdir "$lock_dir" 2>/dev/null || true
        fi
      else
        now=$(/bin/date +%s)
        lock_mtime=$(/usr/bin/stat -f %m "$lock_dir" 2>/dev/null || printf '%s\n' "$now")
        if [ $((now - lock_mtime)) -ge "$lock_stale_seconds" ]; then
          /bin/rmdir "$lock_dir" 2>/dev/null || true
        fi
      fi
      /bin/sleep 0.1
    done
    printf '%s\n' "$$" > "$lock_pid_file"
    trap '/bin/rm -f "$lock_pid_file" 2>/dev/null || true; /bin/rmdir "$lock_dir" 2>/dev/null || true' EXIT
    container_bin=${escapeShellArg cfg.containerBinary}
    machine_name=${escapeShellArg machineName}
    image_tag=${escapeShellArg builderImageTag}
    bootstrap_machine=${escapeShellArg machineBootstrapScript}
    bootstrap_version=${escapeShellArg bootstrapVersion}
    workdir=${escapeShellArg workDir}
    /bin/mkdir -p "$workdir"
    cd "$workdir"

    machine_status() {
      "$container_bin" machine inspect "$machine_name" 2>/dev/null | /usr/bin/awk -F'"' '/"status"/ { print $4; exit }'
    }

    machine_reaches_status() {
      desired_status=$1
      attempts=60
      while [ "$attempts" -gt 0 ]; do
        current_status=$(machine_status || true)
        if [ "$current_status" = "$desired_status" ]; then
          return 0
        fi
        attempts=$((attempts - 1))
        /bin/sleep 0.5
      done
      return 1
    }

    wait_machine_status() {
      desired_status=$1
      if machine_reaches_status "$desired_status"; then
        return 0
      fi
      echo "hexbox: builder machine $machine_name did not reach status $desired_status" >&2
      "$container_bin" machine inspect "$machine_name" >&2 || true
      exit 1
    }

    stop_machine() {
      attempts=60
      while [ "$attempts" -gt 0 ]; do
        current_status=$(machine_status || true)
        if [ "$current_status" = stopped ]; then
          return 0
        fi
        ${pkgs.coreutils}/bin/timeout 15 "$container_bin" machine stop "$machine_name" >/dev/null 2>&1 || true
        attempts=$((attempts - 1))
        /bin/sleep 0.5
      done
      echo "hexbox: builder machine $machine_name did not stop" >&2
      "$container_bin" machine inspect "$machine_name" >&2 || true
      exit 1
    }

    boot_machine() {
      if "$container_bin" machine inspect "$machine_name" 2>/dev/null | /usr/bin/grep -q '"status"[[:space:]]*:[[:space:]]*"running"'; then
        return 0
      fi
      attempts=3
      while [ "$attempts" -gt 0 ]; do
        if boot_output=$("$container_bin" machine run --root -d -n "$machine_name" /sbin/init 2>&1); then
          wait_machine_status running
          return 0
        fi
        attempts=$((attempts - 1))
        if [ "$attempts" -gt 0 ]; then
          ${pkgs.coreutils}/bin/timeout 15 "$container_bin" machine stop "$machine_name" >/dev/null 2>&1 || true
          /bin/sleep 2
        fi
      done
      echo "hexbox: failed to boot builder machine $machine_name" >&2
      echo "hexbox: container machine run output:" >&2
      printf '%s\n' "$boot_output" >&2
      exit 1
    }
    ${optionalString hasCustomImageContainerfile ''
      image_containerfile=${escapeShellArg "${workDir}/builder-image/Containerfile"}
      image_context=${escapeShellArg customImageBuildContext}
    ''}

    if ! "$container_bin" system status >/dev/null 2>&1; then
      echo "Apple container system unhealthy; attempting recovery" >&2
      "$container_bin" system start --enable-kernel-install >/dev/null
    else
      "$container_bin" system start >/dev/null 2>&1 || true
    fi

    ${optionalString hasCustomImageContainerfile ''
      if ! "$container_bin" image inspect "$image_tag" >/dev/null 2>&1; then
        echo "building custom HexBox machine image $image_tag" >&2
        "$container_bin" build --pull --progress plain -f "$image_containerfile" -t "$image_tag" "$image_context"
      fi
    ''}

    if ! "$container_bin" machine inspect "$machine_name" >/dev/null 2>&1; then
      echo "creating HexBox container machine $machine_name" >&2
      set +e
      create_output=$(${pkgs.coreutils}/bin/timeout 60 "$container_bin" machine create "$image_tag" \
        --name "$machine_name" \
        --cpus ${escapeShellArg (toString cfg.cpus)} \
        --memory ${escapeShellArg cfg.memory} \
        --home-mount ${escapeShellArg cfg.homeMount} 2>&1)
      create_status=$?
      set -e
      if [ "$create_status" -ne 0 ]; then
        echo "hexbox: container machine create exited with status $create_status" >&2
        echo "hexbox: container machine create output:" >&2
        printf '%s\n' "$create_output" >&2
        if "$container_bin" machine inspect "$machine_name" >/dev/null 2>&1 && machine_reaches_status running; then
          echo "hexbox: created machine $machine_name reached running state after create returned an error; continuing" >&2
        else
          echo "hexbox: retrying create after Apple container service restart" >&2
          ${pkgs.coreutils}/bin/timeout 60 "$container_bin" system stop >/dev/null 2>&1 || true
          "$container_bin" system start >/dev/null
          if "$container_bin" machine inspect "$machine_name" >/dev/null 2>&1; then
            ${pkgs.coreutils}/bin/timeout 60 "$container_bin" machine rm "$machine_name" >/dev/null 2>&1 || true
          fi
          set +e
          create_output=$(${pkgs.coreutils}/bin/timeout 60 "$container_bin" machine create "$image_tag" \
            --name "$machine_name" \
            --cpus ${escapeShellArg (toString cfg.cpus)} \
            --memory ${escapeShellArg cfg.memory} \
            --home-mount ${escapeShellArg cfg.homeMount} 2>&1)
          create_status=$?
          set -e
          if [ "$create_status" -ne 0 ]; then
            if "$container_bin" machine inspect "$machine_name" >/dev/null 2>&1 && machine_reaches_status running; then
              echo "hexbox: created machine $machine_name reached running state after retry returned an error; continuing" >&2
            else
              echo "hexbox: failed to create builder machine $machine_name from image $image_tag" >&2
              echo "hexbox: container machine create output:" >&2
              printf '%s\n' "$create_output" >&2
              exit 1
            fi
          fi
        fi
      fi
      stop_machine
      "$bootstrap_machine"
      stop_machine
      boot_machine
    else
      "$container_bin" machine set -n "$machine_name" \
        cpus=${escapeShellArg (toString cfg.cpus)} \
        memory=${escapeShellArg cfg.memory} \
        home-mount=${escapeShellArg cfg.homeMount} >/dev/null
      boot_machine
      current_bootstrap_version=$("$container_bin" machine run --root -i -n "$machine_name" /bin/cat /nix/var/hexbox/bootstrap-version </dev/null 2>/dev/null || true)
      if [ "$current_bootstrap_version" != "$bootstrap_version" ]; then
        stop_machine
        "$bootstrap_machine"
        boot_machine
      fi
    fi
  '';

  stopScript = pkgs.writeShellScript "hexbox-stop-machine" ''
    set -euo pipefail
    if [ "$(/usr/bin/id -un)" != ${escapeShellArg owner} ]; then
      exec /usr/bin/sudo -n -u ${escapeShellArg owner} -H "$0"
    fi
    exec ${pkgs.coreutils}/bin/timeout 30 ${escapeShellArg cfg.containerBinary} machine stop ${escapeShellArg machineName}
  '';

  resetScript = pkgs.writeShellScript "hexbox-reset-machine" ''
    set -euo pipefail
    if [ "$(/usr/bin/id -un)" != ${escapeShellArg owner} ]; then
      exec /usr/bin/sudo -n -u ${escapeShellArg owner} -H "$0"
    fi
    container_bin=${escapeShellArg cfg.containerBinary}
    machine_name=${escapeShellArg machineName}
    ${pkgs.coreutils}/bin/timeout 30 "$container_bin" machine stop "$machine_name" >/dev/null 2>&1 || true
    set +e
    rm_output=$(${pkgs.coreutils}/bin/timeout 60 "$container_bin" machine rm "$machine_name" 2>&1)
    rm_status=$?
    set -e
    if [ "$rm_status" -ne 0 ]; then
      if ! "$container_bin" machine inspect "$machine_name" >/dev/null 2>&1; then
        rm_status=0
      fi
    fi
    if [ "$rm_status" -ne 0 ]; then
      echo "hexbox: container machine rm did not complete; restarting Apple container services and retrying" >&2
      ${pkgs.coreutils}/bin/timeout 60 "$container_bin" system stop >/dev/null 2>&1 || true
      "$container_bin" system start >/dev/null
      set +e
      rm_output=$(${pkgs.coreutils}/bin/timeout 60 "$container_bin" machine rm "$machine_name" 2>&1)
      rm_status=$?
      set -e
      if [ "$rm_status" -ne 0 ] && ! "$container_bin" machine inspect "$machine_name" >/dev/null 2>&1; then
        rm_status=0
      fi
    fi
    if [ "$rm_status" -ne 0 ]; then
      case "$rm_output" in
        *"not found"* | *"No such"* | *"does not exist"*) ;;
        *)
          printf '%s\n' "$rm_output" >&2
          exit 1
          ;;
      esac
    fi
    exec ${escapeShellArg "${workDir}/start-container.sh"}
  '';

  proxyScript = pkgs.writeShellScript "hexbox-machine-proxy" ''
    set -euo pipefail

    owner=${escapeShellArg owner}
    start_container=${escapeShellArg "${workDir}/start-container.sh"}
    container_bin=${escapeShellArg cfg.containerBinary}
    machine_name=${escapeShellArg machineName}
    container_port=${escapeShellArg (toString cfg.containerPort)}

    run_proxy() {
      if ! "$start_container" >/dev/null; then
        echo "hexbox: failed to start builder machine; run 'hb builder repair' and inspect readiness logs" >&2
        exit 1
      fi
      ready=0
      attempt=1
      while [ "$attempt" -le 30 ]; do
        if ${pkgs.coreutils}/bin/timeout 5 "$container_bin" machine run --root -i -n "$machine_name" nc -z 127.0.0.1 "$container_port" </dev/null >/dev/null 2>&1; then
          ready=1
          break
        fi
        attempt=$((attempt + 1))
        /bin/sleep 1
      done
      if [ "$ready" -ne 1 ]; then
        echo "hexbox: builder SSH did not become ready; run 'hb builder repair' and inspect readiness logs" >&2
        exit 1
      fi
      exec "$container_bin" machine run --root -i -n "$machine_name" nc -N 127.0.0.1 "$container_port"
    }

    if [ "$(/usr/bin/id -un)" = "$owner" ]; then
      run_proxy
    fi

    if [ "$(/usr/bin/id -u)" = 0 ]; then
      owner_uid=$(/usr/bin/id -u "$owner")
      exec /bin/launchctl asuser "$owner_uid" /usr/bin/sudo -n -u "$owner" -H "$0"
    fi

    echo "hexbox: proxy must run as $owner or root" >&2
    exit 1
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
      Port ${toString cfg.containerPort}
      IdentityFile ${sshKeyPath}
      ProxyCommand ${escapeShellArg "${workDir}/proxy.sh"}
      BatchMode yes
      StrictHostKeyChecking yes
      UserKnownHostsFile ${knownHostsPath}
      LogLevel ERROR
      ServerAliveInterval 15
      ServerAliveCountMax 4

    Host ${cfg.hostAlias}
      HostName ${machineName}
      User ${cfg.sshUser}
      Port ${toString cfg.containerPort}
      IdentityFile ${sshKeyPath}
      ProxyCommand ${escapeShellArg "${workDir}/proxy.sh"}
      BatchMode yes
      StrictHostKeyChecking yes
      UserKnownHostsFile ${knownHostsPath}
      LogLevel ERROR
      ServerAliveInterval 15
      ServerAliveCountMax 4
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
    enable = mkEnableOption "Apple container machine Linux remote builder";

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
      description = "OCI repository or image name used for the Linux builder container machine image.";
    };

    nixVersion = mkOption {
      type = types.str;
      default = runtimeVersions.builderImage.version;
      description = "Version tag of the HexBox builder image. For custom Containerfiles, change this tag or remove the local image to force a rebuild.";
    };

    imageContainerfile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Optional custom Containerfile to build locally for the builder machine. When null, HexBox uses the published GHCR image.";
    };

    imageBuildContext = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional absolute host path to the build context for `imageContainerfile`. When null, custom images build with an empty generated context.";
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
      description = "Nix builder features advertised for the container machine builder.";
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
      {
        assertion = cfg.imageBuildContext == null || cfg.imageContainerfile != null;
        message = "`services.container-builder.imageBuildContext` requires `services.container-builder.imageContainerfile`.";
      }
      {
        assertion = cfg.imageBuildContext == null || lib.hasPrefix "/" cfg.imageBuildContext;
        message = "`services.container-builder.imageBuildContext` must be an absolute host path string.";
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

      /bin/rm -f /etc/ssh/ssh_config.d/201-container-builder-socat.conf
      stale_proxy_agent=${escapeShellArg "/Users/${owner}/Library/LaunchAgents/com.github.robertderose.hexbox-proxy.plist"}
      /bin/launchctl bootout "gui/$(/usr/bin/id -u ${escapeShellArg owner})" "$stale_proxy_agent" >/dev/null 2>&1 || true
      /bin/rm -f "$stale_proxy_agent"
      stale_machine_proxy_agent=${escapeShellArg "/Users/${owner}/Library/LaunchAgents/org.nixos.hexbox-machine-proxy.plist"}
      /bin/launchctl bootout "gui/$(/usr/bin/id -u ${escapeShellArg owner})" "$stale_machine_proxy_agent" >/dev/null 2>&1 || true
      /bin/rm -f "$stale_machine_proxy_agent"

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

      ${pkgs.coreutils}/bin/mkdir -p ${escapeShellArg workDir}
      /usr/sbin/chown ${escapeShellArg owner}:staff ${escapeShellArg workDir}
      /bin/chmod 0700 ${escapeShellArg workDir}

      ${optionalString hasCustomImageContainerfile ''
        ${pkgs.coreutils}/bin/mkdir -p ${escapeShellArg "${workDir}/builder-image/context"}
        ${pkgs.coreutils}/bin/install -m 0644 ${escapeShellArg cfg.imageContainerfile} ${escapeShellArg "${workDir}/builder-image/Containerfile"}
      ''}
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
      : > ${escapeShellArg readinessLogPath}
      /bin/chmod 0644 ${escapeShellArg readinessLogPath}
      if [ -e ${escapeShellArg "${hostKeyPath}.pub"} ]; then
        host_key=$(${pkgs.coreutils}/bin/cut -d ' ' -f 1-2 ${escapeShellArg "${hostKeyPath}.pub"})
        ${pkgs.coreutils}/bin/printf '%s %s\n' ${escapeShellArg knownHostsAliases} "$host_key" > ${escapeShellArg knownHostsPath}
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
