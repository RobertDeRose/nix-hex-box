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
  containerGenerationLabel = "hexbox.generation";
  bridgeAgentName = "hexbox-bridge";
  bridgeAgentLabel = "org.nixos.${bridgeAgentName}";
  containerScriptVersion = "2026-04-25-on-demand-only-1";

  workDir = cfg.workingDirectory;
  containerExecutable = "/usr/local/bin/container";
  hostContainerInternalDomain = "host.container.internal";
  hostContainerInternalLoopback = "203.0.113.113";
  effectiveImage = "${cfg.imageRepository}:${cfg.nixVersion}";
  sshKeyPath = "${workDir}/builder_ed25519";
  hostKeyPath = "${workDir}/ssh_host_ed25519_key";
  readinessLogPath = "${workDir}/hexbox-readiness.log";
  idleLogPath = "${workDir}/hexbox-idle.log";
  bridgeLaunchPath = "${workDir}/hexbox-bridge";
  reconcileHostContainerInternalScript = pkgs.writeShellScript "hexbox-reconcile-host-container-internal" ''
    set -euo pipefail

    if [ "$(/usr/bin/id -u)" -ne 0 ]; then
      echo "must run as root" >&2
      exit 1
    fi

    if ${boolToString cfg.exposeHostContainerInternal}; then
      if ${escapeShellArg cfg.containerBinary} system dns list 2>/dev/null | /usr/bin/grep -qx ${escapeShellArg hostContainerInternalDomain}; then
        ${escapeShellArg cfg.containerBinary} system dns delete ${escapeShellArg hostContainerInternalDomain}
      fi
      echo "configuring Apple container DNS entry for ${hostContainerInternalDomain}" >&2
      ${escapeShellArg cfg.containerBinary} system dns create ${escapeShellArg hostContainerInternalDomain} --localhost ${escapeShellArg hostContainerInternalLoopback}
    elif ${escapeShellArg cfg.containerBinary} system dns list 2>/dev/null | /usr/bin/grep -qx ${escapeShellArg hostContainerInternalDomain}; then
      echo "removing Apple container DNS entry for ${hostContainerInternalDomain}" >&2
      ${escapeShellArg cfg.containerBinary} system dns delete ${escapeShellArg hostContainerInternalDomain}
    fi
  '';
  containerInstallerPkg = pkgs.fetchurl {
    url = cfg.installer.url;
    hash = cfg.installer.hash;
  };

  bootstrapKeysScript = pkgs.writeShellScript "hexbox-bootstrap-keys" ''
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

  initScript = pkgs.writeShellScript "hexbox-init" ''
    set -e
    mkdir -p /config
    exec > /config/init-debug.log 2>&1
    set -x
    unset NIX_PATH
    export PATH="/root/.nix-profile/bin:/bin:/sbin:/usr/bin:/usr/local/bin:$PATH"

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
    EOF

    mkdir -p /var/cache/nix/narinfo

    mkdir -p /home/builder/.ssh
    cp /config/builder_ed25519.pub /home/builder/.ssh/authorized_keys
    chmod 700 /home/builder/.ssh
    chmod 600 /home/builder/.ssh/authorized_keys
    chown -R 1000:1000 /home/builder/.ssh

    mkdir -p /home/builder/.cache
    chown -R 1000:1000 /home/builder

    mkdir -p /etc/ssh
    cp /config/ssh_host_ed25519_key /etc/ssh/
    chmod 600 /etc/ssh/ssh_host_ed25519_key

    if ! id sshd > /dev/null 2>&1; then
      echo "sshd:x:74:74:sshd privsep:/var/empty:/bin/false" >> /etc/passwd
      echo "sshd:x:74:" >> /etc/group
    fi
    mkdir -p /var/empty

    mkdir -p /run/sshd
    mkdir -p /var/log
    cat > /etc/ssh/sshd_config << 'EOF'
    ListenAddress 0.0.0.0:${toString cfg.containerPort}
    HostKey /etc/ssh/ssh_host_ed25519_key
    PidFile /run/sshd/sshd.pid
    PermitRootLogin no
    PubkeyAuthentication yes
    PasswordAuthentication no
    ChallengeResponseAuthentication no
    UsePAM no
    PrintMotd no
    AcceptEnv LANG LC_*
    SetEnv PATH=/root/.nix-profile/bin:/bin:/sbin:/usr/bin:/usr/local/bin
    Subsystem sftp internal-sftp
    MaxStartups 64:30:128
    MaxSessions 64
    EOF

    mkdir -p /usr/local/bin
    cat > /usr/local/bin/hexbox-idle-watchdog << 'EOF'
    #!/bin/sh
    set -eu
    export PATH="/root/.nix-profile/bin:/bin:/sbin:/usr/bin:/usr/local/bin:$PATH"

    timeout_seconds=${toString cfg.idleShutdown.timeoutSeconds}
    interval_seconds=30
    idle_seconds=0
    log_file=/config/hexbox-idle.log

    touch "$log_file"
    exec >> "$log_file" 2>&1
    set -x
    echo "[$(date)] idle watchdog started (timeout=${toString cfg.idleShutdown.timeoutSeconds}s)"

    while ! command -v ps >/dev/null 2>&1; do
      echo "[$(date)] waiting for procps installation"
      sleep 5
    done

    while true; do
      sleep "$interval_seconds"

      if ps -ef | grep -q 'sshd-sessio[n]'; then
        ssh_sessions=1
      else
        ssh_sessions=0
      fi

      if [ "$ssh_sessions" -gt 0 ]; then
        idle_seconds=0
        echo "[$(date)] active ssh sessions detected (count=$ssh_sessions); resetting idle timer"
        continue
      fi

      idle_seconds=$(( idle_seconds + interval_seconds ))
      echo "[$(date)] no active ssh sessions (count=$ssh_sessions); idle=$idle_seconds s"

      if [ "$idle_seconds" -lt "$timeout_seconds" ]; then
        continue
      fi

      echo "[$(date)] idle timeout reached; stopping sshd"
      sshd_pid=$(cat /run/sshd/sshd.pid 2>/dev/null || true)
      if [ -n "$sshd_pid" ] && kill -0 "$sshd_pid" 2>/dev/null; then
        kill -TERM "$sshd_pid"
      fi
      exit 0
    done
    EOF
    chmod +x /usr/local/bin/hexbox-idle-watchdog

    ${optionalString cfg.idleShutdown.enable ''
      if ! command -v ps >/dev/null 2>&1; then
        sh -c 'until nix --extra-experimental-features "nix-command flakes" profile install --profile /root/.nix-profile nixpkgs#procps; do sleep 10; done' >/config/procps-install.log 2>&1 &
      fi
    ''}

    echo "starting nix-daemon"
    nix-daemon &
    echo "started nix-daemon pid=$!"
    ${optionalString cfg.idleShutdown.enable ''
      echo "starting idle watchdog"
      /usr/local/bin/hexbox-idle-watchdog &
      echo "started idle watchdog pid=$!"
    ''}
    echo "starting sshd"
    exec "$(command -v sshd)" -D -e
  '';

  proxyScript = pkgs.writeShellScript "hexbox-proxy" ''
    set -euo pipefail

    container_bin=${escapeShellArg cfg.containerBinary}
    container_name=${escapeShellArg effectiveContainerName}
    timeout_seconds=${escapeShellArg (toString cfg.readiness.timeoutSeconds)}
    interval_seconds=${escapeShellArg (toString cfg.readiness.intervalSeconds)}
    deadline=$(( $(/bin/date +%s) + timeout_seconds ))

    "$container_bin" system start >/dev/null 2>&1 || true
    ${startScript} >/dev/null 2>&1 || true

    while [ "$(( $(/bin/date +%s) ))" -lt "$deadline" ]; do
      if "$container_bin" exec "$container_name" sh -c ${escapeShellArg ''pid=$(cat /run/sshd/sshd.pid 2>/dev/null || true); [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null''} </dev/null >/dev/null 2>&1; then
        container_ip=$("$container_bin" inspect "$container_name" 2>/dev/null | /usr/bin/grep -Eo '"ipv4Address":"[0-9.]+' | /usr/bin/sed -n '1s/.*:"//p')
        if [ -n "$container_ip" ]; then
          exec /usr/bin/nc "$container_ip" ${toString cfg.containerPort}
        fi
      fi

      /bin/sleep "$interval_seconds"
    done

    echo "timed out waiting for in-container SSH readiness" >&2
    exit 1
  '';

  readinessScript = pkgs.writeShellScript "hexbox-readiness" ''
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

  startScript = pkgs.writeShellScript "hexbox-start" ''
    set -euo pipefail

    container_bin=${escapeShellArg cfg.containerBinary}
    reconcile_host_container_internal=${escapeShellArg reconcileHostContainerInternalScript}
    workdir=${escapeShellArg workDir}
    container_base=${escapeShellArg cfg.containerName}
    container_name=${escapeShellArg effectiveContainerName}

    if ! "$container_bin" system status >/dev/null 2>&1; then
      echo "Apple container system unhealthy; attempting recovery" >&2
      if ! "$container_bin" system start --enable-kernel-install >/dev/null 2>&1; then
        echo "Apple container recovery failed" >&2
        exit 1
      fi
    fi

    "$container_bin" system start >/dev/null 2>&1 || true

    if [ "$(/usr/bin/id -u)" -eq 0 ]; then
      "$reconcile_host_container_internal"
    fi

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

    container_info="$($container_bin inspect "$container_name" 2>/dev/null || true)"

    if [ -n "$container_info" ]; then
      if ! printf '%s' "$container_info" | ${pkgs.gnugrep}/bin/grep -Eq ${escapeShellArg ''"${containerGenerationLabel}"[[:space:]]*:[[:space:]]*"${containerVersion}"''}; then
        echo "existing container-builder container does not match current config generation; recreating"
        "$container_bin" rm -f "$container_name" >/dev/null 2>&1 || true
        container_info=""
      fi
    fi

    if [ -n "$container_info" ]; then
      if printf '%s' "$container_info" | ${pkgs.gnugrep}/bin/grep -q '"status"[[:space:]]*:[[:space:]]*"running"'; then
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
      --init
      --name "$container_name"
      --label ${escapeShellArg "${containerGenerationLabel}=${containerVersion}"}
      --cpus ${escapeShellArg (toString cfg.cpus)}
      -m ${escapeShellArg cfg.memory}
      -v ${escapeShellArg "${workDir}:/config"}
    )

    ${optionalString (cfg.dns.servers != [ ]) ''
      ${concatMapStringsSep "\n" (server: "args+=( --dns ${escapeShellArg server} )") cfg.dns.servers}
    ''}

    ${optionalString (cfg.dns.search != [ ]) ''
      ${concatMapStringsSep "\n" (
        domain: "args+=( --dns-search ${escapeShellArg domain} )"
      ) cfg.dns.search}
    ''}

    ${optionalString (cfg.dns.options != [ ]) ''
      ${concatMapStringsSep "\n" (
        option: "args+=( --dns-option ${escapeShellArg option} )"
      ) cfg.dns.options}
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
      ${escapeShellArg effectiveImage}
      sh
      -c
      ${escapeShellArg "sh /config/init.sh"}
    )

    exec "$container_bin" "''${args[@]}"
  '';

  stopScript = pkgs.writeShellScript "hexbox-stop" ''
    set -euo pipefail
    exec ${escapeShellArg cfg.containerBinary} rm -f ${escapeShellArg effectiveContainerName}
  '';

  helperScript = pkgs.writeShellScript "hb" ''
    set -euo pipefail

        host_alias=${escapeShellArg cfg.hostAlias}
        ssh_config=${escapeShellArg "${workDir}/ssh_config_root"}
        container_bin=${escapeShellArg cfg.containerBinary}
        container_name=${escapeShellArg effectiveContainerName}
        reconcile_host_container_internal=${escapeShellArg "${workDir}/reconcile-host-container-internal.sh"}
        readiness_log=${escapeShellArg readinessLogPath}
    bridge_out_log=${escapeShellArg "${workDir}/hexbox-bridge.out.log"}
    bridge_err_log=${escapeShellArg "${workDir}/hexbox-bridge.err.log"}

        print_mark() {
          case "$1" in
            ok) printf '[x] %s\n' "$2" ;;
            fail) printf '[ ] %s\n' "$2" ;;
            skip) printf '[-] %s\n' "$2" ;;
          esac
        }

        recover_container_system() {
          "$container_bin" system start --enable-kernel-install
        }

        status_system() {
          "$container_bin" system status --format json 2>/dev/null || return 1
        }

        status_container() {
          "$container_bin" inspect "$container_name" 2>/dev/null || return 1
        }

        status_ssh() {
          /usr/bin/ssh -F "$ssh_config" -o BatchMode=yes -o ConnectTimeout=2 "$host_alias" true >/dev/null 2>&1
        }

        status_remote_store() {
          nix store ping --store ${escapeShellArg "${cfg.protocol}://${cfg.hostAlias}"} >/dev/null 2>&1
        }

        status_with_retries() {
          local attempts="$1"
          shift
          local remaining="$attempts"

          while [ "$remaining" -gt 0 ]; do
            if "$@"; then
              return 0
            fi
            remaining=$((remaining - 1))
            if [ "$remaining" -gt 0 ]; then
              /bin/sleep 1
            fi
          done

          return 1
        }

        render_status() {
          local system_state=down
          local container_state=missing
          local ssh_state=failed
          local remote_state=failed
          local bridge_state=disabled

          if status_system >/dev/null; then
            system_state=running
          fi

          if status_container | ${pkgs.gnugrep}/bin/grep -q '"status"[[:space:]]*:[[:space:]]*"running"'; then
            container_state=running
          elif status_container >/dev/null 2>&1; then
            container_state=stopped
          fi

          if [ "$container_state" = running ]; then
            if status_with_retries 3 status_ssh; then
              ssh_state=ok
            else
              ssh_state=starting
            fi
          fi

          if [ "$container_state" = running ]; then
            if status_with_retries 3 status_remote_store; then
              remote_state=ok
            else
              remote_state=starting
            fi
          fi

          if launchctl print gui/$(id -u)/${bridgeAgentLabel} >/dev/null 2>&1; then
            bridge_state=loaded
          fi

          printf '%-18s %s\n' COMPONENT STATE
          printf '%-18s %s\n' --------- -----
          printf '%-18s %s\n' 'container system' "$system_state"
          printf '%-18s %s\n' 'bridge agent' "$bridge_state"
          printf '%-18s %s\n' 'builder container' "$container_state"
          printf '%-18s %s\n' 'ssh handshake' "$ssh_state"
          printf '%-18s %s\n' 'remote store' "$remote_state"
        }

    do_repair() {
      local recovered=no
      local readiness_attempt=1
      local readiness_ok=0

          if status_system >/dev/null; then
            print_mark ok 'Apple container system running'
          else
            print_mark fail 'Apple container system unhealthy; attempting recovery'
            if recover_container_system; then
              recovered=yes
              print_mark ok 'Apple container recovery succeeded'
            else
              print_mark fail 'Apple container recovery failed'
              exit 1
            fi
          fi

          if launchctl print gui/$(id -u)/${bridgeAgentLabel} >/dev/null 2>&1; then
            print_mark ok 'Bridge agent loaded'
          else
            print_mark fail 'Bridge agent not loaded'
          fi

          ${startScript} >/dev/null 2>&1 || true

          if status_container | ${pkgs.gnugrep}/bin/grep -q '"status"[[:space:]]*:[[:space:]]*"running"'; then
            print_mark ok 'Builder container running'
          else
            print_mark fail 'Builder container not running'
            exit 1
          fi

      while [ "$readiness_attempt" -le 3 ]; do
        if ${readinessScript} >/dev/null 2>&1; then
          readiness_ok=1
          break
        fi

        readiness_attempt=$((readiness_attempt + 1))
        if [ "$readiness_attempt" -le 3 ]; then
          ${startScript} >/dev/null 2>&1 || true
          /bin/sleep 2
            fi
          done

          if [ "$readiness_ok" -eq 1 ]; then
            print_mark ok 'SSH handshake succeeded'
          else
            print_mark fail 'SSH handshake failed'
            exit 1
          fi

          if /usr/bin/ssh -F "$ssh_config" -o BatchMode=yes "$host_alias" 'nix store ping --store https://cache.nixos.org' >/dev/null 2>&1; then
            print_mark ok 'Builder can reach cache.nixos.org'
          else
            print_mark fail 'Builder cannot reach cache.nixos.org'
            exit 1
          fi

          if nix store ping --store ${escapeShellArg "${cfg.protocol}://${cfg.hostAlias}"} >/dev/null 2>&1; then
            print_mark ok 'Host can reach remote store'
          else
            print_mark fail 'Host cannot reach remote store'
            exit 1
          fi

          if [ "$recovered" = yes ]; then
            print_mark ok 'Recovery was required'
          else
            print_mark skip 'Recovery not required'
          fi
        }

        do_logs() {
          local target="''${1:-runtime}"
          shift || true
          local follow=0
          local lines=100

          while [ "$#" -gt 0 ]; do
            case "$1" in
              -f|--follow) follow=1 ;;
              -n) shift; lines="$1" ;;
              *) echo "unknown logs argument: $1" >&2; exit 2 ;;
            esac
            shift || true
          done

          case "$target" in
            idle) logfile=${escapeShellArg idleLogPath} ;;
            readiness) logfile="$readiness_log" ;;
            bridge) logfile="$bridge_err_log" ;;
            bridge-out) logfile="$bridge_out_log" ;;
            boot)
              if [ "$follow" -eq 1 ]; then
                exec "$container_bin" logs --boot --follow "$container_name"
              else
                exec "$container_bin" logs --boot -n "$lines" "$container_name"
              fi
              ;;
            *) echo "unknown log target: $target" >&2; exit 2 ;;
          esac

          if [ ! -f "$logfile" ]; then
            echo "log file not found: $logfile" >&2
            exit 1
          fi

          if [ "$follow" -eq 1 ]; then
            exec ${pkgs.coreutils}/bin/tail -n "$lines" -f "$logfile"
          else
            exec ${pkgs.coreutils}/bin/tail -n "$lines" "$logfile"
          fi
        }

        do_gc() {
          exec /usr/bin/ssh -F "$ssh_config" "$host_alias" 'nix-collect-garbage -d'
        }

        do_reset() {
          ${stopScript} >/dev/null 2>&1 || true
          ${startScript}
          ${readinessScript}
          render_status
        }

        do_restart() {
          ${stopScript} >/dev/null 2>&1 || true
          ${startScript}
          ${readinessScript}
          render_status
        }

        do_ssh() {
          exec /usr/bin/ssh -F "$ssh_config" "$host_alias" "$@"
        }

        do_inspect() {
          printf '==> launchd bridge\n'
          launchctl print gui/$(id -u)/${bridgeAgentLabel} || true
          printf '\n==> container inspect\n'
          status_container || true
        }

        do_host_check() {
          local port="''${1:-}"
          local probe_cmd

          if [ -z "$port" ]; then
            echo "usage: hb host-check <port>" >&2
            exit 2
          fi

          case "$port" in
            *[!0-9]*|"")
              echo "port must be numeric: $port" >&2
              exit 2
              ;;
          esac

          probe_cmd="nc -zvw5 host.container.internal $port"

          if ! ${boolToString cfg.exposeHostContainerInternal}; then
            echo "host.container.internal exposure is disabled in services.container-builder.exposeHostContainerInternal" >&2
            exit 1
          fi

          if ! status_system >/dev/null; then
            recover_container_system >/dev/null
          fi

          if "$container_bin" run --rm docker.io/alpine:latest sh -eu -c "$probe_cmd"; then
            exit 0
          fi

          if [ "$(/usr/bin/id -u)" -eq 0 ]; then
            "$reconcile_host_container_internal"
          else
            /usr/bin/sudo "$reconcile_host_container_internal"
          fi

          exec "$container_bin" run --rm docker.io/alpine:latest sh -eu -c "$probe_cmd"
        }

        if [ "''${1:-}" = "--help" ] || [ "''${1:-}" = "-h" ] || [ "$#" -eq 0 ]; then
          cat <<'EOF'
    Usage: hb <command>

      status            Show builder status summary.
      repair            Verify builder health and attempt Apple container recovery.
      logs [target]     Show logs. Targets: idle, readiness, bridge, bridge-out, boot.
      gc                Run nix garbage collection inside the builder.
      reset             Destroy and recreate the builder container.
      restart           Restart the builder container.
      ssh               Open an SSH session to the builder.
      inspect           Show raw launchd and container inspection data.
      host-check        Verify host.container.internal reaches a host TCP port.
    EOF
          exit 0
        fi

        command="$1"
        shift

        case "$command" in
          status) render_status ;;
          repair) do_repair ;;
          logs) do_logs "$@" ;;
          gc) do_gc ;;
          reset) do_reset ;;
          restart) do_restart ;;
          ssh) do_ssh "$@" ;;
          inspect) do_inspect ;;
          host-check) do_host_check "$@" ;;
          *) echo "unknown command: $command" >&2; exit 2 ;;
        esac
  '';

  bridgeLaunchScript = pkgs.writeShellScript "hexbox-bridge" ''
    exec ${pkgs.socat}/bin/socat \
      TCP-LISTEN:${toString cfg.port},bind=${cfg.listenAddress},reuseaddr,fork \
      EXEC:${workDir}/proxy.sh
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

  containerConfigSpec = pkgs.writeText "container-builder-config.json" (
    builtins.toJSON {
      inherit owner;
      containerName = cfg.containerName;
      hostAlias = cfg.hostAlias;
      sshUser = cfg.sshUser;
      listenAddress = cfg.listenAddress;
      port = cfg.port;
      containerPort = cfg.containerPort;
      workingDirectory = cfg.workingDirectory;
      image = effectiveImage;
      imageRepository = cfg.imageRepository;
      nixVersion = cfg.nixVersion;
      cpus = cfg.cpus;
      memory = cfg.memory;
      dns = cfg.dns;
      exposeHostContainerInternal = cfg.exposeHostContainerInternal;
      bridgeEnable = cfg.bridge.enable;
      installerVersion = cfg.installer.version;
      protocol = cfg.protocol;
      systems = cfg.systems;
      supportedFeatures = cfg.supportedFeatures;
      mandatoryFeatures = cfg.mandatoryFeatures;
      maxJobs = cfg.maxJobs;
      speedFactor = cfg.speedFactor;
      scriptVersion = containerScriptVersion;
    }
  );
  containerVersion = builtins.substring 0 12 (builtins.baseNameOf containerConfigSpec);
  effectiveContainerName = "${cfg.containerName}-${containerVersion}";
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
      default = "/Users/${owner}/.local/state/hb";
      description = "Directory holding persistent builder state such as keys, generated helper scripts, and logs.";
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

    imageRepository = mkOption {
      type = types.str;
      default = "docker.io/nixos/nix";
      description = "OCI repository used for the Linux builder container image.";
    };

    nixVersion = mkOption {
      type = types.str;
      default = "2.34.6";
      description = "Version tag of the upstream `nixos/nix` container image used for the builder.";
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

    exposeHostContainerInternal = mkOption {
      type = types.bool;
      default = true;
      description = "Expose `host.container.internal` to Apple containers by managing `container system dns` during activation.";
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
      default = false;
      description = "Deprecated no-op retained for compatibility; the builder now starts only on demand.";
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

    idleShutdown.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Stop the builder container automatically after a period with no SSH sessions or build activity.";
    };

    idleShutdown.timeoutSeconds = mkOption {
      type = types.ints.positive;
      default = 300;
      description = "How long the builder may remain idle before being stopped.";
    };

    bridge.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Run a user launch agent with socat to bridge host SSH traffic into `container exec`. Disable this to use direct published ports.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin && pkgs.stdenv.hostPlatform.isAarch64;
        message = "`services.container-builder` is currently only supported on aarch64-darwin.";
      }
    ];

    environment.systemPackages = [ pkgs.netcat ] ++ optional cfg.bridge.enable pkgs.socat;

    environment.etc."ssh/ssh_config.d/201-container-builder.conf".source = rootSshConfig;

    system.activationScripts.extraActivation.text = mkAfter ''
      if [ ! -x ${escapeShellArg containerExecutable} ] || ! ${escapeShellArg containerExecutable} --version 2>/dev/null | /usr/bin/grep -q ${escapeShellArg cfg.installer.version}; then
        echo "installing Apple container ${cfg.installer.version} from official pkg..." >&2
        /usr/sbin/installer -pkg ${escapeShellArg containerInstallerPkg} -target /
      fi

      if ${escapeShellArg cfg.containerBinary} system status >/dev/null 2>&1; then
        ${reconcileHostContainerInternalScript}
      else
        echo "warning: Apple container system is not running; skipping ${hostContainerInternalDomain} DNS reconciliation" >&2
      fi

      ${pkgs.coreutils}/bin/mkdir -p ${escapeShellArg workDir}
      /usr/sbin/chown ${escapeShellArg owner}:staff ${escapeShellArg workDir}
      /bin/chmod 0700 ${escapeShellArg workDir}
      ${pkgs.coreutils}/bin/install -m 0755 ${bootstrapKeysScript} ${escapeShellArg "${workDir}/bootstrap-keys.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${initScript} ${escapeShellArg "${workDir}/init.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${proxyScript} ${escapeShellArg "${workDir}/proxy.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${startScript} ${escapeShellArg "${workDir}/start-container.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${stopScript} ${escapeShellArg "${workDir}/stop-container.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${reconcileHostContainerInternalScript} ${escapeShellArg "${workDir}/reconcile-host-container-internal.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${sshWrapperScript} ${escapeShellArg "${workDir}/ssh-wrapper.sh"}
      ${pkgs.coreutils}/bin/install -m 0755 ${bridgeLaunchScript} ${escapeShellArg bridgeLaunchPath}
      ${pkgs.coreutils}/bin/install -m 0755 ${helperScript} /usr/local/bin/hb
      ${pkgs.coreutils}/bin/install -m 0644 ${userSshConfig} ${escapeShellArg "${workDir}/ssh_config"}
      ${pkgs.coreutils}/bin/install -m 0644 ${rootSshConfig} ${escapeShellArg "${workDir}/ssh_config_root"}
      /usr/sbin/chown ${escapeShellArg owner}:staff \
        ${escapeShellArg "${workDir}/bootstrap-keys.sh"} \
        ${escapeShellArg "${workDir}/init.sh"} \
        ${escapeShellArg "${workDir}/proxy.sh"} \
        ${escapeShellArg "${workDir}/start-container.sh"} \
        ${escapeShellArg "${workDir}/stop-container.sh"} \
        ${escapeShellArg "${workDir}/reconcile-host-container-internal.sh"} \
        ${escapeShellArg "${workDir}/ssh-wrapper.sh"} \
        ${escapeShellArg bridgeLaunchPath} \
        ${escapeShellArg "${workDir}/ssh_config"} \
        ${escapeShellArg "${workDir}/ssh_config_root"}

      if [ ! -e ${escapeShellArg sshKeyPath} ] || [ ! -e ${escapeShellArg "${sshKeyPath}.pub"} ] || [ ! -e ${escapeShellArg hostKeyPath} ] || [ ! -e ${escapeShellArg "${hostKeyPath}.pub"} ]; then
        echo "warning: container-builder keys are missing in ${workDir}; run ${workDir}/bootstrap-keys.sh" >&2
      fi
    '';

    launchd.user.agents."${bridgeAgentName}" = mkIf cfg.bridge.enable {
      serviceConfig = {
        KeepAlive = true;
        RunAtLoad = true;
        ProgramArguments = [ bridgeLaunchPath ];
        StandardErrorPath = "${workDir}/hexbox-bridge.err.log";
        StandardOutPath = "${workDir}/hexbox-bridge.out.log";
        WorkingDirectory = workDir;
      };
      managedBy = "services.container-builder.bridge.enable";
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
