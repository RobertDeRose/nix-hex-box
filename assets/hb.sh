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
  idle_log=${HB_IDLE_LOG:?}
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
      exec /usr/bin/ssh -F "$ssh_config" "$host_alias" "tail -n '$lines' /var/log/hexbox-idle.log"
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
        exec "$container_bin" machine logs --boot "$container_name"
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
  show_logs "$argc_target" "${argc_follow:-0}" "${argc_lines:-100}"
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
      args = [ "-c" "printf ok > $out" ];
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

  "$container_bin" machine run -n "$container_name" --root -- getent hosts "$host" > /dev/null 2>&1
}

probe_container_tcp_target() {
  local host="$1"
  local port="$2"

  "$container_bin" machine run -n "$container_name" --root -- nc -zvw5 "$host" "$port" > /dev/null 2>&1
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

  "$start_script" > /dev/null 2>&1 || true

  if probe_common_external_domains; then
    exit 0
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

  "$start_script" > /dev/null 2>&1 || true

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

# ARGC-BUILD {
# This block was generated by argc (https://github.com/sigoden/argc).
# Modifying it manually is not recommended

_argc_run() {
  if [[ ${1:-} == "___internal___" ]]; then
    _argc_die "error: unsupported ___internal___ command"
  fi
  if [[ ${OS:-} == "Windows_NT" ]] && [[ -n ${MSYSTEM:-} ]]; then
    set -o igncr
  fi
  argc__args=("$(basename "$0" .sh)" "$@")
  argc__positionals=()
  _argc_index=1
  _argc_len="${#argc__args[@]}"
  _argc_tools=()
  _argc_parse
  if [ -n "${argc__fn:-}" ]; then
    $argc__fn "${argc__positionals[@]}"
  fi
}

_argc_usage() {
  cat <<- 'EOF'
Helper CLI for nix-hex-box container-builder operations

USAGE: hb <COMMAND>

COMMANDS:
  builder     Builder operations
  socktainer  Manage Socktainer
  doctor      Run runtime and connectivity diagnostics
EOF
  exit
}

_argc_version() {
  echo hb 0.0.0
  exit
}

_argc_parse() {
  local _argc_key _argc_action
  local _argc_subcmds="builder, socktainer, doctor"
  while [[ $_argc_index -lt $_argc_len ]]; do
    _argc_item="${argc__args[_argc_index]}"
    _argc_key="${_argc_item%%=*}"
    case "$_argc_key" in
      --help | -help | -h)
        _argc_usage
        ;;
      --version | -version | -V)
        _argc_version
        ;;
      --)
        _argc_dash="${#argc__positionals[@]}"
        argc__positionals+=("${argc__args[@]:$((_argc_index + 1))}")
        _argc_index=$_argc_len
        break
        ;;
      builder)
        _argc_index=$((_argc_index + 1))
        _argc_action=_argc_parse_builder
        break
        ;;
      socktainer)
        _argc_index=$((_argc_index + 1))
        _argc_action=_argc_parse_socktainer
        break
        ;;
      doctor)
        _argc_index=$((_argc_index + 1))
        _argc_action=_argc_parse_doctor
        break
        ;;
      help)
        local help_arg="${argc__args[$((_argc_index + 1))]:-}"
        case "$help_arg" in
          builder)
            _argc_usage_builder
            ;;
          socktainer)
            _argc_usage_socktainer
            ;;
          doctor)
            _argc_usage_doctor
            ;;
          "")
            _argc_usage
            ;;
          *)
            _argc_die "error: invalid value \`$help_arg\` for \`<command>\`"$'\n'"  [possible values: $_argc_subcmds]"
            ;;
        esac
        ;;
      *)
        _argc_die 'error: `hb` requires a subcommand but one was not provided'$'\n'"  [subcommands: $_argc_subcmds]"
        ;;
    esac
  done
  if [[ -n ${_argc_action:-} ]]; then
    $_argc_action
  else
    _argc_usage
  fi
}

_argc_usage_builder() {
  cat <<- 'EOF'
Builder operations

USAGE: hb builder <COMMAND>

COMMANDS:
  status   Show builder status summary
  logs     Show builder logs
  test     Run a simple remote build smoke test through the builder
  repair   Verify builder health and recover runtime if needed
  reset    Destroy and recreate the builder machine
  gc       Run nix garbage collection inside the builder
  inspect  Show raw launchd and container inspection data
  ssh      Open an SSH session to the builder
EOF
  exit
}

_argc_parse_builder() {
  local _argc_key _argc_action
  local _argc_subcmds="status, logs, test, repair, reset, gc, inspect, ssh"
  while [[ $_argc_index -lt $_argc_len ]]; do
    _argc_item="${argc__args[_argc_index]}"
    _argc_key="${_argc_item%%=*}"
    case "$_argc_key" in
      --help | -help | -h)
        _argc_usage_builder
        ;;
      --)
        _argc_dash="${#argc__positionals[@]}"
        argc__positionals+=("${argc__args[@]:$((_argc_index + 1))}")
        _argc_index=$_argc_len
        break
        ;;
      status)
        _argc_index=$((_argc_index + 1))
        _argc_action=_argc_parse_builder_status
        break
        ;;
      logs)
        _argc_index=$((_argc_index + 1))
        _argc_action=_argc_parse_builder_logs
        break
        ;;
      test)
        _argc_index=$((_argc_index + 1))
        _argc_action=_argc_parse_builder_test
        break
        ;;
      repair)
        _argc_index=$((_argc_index + 1))
        _argc_action=_argc_parse_builder_repair
        break
        ;;
      reset)
        _argc_index=$((_argc_index + 1))
        _argc_action=_argc_parse_builder_reset
        break
        ;;
      gc)
        _argc_index=$((_argc_index + 1))
        _argc_action=_argc_parse_builder_gc
        break
        ;;
      inspect)
        _argc_index=$((_argc_index + 1))
        _argc_action=_argc_parse_builder_inspect
        break
        ;;
      ssh)
        _argc_index=$((_argc_index + 1))
        _argc_action=_argc_parse_builder_ssh
        break
        ;;
      help)
        local help_arg="${argc__args[$((_argc_index + 1))]:-}"
        case "$help_arg" in
          status)
            _argc_usage_builder_status
            ;;
          logs)
            _argc_usage_builder_logs
            ;;
          test)
            _argc_usage_builder_test
            ;;
          repair)
            _argc_usage_builder_repair
            ;;
          reset)
            _argc_usage_builder_reset
            ;;
          gc)
            _argc_usage_builder_gc
            ;;
          inspect)
            _argc_usage_builder_inspect
            ;;
          ssh)
            _argc_usage_builder_ssh
            ;;
          "")
            _argc_usage_builder
            ;;
          *)
            _argc_die "error: invalid value \`$help_arg\` for \`<command>\`"$'\n'"  [possible values: $_argc_subcmds]"
            ;;
        esac
        ;;
      *)
        _argc_die 'error: `hb-builder` requires a subcommand but one was not provided'$'\n'"  [subcommands: $_argc_subcmds]"
        ;;
    esac
  done
  if [[ -n ${_argc_action:-} ]]; then
    $_argc_action
  else
    _argc_usage_builder
  fi
}

_argc_usage_builder_status() {
  cat <<- 'EOF'
Show builder status summary

USAGE: hb builder status
EOF
  exit
}

_argc_parse_builder_status() {
  local _argc_key _argc_action
  local _argc_subcmds=""
  while [[ $_argc_index -lt $_argc_len ]]; do
    _argc_item="${argc__args[_argc_index]}"
    _argc_key="${_argc_item%%=*}"
    case "$_argc_key" in
      --help | -help | -h)
        _argc_usage_builder_status
        ;;
      --)
        _argc_dash="${#argc__positionals[@]}"
        argc__positionals+=("${argc__args[@]:$((_argc_index + 1))}")
        _argc_index=$_argc_len
        break
        ;;
      *)
        argc__positionals+=("$_argc_item")
        _argc_index=$((_argc_index + 1))
        ;;
    esac
  done
  if [[ -n ${_argc_action:-} ]]; then
    $_argc_action
  else
    argc__fn=builder::status
    if [[ ${argc__positionals[0]:-} == "help" ]] && [[ ${#argc__positionals[@]} -eq 1 ]]; then
      _argc_usage_builder_status
    fi
  fi
}

_argc_usage_builder_logs() {
  cat <<- 'EOF'
Show builder logs

USAGE: hb builder logs [OPTIONS] <TARGET>

ARGS:
  <TARGET>  Log target [possible values: idle, readiness, boot]

OPTIONS:
  -f, --follow         Follow log output
  -n, --lines <LINES>  Number of lines to show
  -h, --help           Print help
EOF
  exit
}

_argc_parse_builder_logs() {
  local _argc_key _argc_action
  local _argc_subcmds=""
  while [[ $_argc_index -lt $_argc_len ]]; do
    _argc_item="${argc__args[_argc_index]}"
    _argc_key="${_argc_item%%=*}"
    case "$_argc_key" in
      --help | -help | -h)
        _argc_usage_builder_logs
        ;;
      --)
        _argc_dash="${#argc__positionals[@]}"
        argc__positionals+=("${argc__args[@]:$((_argc_index + 1))}")
        _argc_index=$_argc_len
        break
        ;;
      --follow | -f)
        if [[ $_argc_item == *=* ]]; then
          _argc_die "error: flag \`--follow\` don't accept any value"
        fi
        _argc_index=$((_argc_index + 1))
        if [[ -n ${argc_follow:-} ]]; then
          _argc_die 'error: the argument `--follow` cannot be used multiple times'
        else
          argc_follow=1
        fi
        ;;
      --lines | -n)
        _argc_take_args "--lines <LINES>" 1 1 "-" ""
        _argc_index=$((_argc_index + _argc_take_args_len + 1))
        if [[ -z ${argc_lines:-} ]]; then
          argc_lines="${_argc_take_args_values[0]:-}"
        else
          _argc_die 'error: the argument `--lines` cannot be used multiple times'
        fi
        ;;
      *)
        if _argc_maybe_flag_option "-" "$_argc_item"; then
          _argc_die "error: unexpected argument \`$_argc_key\` found"
        fi
        argc__positionals+=("$_argc_item")
        _argc_index=$((_argc_index + 1))
        ;;
    esac
  done
  if [[ -n ${_argc_action:-} ]]; then
    $_argc_action
  else
    argc__fn=builder::logs
    if [[ ${argc__positionals[0]:-} == "help" ]] && [[ ${#argc__positionals[@]} -eq 1 ]]; then
      _argc_usage_builder_logs
    fi
    _argc_match_positionals 0
    local values_index values_size
    IFS=: read -r values_index values_size <<< "${_argc_match_positionals_values[0]:-}"
    if [[ -n $values_index ]]; then
      argc_target="${argc__positionals[values_index]}"
      _argc_validate_choices '`<TARGET>`' "$(printf "%s\n" idle readiness boot)" "$argc_target"
    else
      _argc_die 'error: the required environments `<TARGET>` were not provided'
    fi
  fi
}

_argc_usage_builder_test() {
  cat <<- 'EOF'
Run a simple remote build smoke test through the builder

USAGE: hb builder test
EOF
  exit
}

_argc_parse_builder_test() {
  local _argc_key _argc_action
  local _argc_subcmds=""
  while [[ $_argc_index -lt $_argc_len ]]; do
    _argc_item="${argc__args[_argc_index]}"
    _argc_key="${_argc_item%%=*}"
    case "$_argc_key" in
      --help | -help | -h)
        _argc_usage_builder_test
        ;;
      --)
        _argc_dash="${#argc__positionals[@]}"
        argc__positionals+=("${argc__args[@]:$((_argc_index + 1))}")
        _argc_index=$_argc_len
        break
        ;;
      *)
        argc__positionals+=("$_argc_item")
        _argc_index=$((_argc_index + 1))
        ;;
    esac
  done
  if [[ -n ${_argc_action:-} ]]; then
    $_argc_action
  else
    argc__fn=builder::test
    if [[ ${argc__positionals[0]:-} == "help" ]] && [[ ${#argc__positionals[@]} -eq 1 ]]; then
      _argc_usage_builder_test
    fi
  fi
}

_argc_usage_builder_repair() {
  cat <<- 'EOF'
Verify builder health and recover runtime if needed

USAGE: hb builder repair
EOF
  exit
}

_argc_parse_builder_repair() {
  local _argc_key _argc_action
  local _argc_subcmds=""
  while [[ $_argc_index -lt $_argc_len ]]; do
    _argc_item="${argc__args[_argc_index]}"
    _argc_key="${_argc_item%%=*}"
    case "$_argc_key" in
      --help | -help | -h)
        _argc_usage_builder_repair
        ;;
      --)
        _argc_dash="${#argc__positionals[@]}"
        argc__positionals+=("${argc__args[@]:$((_argc_index + 1))}")
        _argc_index=$_argc_len
        break
        ;;
      *)
        argc__positionals+=("$_argc_item")
        _argc_index=$((_argc_index + 1))
        ;;
    esac
  done
  if [[ -n ${_argc_action:-} ]]; then
    $_argc_action
  else
    argc__fn=builder::repair
    if [[ ${argc__positionals[0]:-} == "help" ]] && [[ ${#argc__positionals[@]} -eq 1 ]]; then
      _argc_usage_builder_repair
    fi
  fi
}

_argc_usage_builder_reset() {
  cat <<- 'EOF'
Destroy and recreate the builder machine

USAGE: hb builder reset
EOF
  exit
}

_argc_parse_builder_reset() {
  local _argc_key _argc_action
  local _argc_subcmds=""
  while [[ $_argc_index -lt $_argc_len ]]; do
    _argc_item="${argc__args[_argc_index]}"
    _argc_key="${_argc_item%%=*}"
    case "$_argc_key" in
      --help | -help | -h)
        _argc_usage_builder_reset
        ;;
      --)
        _argc_dash="${#argc__positionals[@]}"
        argc__positionals+=("${argc__args[@]:$((_argc_index + 1))}")
        _argc_index=$_argc_len
        break
        ;;
      *)
        argc__positionals+=("$_argc_item")
        _argc_index=$((_argc_index + 1))
        ;;
    esac
  done
  if [[ -n ${_argc_action:-} ]]; then
    $_argc_action
  else
    argc__fn=builder::reset
    if [[ ${argc__positionals[0]:-} == "help" ]] && [[ ${#argc__positionals[@]} -eq 1 ]]; then
      _argc_usage_builder_reset
    fi
  fi
}

_argc_usage_builder_gc() {
  cat <<- 'EOF'
Run nix garbage collection inside the builder

USAGE: hb builder gc
EOF
  exit
}

_argc_parse_builder_gc() {
  local _argc_key _argc_action
  local _argc_subcmds=""
  while [[ $_argc_index -lt $_argc_len ]]; do
    _argc_item="${argc__args[_argc_index]}"
    _argc_key="${_argc_item%%=*}"
    case "$_argc_key" in
      --help | -help | -h)
        _argc_usage_builder_gc
        ;;
      --)
        _argc_dash="${#argc__positionals[@]}"
        argc__positionals+=("${argc__args[@]:$((_argc_index + 1))}")
        _argc_index=$_argc_len
        break
        ;;
      *)
        argc__positionals+=("$_argc_item")
        _argc_index=$((_argc_index + 1))
        ;;
    esac
  done
  if [[ -n ${_argc_action:-} ]]; then
    $_argc_action
  else
    argc__fn=builder::gc
    if [[ ${argc__positionals[0]:-} == "help" ]] && [[ ${#argc__positionals[@]} -eq 1 ]]; then
      _argc_usage_builder_gc
    fi
  fi
}

_argc_usage_builder_inspect() {
  cat <<- 'EOF'
Show raw launchd and container inspection data

USAGE: hb builder inspect
EOF
  exit
}

_argc_parse_builder_inspect() {
  local _argc_key _argc_action
  local _argc_subcmds=""
  while [[ $_argc_index -lt $_argc_len ]]; do
    _argc_item="${argc__args[_argc_index]}"
    _argc_key="${_argc_item%%=*}"
    case "$_argc_key" in
      --help | -help | -h)
        _argc_usage_builder_inspect
        ;;
      --)
        _argc_dash="${#argc__positionals[@]}"
        argc__positionals+=("${argc__args[@]:$((_argc_index + 1))}")
        _argc_index=$_argc_len
        break
        ;;
      *)
        argc__positionals+=("$_argc_item")
        _argc_index=$((_argc_index + 1))
        ;;
    esac
  done
  if [[ -n ${_argc_action:-} ]]; then
    $_argc_action
  else
    argc__fn=builder::inspect
    if [[ ${argc__positionals[0]:-} == "help" ]] && [[ ${#argc__positionals[@]} -eq 1 ]]; then
      _argc_usage_builder_inspect
    fi
  fi
}

_argc_usage_builder_ssh() {
  cat <<- 'EOF'
Open an SSH session to the builder

USAGE: hb builder ssh [ARGS]...

ARGS:
  [ARGS]...
EOF
  exit
}

_argc_parse_builder_ssh() {
  local _argc_key _argc_action
  local _argc_subcmds=""
  while [[ $_argc_index -lt $_argc_len ]]; do
    _argc_item="${argc__args[_argc_index]}"
    _argc_key="${_argc_item%%=*}"
    case "$_argc_key" in
      *)
        argc__positionals+=("$_argc_item")
        _argc_index=$((_argc_index + 1))
        if [[ ${#argc__positionals[@]} -ge 0 ]]; then
          argc__positionals+=("${argc__args[@]:_argc_index}")
          _argc_index=$_argc_len
        fi
        ;;
    esac
  done
  if [[ -n ${_argc_action:-} ]]; then
    $_argc_action
  else
    argc__fn=builder::ssh
    if [[ ${argc__positionals[0]:-} == "help" ]] && [[ ${#argc__positionals[@]} -eq 1 ]]; then
      _argc_usage_builder_ssh
    fi
    _argc_match_positionals 1
    local values_index values_size
    IFS=: read -r values_index values_size <<< "${_argc_match_positionals_values[0]:-}"
    if [[ -n $values_index ]]; then
      argc_args=("${argc__positionals[@]:values_index:values_size}")
    fi
  fi
}

_argc_usage_socktainer() {
  cat <<- 'EOF'
Manage Socktainer

USAGE: hb socktainer <COMMAND>

COMMANDS:
  status  Show Socktainer status
  logs    Show Socktainer logs
EOF
  exit
}

_argc_parse_socktainer() {
  local _argc_key _argc_action
  local _argc_subcmds="status, logs"
  while [[ $_argc_index -lt $_argc_len ]]; do
    _argc_item="${argc__args[_argc_index]}"
    _argc_key="${_argc_item%%=*}"
    case "$_argc_key" in
      --help | -help | -h)
        _argc_usage_socktainer
        ;;
      --)
        _argc_dash="${#argc__positionals[@]}"
        argc__positionals+=("${argc__args[@]:$((_argc_index + 1))}")
        _argc_index=$_argc_len
        break
        ;;
      status)
        _argc_index=$((_argc_index + 1))
        _argc_action=_argc_parse_socktainer_status
        break
        ;;
      logs)
        _argc_index=$((_argc_index + 1))
        _argc_action=_argc_parse_socktainer_logs
        break
        ;;
      help)
        local help_arg="${argc__args[$((_argc_index + 1))]:-}"
        case "$help_arg" in
          status)
            _argc_usage_socktainer_status
            ;;
          logs)
            _argc_usage_socktainer_logs
            ;;
          "")
            _argc_usage_socktainer
            ;;
          *)
            _argc_die "error: invalid value \`$help_arg\` for \`<command>\`"$'\n'"  [possible values: $_argc_subcmds]"
            ;;
        esac
        ;;
      *)
        _argc_die 'error: `hb-socktainer` requires a subcommand but one was not provided'$'\n'"  [subcommands: $_argc_subcmds]"
        ;;
    esac
  done
  if [[ -n ${_argc_action:-} ]]; then
    $_argc_action
  else
    _argc_usage_socktainer
  fi
}

_argc_usage_socktainer_status() {
  cat <<- 'EOF'
Show Socktainer status

USAGE: hb socktainer status
EOF
  exit
}

_argc_parse_socktainer_status() {
  local _argc_key _argc_action
  local _argc_subcmds=""
  while [[ $_argc_index -lt $_argc_len ]]; do
    _argc_item="${argc__args[_argc_index]}"
    _argc_key="${_argc_item%%=*}"
    case "$_argc_key" in
      --help | -help | -h)
        _argc_usage_socktainer_status
        ;;
      --)
        _argc_dash="${#argc__positionals[@]}"
        argc__positionals+=("${argc__args[@]:$((_argc_index + 1))}")
        _argc_index=$_argc_len
        break
        ;;
      *)
        argc__positionals+=("$_argc_item")
        _argc_index=$((_argc_index + 1))
        ;;
    esac
  done
  if [[ -n ${_argc_action:-} ]]; then
    $_argc_action
  else
    argc__fn=socktainer::status
    if [[ ${argc__positionals[0]:-} == "help" ]] && [[ ${#argc__positionals[@]} -eq 1 ]]; then
      _argc_usage_socktainer_status
    fi
  fi
}

_argc_usage_socktainer_logs() {
  cat <<- 'EOF'
Show Socktainer logs

USAGE: hb socktainer logs [OPTIONS]

OPTIONS:
  -f, --follow  Follow log output
  -h, --help    Print help
EOF
  exit
}

_argc_parse_socktainer_logs() {
  local _argc_key _argc_action
  local _argc_subcmds=""
  while [[ $_argc_index -lt $_argc_len ]]; do
    _argc_item="${argc__args[_argc_index]}"
    _argc_key="${_argc_item%%=*}"
    case "$_argc_key" in
      --help | -help | -h)
        _argc_usage_socktainer_logs
        ;;
      --)
        _argc_dash="${#argc__positionals[@]}"
        argc__positionals+=("${argc__args[@]:$((_argc_index + 1))}")
        _argc_index=$_argc_len
        break
        ;;
      --follow | -f)
        if [[ $_argc_item == *=* ]]; then
          _argc_die "error: flag \`--follow\` don't accept any value"
        fi
        _argc_index=$((_argc_index + 1))
        if [[ -n ${argc_follow:-} ]]; then
          _argc_die 'error: the argument `--follow` cannot be used multiple times'
        else
          argc_follow=1
        fi
        ;;
      *)
        if _argc_maybe_flag_option "-" "$_argc_item"; then
          _argc_die "error: unexpected argument \`$_argc_key\` found"
        fi
        argc__positionals+=("$_argc_item")
        _argc_index=$((_argc_index + 1))
        ;;
    esac
  done
  if [[ -n ${_argc_action:-} ]]; then
    $_argc_action
  else
    argc__fn=socktainer::logs
    if [[ ${argc__positionals[0]:-} == "help" ]] && [[ ${#argc__positionals[@]} -eq 1 ]]; then
      _argc_usage_socktainer_logs
    fi
  fi
}

_argc_usage_doctor() {
  cat <<- 'EOF'
Run runtime and connectivity diagnostics

USAGE: hb doctor <COMMAND>

COMMANDS:
  runtime  Check and recover Apple container runtime
  dns      Check container access to common external domains
  host     Check container access to host.container.internal
EOF
  exit
}

_argc_parse_doctor() {
  local _argc_key _argc_action
  local _argc_subcmds="runtime, dns, host"
  while [[ $_argc_index -lt $_argc_len ]]; do
    _argc_item="${argc__args[_argc_index]}"
    _argc_key="${_argc_item%%=*}"
    case "$_argc_key" in
      --help | -help | -h)
        _argc_usage_doctor
        ;;
      --)
        _argc_dash="${#argc__positionals[@]}"
        argc__positionals+=("${argc__args[@]:$((_argc_index + 1))}")
        _argc_index=$_argc_len
        break
        ;;
      runtime)
        _argc_index=$((_argc_index + 1))
        _argc_action=_argc_parse_doctor_runtime
        break
        ;;
      dns)
        _argc_index=$((_argc_index + 1))
        _argc_action=_argc_parse_doctor_dns
        break
        ;;
      host)
        _argc_index=$((_argc_index + 1))
        _argc_action=_argc_parse_doctor_host
        break
        ;;
      help)
        local help_arg="${argc__args[$((_argc_index + 1))]:-}"
        case "$help_arg" in
          runtime)
            _argc_usage_doctor_runtime
            ;;
          dns)
            _argc_usage_doctor_dns
            ;;
          host)
            _argc_usage_doctor_host
            ;;
          "")
            _argc_usage_doctor
            ;;
          *)
            _argc_die "error: invalid value \`$help_arg\` for \`<command>\`"$'\n'"  [possible values: $_argc_subcmds]"
            ;;
        esac
        ;;
      *)
        _argc_die 'error: `hb-doctor` requires a subcommand but one was not provided'$'\n'"  [subcommands: $_argc_subcmds]"
        ;;
    esac
  done
  if [[ -n ${_argc_action:-} ]]; then
    $_argc_action
  else
    _argc_usage_doctor
  fi
}

_argc_usage_doctor_runtime() {
  cat <<- 'EOF'
Check and recover Apple container runtime

USAGE: hb doctor runtime
EOF
  exit
}

_argc_parse_doctor_runtime() {
  local _argc_key _argc_action
  local _argc_subcmds=""
  while [[ $_argc_index -lt $_argc_len ]]; do
    _argc_item="${argc__args[_argc_index]}"
    _argc_key="${_argc_item%%=*}"
    case "$_argc_key" in
      --help | -help | -h)
        _argc_usage_doctor_runtime
        ;;
      --)
        _argc_dash="${#argc__positionals[@]}"
        argc__positionals+=("${argc__args[@]:$((_argc_index + 1))}")
        _argc_index=$_argc_len
        break
        ;;
      *)
        argc__positionals+=("$_argc_item")
        _argc_index=$((_argc_index + 1))
        ;;
    esac
  done
  if [[ -n ${_argc_action:-} ]]; then
    $_argc_action
  else
    argc__fn=doctor::runtime
    if [[ ${argc__positionals[0]:-} == "help" ]] && [[ ${#argc__positionals[@]} -eq 1 ]]; then
      _argc_usage_doctor_runtime
    fi
  fi
}

_argc_usage_doctor_dns() {
  cat <<- 'EOF'
Check container access to common external domains

USAGE: hb doctor dns
EOF
  exit
}

_argc_parse_doctor_dns() {
  local _argc_key _argc_action
  local _argc_subcmds=""
  while [[ $_argc_index -lt $_argc_len ]]; do
    _argc_item="${argc__args[_argc_index]}"
    _argc_key="${_argc_item%%=*}"
    case "$_argc_key" in
      --help | -help | -h)
        _argc_usage_doctor_dns
        ;;
      --)
        _argc_dash="${#argc__positionals[@]}"
        argc__positionals+=("${argc__args[@]:$((_argc_index + 1))}")
        _argc_index=$_argc_len
        break
        ;;
      *)
        argc__positionals+=("$_argc_item")
        _argc_index=$((_argc_index + 1))
        ;;
    esac
  done
  if [[ -n ${_argc_action:-} ]]; then
    $_argc_action
  else
    argc__fn=doctor::dns
    if [[ ${argc__positionals[0]:-} == "help" ]] && [[ ${#argc__positionals[@]} -eq 1 ]]; then
      _argc_usage_doctor_dns
    fi
  fi
}

_argc_usage_doctor_host() {
  cat <<- 'EOF'
Check container access to host.container.internal

USAGE: hb doctor host [PORT]

ARGS:
  [PORT]  TCP port to probe on host.container.internal
EOF
  exit
}

_argc_parse_doctor_host() {
  local _argc_key _argc_action
  local _argc_subcmds=""
  while [[ $_argc_index -lt $_argc_len ]]; do
    _argc_item="${argc__args[_argc_index]}"
    _argc_key="${_argc_item%%=*}"
    case "$_argc_key" in
      --help | -help | -h)
        _argc_usage_doctor_host
        ;;
      --)
        _argc_dash="${#argc__positionals[@]}"
        argc__positionals+=("${argc__args[@]:$((_argc_index + 1))}")
        _argc_index=$_argc_len
        break
        ;;
      *)
        argc__positionals+=("$_argc_item")
        _argc_index=$((_argc_index + 1))
        ;;
    esac
  done
  if [[ -n ${_argc_action:-} ]]; then
    $_argc_action
  else
    argc__fn=doctor::host
    if [[ ${argc__positionals[0]:-} == "help" ]] && [[ ${#argc__positionals[@]} -eq 1 ]]; then
      _argc_usage_doctor_host
    fi
    _argc_match_positionals 0
    local values_index values_size
    IFS=: read -r values_index values_size <<< "${_argc_match_positionals_values[0]:-}"
    if [[ -n $values_index ]]; then
      argc_port="${argc__positionals[values_index]}"
    fi
  fi
}

_argc_take_args() {
  _argc_take_args_values=()
  _argc_take_args_len=0
  local param="$1" min="$2" max="$3" signs="$4" delimiter="$5"
  if [[ $min -eq 0 ]] && [[ $max -eq 0 ]]; then
    return
  fi
  local _argc_take_index=$((_argc_index + 1)) _argc_take_value
  if [[ $_argc_item == *=* ]]; then
    _argc_take_args_values=("${_argc_item##*=}")
  else
    while [[ $_argc_take_index -lt $_argc_len ]]; do
      _argc_take_value="${argc__args[_argc_take_index]}"
      if _argc_maybe_flag_option "$signs" "$_argc_take_value"; then
        if [[ ${#_argc_take_value} -gt 1 ]]; then
          break
        fi
      fi
      _argc_take_args_values+=("$_argc_take_value")
      _argc_take_args_len=$((_argc_take_args_len + 1))
      if [[ $_argc_take_args_len -ge $max ]]; then
        break
      fi
      _argc_take_index=$((_argc_take_index + 1))
    done
  fi
  if [[ ${#_argc_take_args_values[@]} -lt $min ]]; then
    _argc_die "error: incorrect number of values for \`$param\`"
  fi
  if [[ -n $delimiter ]] && [[ ${#_argc_take_args_values[@]} -gt 0 ]]; then
    local item values arr=()
    for item in "${_argc_take_args_values[@]}"; do
      IFS="$delimiter" read -r -a values <<< "$item"
      arr+=("${values[@]}")
    done
    _argc_take_args_values=("${arr[@]}")
  fi
}

_argc_match_positionals() {
  _argc_match_positionals_values=()
  _argc_match_positionals_len=0
  local params=("$@")
  local args_len="${#argc__positionals[@]}"
  if [[ $args_len -eq 0 ]]; then
    return
  fi
  local params_len=$# arg_index=0 param_index=0
  while [[ $param_index -lt $params_len && $arg_index -lt $args_len ]]; do
    local takes=0
    if [[ ${params[param_index]} -eq 1 ]]; then
      if [[ $param_index -eq 0 ]] &&
        [[ ${_argc_dash:-} -gt 0 ]] &&
        [[ $params_len -eq 2 ]] &&
        [[ ${params[$((param_index + 1))]} -eq 1 ]] \
        ; then
        takes=${_argc_dash:-}
      else
        local arg_diff=$((args_len - arg_index)) param_diff=$((params_len - param_index))
        if [[ $arg_diff -gt $param_diff ]]; then
          takes=$((arg_diff - param_diff + 1))
        else
          takes=1
        fi
      fi
    else
      takes=1
    fi
    _argc_match_positionals_values+=("$arg_index:$takes")
    arg_index=$((arg_index + takes))
    param_index=$((param_index + 1))
  done
  if [[ $arg_index -lt $args_len ]]; then
    _argc_match_positionals_values+=("$arg_index:$((args_len - arg_index))")
  fi
  _argc_match_positionals_len=${#_argc_match_positionals_values[@]}
  if [[ $params_len -gt 0 ]] && [[ $_argc_match_positionals_len -gt $params_len ]]; then
    local index="${_argc_match_positionals_values[params_len]%%:*}"
    _argc_die "error: unexpected argument \`${argc__positionals[index]}\` found"
  fi
}

_argc_validate_choices() {
  local render_name="$1" raw_choices="$2" choices item choice concated_choices=""
  while IFS= read -r line; do
    choices+=("$line")
  done <<< "$raw_choices"
  for choice in "${choices[@]}"; do
    if [[ -z $concated_choices ]]; then
      concated_choices="$choice"
    else
      concated_choices="$concated_choices, $choice"
    fi
  done
  for item in "${@:3}"; do
    local pass=0 choice
    for choice in "${choices[@]}"; do
      if [[ $item == "$choice" ]]; then
        pass=1
      fi
    done
    if [[ $pass -ne 1 ]]; then
      _argc_die "error: invalid value \`$item\` for $render_name"$'\n'"  [possible values: $concated_choices]"
    fi
  done
}

_argc_maybe_flag_option() {
  local signs="$1" arg="$2"
  if [[ -z $signs ]]; then
    return 1
  fi
  local cond=false
  if [[ $signs == *"+"* ]]; then
    if [[ $arg =~ ^\+[^+].* ]]; then
      cond=true
    fi
  elif [[ $arg == -* ]]; then
    if ((${#arg} < 3)) || [[ ! $arg =~ ^---.* ]]; then
      cond=true
    fi
  fi
  if [[ $cond == "false" ]]; then
    return 1
  fi
  local value="${arg%%=*}"
  if [[ $value =~ [[:space:]] ]]; then
    return 1
  fi
  return 0
}

_argc_die() {
  if [[ $# -eq 0 ]]; then
    cat
  else
    echo "$*" >&2
  fi
  exit 1
}

_argc_run "$@"

# ARGC-BUILD }
