#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2034,SC2154
set -eo pipefail

# @describe Helper CLI for nix-hex-box container-builder operations
# @meta binname hb

hb_env_loaded=0

hb_init() {
  if [ "$hb_env_loaded" -eq 1 ]; then
    return
  fi

  host_alias=${HB_HOST_ALIAS:?}
  ssh_config=${HB_SSH_CONFIG:?}
  container_bin=${HB_CONTAINER_BIN:?}
  container_name=${HB_CONTAINER_NAME:?}
  reconcile_host_container_internal=${HB_RECONCILE_HOST_CONTAINER_INTERNAL:?}
  socktainer_enabled=${HB_SOCKTAINER_ENABLED:?}
  socktainer_agent_label=${HB_SOCKTAINER_AGENT_LABEL:?}
  socktainer_socket=${HB_SOCKTAINER_SOCKET:?}
  socktainer_health=${HB_SOCKTAINER_HEALTH:?}
  socktainer_err_log=${HB_SOCKTAINER_ERR_LOG:?}
  socktainer_out_log=${HB_SOCKTAINER_OUT_LOG:?}
  readiness_log=${HB_READINESS_LOG:?}
  remote_store=${HB_REMOTE_STORE:?}
  start_script=${HB_START_SCRIPT:?}
  stop_script=${HB_STOP_SCRIPT:?}
  reset_script=${HB_RESET_SCRIPT:?}
  readiness_script=${HB_READINESS_SCRIPT:?}
  expose_host_container_internal=${HB_EXPOSE_HOST_CONTAINER_INTERNAL:?}
  hb_env_loaded=1
}

if [ "$#" -eq 1 ]; then
  case "$1" in
    builder) set -- builder status ;;
    socktainer) set -- socktainer status ;;
  esac
fi

if [ "${1:-}" = builder ] && [ "${2:-}" = ssh ] && [ "$#" -eq 3 ]; then
  case "${3:-}" in
    -h | --help | -help)
      cat << 'EOF'
Open an SSH session to the builder

USAGE: hb builder ssh [ARGS]...

ARGS:
  [ARGS]...
EOF
      exit 0
      ;;
  esac
fi

print_mark() {
  printf '%s %s\n' "$(status_icon "$1")" "$2"
}

print_error() {
  print_mark fail "$1" >&2
}

status_icon() {
  case "$1" in
    ok) printf '✅' ;;
    fail) printf '❌' ;;
    skip) printf '⚠️' ;;
    info) printf 'ℹ️' ;;
    pending) printf '⏳' ;;
  esac
}

print_heading() {
  printf '%s %s\n' "$1" "$2"
}

print_state_row() {
  printf '%-18s %s %s\n' "$1" "$(status_icon "$2")" "$3"
}

recover_container_system() {
  "$container_bin" system start --enable-kernel-install
}

doctor_runtime_impl() {
  if status_system > /dev/null; then
    print_mark ok 'Apple container runtime is healthy'
    return 0
  fi

  print_mark fail 'Apple container runtime is unhealthy; attempting recovery'
  if recover_container_system; then
    print_mark ok 'Apple container runtime recovery succeeded'
    return 0
  fi

  print_mark fail 'Apple container runtime recovery failed'
  return 1
}

status_system() {
  "$container_bin" system status --format json 2> /dev/null || return 1
}

status_container() {
  "$container_bin" machine inspect "$container_name" 2> /dev/null || return 1
}

status_ssh() {
  /usr/bin/ssh -F "$ssh_config" -o BatchMode=yes -o ConnectTimeout=2 "$host_alias" true > /dev/null 2>&1
}

status_remote_store() {
  nix store ping --store "$remote_store" > /dev/null 2>&1
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

probe_common_external_domains() {
  local failed=0
  local domains
  local domain

  domains=(google.com github.com cache.nixos.org)
  for domain in "${domains[@]}"; do
    if probe_container_tcp_target "$domain" 443; then
      print_mark ok "Builder machine can reach $domain:443"
    else
      print_mark fail "Builder machine cannot reach $domain:443"
      failed=1
    fi
  done

  if [ "$failed" -ne 0 ]; then
    return 1
  fi
}

# @cmd Builder operations
builder() {
  builder::status
}

# @cmd Show builder status summary
builder::status() {
  hb_init
  local system_kind=fail
  local system_text='not running'
  local machine_kind=fail
  local machine_text=missing
  local ssh_kind=skip
  local ssh_text='not checked'
  local remote_kind=skip
  local remote_text='not checked'

  if status_system > /dev/null; then
    system_kind=ok
    system_text=running
  fi

  if status_container | /usr/bin/grep -q '"status"[[:space:]]*:[[:space:]]*"running"'; then
    machine_kind=ok
    machine_text=running
  elif status_container > /dev/null 2>&1; then
    machine_kind=pending
    machine_text=stopped
  fi

  if [ "$machine_text" = running ]; then
    if status_with_retries 3 status_ssh; then
      ssh_kind=ok
      ssh_text=ready
    else
      ssh_kind=pending
      ssh_text=starting
    fi

    if status_with_retries 3 status_remote_store; then
      remote_kind=ok
      remote_text=reachable
    else
      remote_kind=pending
      remote_text=starting
    fi
  fi

  print_heading '🔨' 'Builder status'
  print_state_row 'container system' "$system_kind" "$system_text"
  print_state_row 'builder machine' "$machine_kind" "$machine_text"
  print_state_row 'ssh handshake' "$ssh_kind" "$ssh_text"
  print_state_row 'remote store' "$remote_kind" "$remote_text"
}

show_logs() {
  local target="$1"
  local follow="$2"
  local lines="$3"
  local logfile

  case "$target" in
    idle)
      if [ "$follow" -eq 1 ]; then
        exec /usr/bin/ssh -F "$ssh_config" "$host_alias" "tail -n '$lines' -f /var/log/hexbox-idle.log"
      else
        exec /usr/bin/ssh -F "$ssh_config" "$host_alias" "tail -n '$lines' /var/log/hexbox-idle.log"
      fi
      ;;
    readiness) logfile="$readiness_log" ;;
    bridge | bridge-out)
      print_error 'Bridge logs were removed with the container-machine backend'
      exit 2
      ;;
    boot)
      if [ "$follow" -eq 1 ]; then
        exec "$container_bin" machine logs --boot --follow "$container_name"
      else
        "$container_bin" machine logs --boot "$container_name" | /usr/bin/tail -n "$lines"
        return
      fi
      ;;
    *)
      print_error "Unknown log target: $target"
      exit 2
      ;;
  esac

  if [ ! -f "$logfile" ]; then
    print_error "Log file not found: $logfile"
    exit 1
  fi

  if [ "$follow" -eq 1 ]; then
    exec /usr/bin/tail -n "$lines" -f "$logfile"
  else
    print_heading '📜' "Builder logs: $target"
    exec /usr/bin/tail -n "$lines" "$logfile"
  fi
}

# @cmd Show builder logs
# @arg target![idle|readiness|boot] Log target
# @flag -f --follow Follow log output
# @option -n --lines <LINES> Number of lines to show
builder::logs() {
  hb_init
  local lines="${argc_lines:-100}"

  case "$lines" in
    *[!0-9]* | '')
      print_error "Lines must be numeric: $lines"
      exit 2
      ;;
  esac

  show_logs "$argc_target" "${argc_follow:-0}" "$lines"
}

# @cmd Run a simple remote build smoke test through the builder
builder::test() {
  hb_init
  local expr
  local output_path
  local -a build_args

  expr='
    derivation {
      name = "hexbox-builder-smoke";
      system = "aarch64-linux";
      builder = "/bin/sh";
      args = [ "-c" "printf ok > \"$out\"" ];
    }
  '

  builder::repair
  print_heading '🧪' 'Remote build smoke test (trivial aarch64-linux derivation)'

  output_path=$(nix eval --raw --impure --expr "(${expr}).outPath")

  build_args=(
    build
    --max-jobs 0
    --no-link
    --option substitute false
    --impure
    --expr "$expr"
  )

  if nix path-info "$output_path" > /dev/null 2>&1; then
    build_args+=(--rebuild)
  fi

  exec nix "${build_args[@]}"
}

# @cmd Verify builder health and recover runtime if needed
builder::repair() {
  hb_init
  local readiness_attempt=1
  local readiness_ok=0

  if ! doctor_runtime_impl; then
    exit 1
  fi

  "$start_script"

  if status_container | /usr/bin/grep -q '"status"[[:space:]]*:[[:space:]]*"running"'; then
    print_mark ok 'Builder machine running'
  else
    print_mark fail 'Builder machine not running'
    exit 1
  fi

  while [ "$readiness_attempt" -le 3 ]; do
    if "$readiness_script" > /dev/null 2>&1; then
      readiness_ok=1
      break
    fi

    readiness_attempt=$((readiness_attempt + 1))
    if [ "$readiness_attempt" -le 3 ]; then
      "$start_script" > /dev/null 2>&1 || true
      /bin/sleep 2
    fi
  done

  if [ "$readiness_ok" -eq 1 ]; then
    print_mark ok 'SSH handshake succeeded'
  else
    print_mark fail 'SSH handshake failed'
    exit 1
  fi

  if ! probe_common_external_domains; then
    exit 1
  fi

  if nix store ping --store "$remote_store" > /dev/null 2>&1; then
    print_mark ok 'Host can reach remote store'
  else
    print_mark fail 'Host cannot reach remote store'
    exit 1
  fi
}

# @cmd Destroy and recreate the builder machine
builder::reset() {
  hb_init
  "$reset_script"
  "$readiness_script"
  builder::status
}

# @cmd Run nix garbage collection inside the builder
builder::gc() {
  hb_init
  exec /usr/bin/ssh -F "$ssh_config" "$host_alias" 'nix-collect-garbage -d'
}

# @cmd Show raw launchd and container inspection data
builder::inspect() {
  hb_init
  if launchctl print "gui/$(id -u)/$socktainer_agent_label" > /dev/null 2>&1; then
    print_heading '🔎' 'launchd socktainer'
    launchctl print "gui/$(id -u)/$socktainer_agent_label" || true
    printf '\n'
  fi
  print_heading '🔎' 'container machine inspect'
  status_container || true
}

# @cmd Open an SSH session to the builder
# @arg args~
builder::ssh() {
  hb_init
  exec /usr/bin/ssh -F "$ssh_config" "$host_alias" "$@"
}

socktainer_disabled() {
  print_error 'Socktainer is disabled'
  exit 1
}

# @cmd Manage Socktainer
socktainer() {
  hb_init
  socktainer::status
}

# @cmd Show Socktainer status
socktainer::status() {
  hb_init
  local agent_kind=fail
  local agent_text='not loaded'
  local socket_kind=fail
  local socket_text=missing
  local ping_kind=fail
  local ping_text=unreachable

  if [ "$socktainer_enabled" != true ]; then
    socktainer_disabled
  fi

  if launchctl print "gui/$(id -u)/$socktainer_agent_label" > /dev/null 2>&1; then
    agent_kind=ok
    agent_text=loaded
  fi

  if [ -S "$socktainer_socket" ]; then
    socket_kind=ok
    socket_text=present
  fi

  if "$socktainer_health" > /dev/null 2>&1; then
    ping_kind=ok
    ping_text=ready
  fi

  print_heading '🚢' 'Socktainer status'
  print_state_row 'socktainer agent' "$agent_kind" "$agent_text"
  print_state_row 'socktainer socket' "$socket_kind" "$socket_text"
  print_state_row 'socktainer ping' "$ping_kind" "$ping_text"
  print_state_row 'docker host' info "unix://$socktainer_socket"
}

socktainer_logs_impl() {
  local follow="$1"

  if [ "$socktainer_enabled" != true ]; then
    socktainer_disabled
  fi

  if [ ! -f "$socktainer_err_log" ]; then
    print_error "Log file not found: $socktainer_err_log"
    exit 1
  fi

  if [ ! -f "$socktainer_out_log" ]; then
    print_error "Log file not found: $socktainer_out_log"
    exit 1
  fi

  if [ "$follow" -eq 1 ]; then
    exec /usr/bin/tail -n 100 -f "$socktainer_err_log" "$socktainer_out_log"
  else
    print_heading '📜' 'socktainer stderr'
    /usr/bin/tail -n 100 "$socktainer_err_log"
    printf '\n'
    print_heading '📜' 'socktainer stdout'
    /usr/bin/tail -n 100 "$socktainer_out_log"
  fi
}

# @cmd Show Socktainer logs
# @flag -f --follow Follow log output
socktainer::logs() {
  hb_init
  socktainer_logs_impl "${argc_follow:-0}"
}

# @cmd Run runtime and connectivity diagnostics
doctor() {
  hb_init
  doctor::runtime
  printf '\n'
  doctor::dns
  printf '\n'
  doctor::host
}

probe_container_dns_name() {
  local host="$1"

  "$container_bin" machine run --root -n "$container_name" getent hosts "$host" > /dev/null 2>&1
}

probe_container_tcp_target() {
  local host="$1"
  local port="$2"

  "$container_bin" machine run --root -n "$container_name" nc -zvw5 "$host" "$port" > /dev/null 2>&1
}

# @cmd Check and recover Apple container runtime
doctor::runtime() {
  hb_init
  print_heading '🩻' 'Runtime check'
  doctor_runtime_impl
}

# @cmd Check container access to common external domains
doctor::dns() {
  hb_init

  print_heading '🌐' 'DNS check'

  if ! status_system > /dev/null; then
    recover_container_system > /dev/null
  fi

  "$start_script" > /dev/null

  if probe_common_external_domains; then
    return 0
  fi

  print_mark fail 'Builder external reachability failed; restarting Apple container runtime and retrying'
  if ! recover_container_system > /dev/null; then
    exit 1
  fi

  if ! probe_common_external_domains; then
    exit 1
  fi
}

# @cmd Check container access to host.container.internal
# @arg port TCP port to probe on host.container.internal
doctor::host() {
  hb_init
  local port="${argc_port:-}"
  local resolved=0

  print_heading '🏠' 'Host reachability check'

  if ! status_system > /dev/null; then
    recover_container_system > /dev/null
  fi

  "$start_script" > /dev/null

  if probe_container_dns_name host.container.internal; then
    resolved=1
  elif [ "$expose_host_container_internal" = true ]; then
    if [ "$(/usr/bin/id -u)" -eq 0 ]; then
      "$reconcile_host_container_internal"
    else
      /usr/bin/sudo "$reconcile_host_container_internal"
    fi

    if probe_container_dns_name host.container.internal; then
      resolved=1
    fi
  fi

  if [ "$resolved" -eq 1 ]; then
    print_mark ok 'Builder resolves host.container.internal'
  else
    print_mark fail 'Builder cannot resolve host.container.internal'
    exit 1
  fi

  if [ -z "$port" ]; then
    exit 0
  fi

  case "$port" in
    *[!0-9]* | '')
      print_error "Port must be numeric: $port"
      exit 2
      ;;
  esac

  if [ "$expose_host_container_internal" != true ]; then
    print_error 'host.container.internal exposure is disabled in services.container-builder.exposeHostContainerInternal'
    exit 1
  fi

  if probe_container_tcp_target host.container.internal "$port"; then
    print_mark ok "Builder can reach host.container.internal:$port"
    exit 0
  fi

  if [ "$(/usr/bin/id -u)" -eq 0 ]; then
    "$reconcile_host_container_internal"
  else
    /usr/bin/sudo "$reconcile_host_container_internal"
  fi

  if probe_container_tcp_target host.container.internal "$port"; then
    print_mark ok "Builder can reach host.container.internal:$port"
  else
    print_mark fail "Builder cannot reach host.container.internal:$port"
    exit 1
  fi
}

if [ "$#" -eq 1 ] && [ "$1" = doctor ]; then
  doctor
  exit $?
fi
