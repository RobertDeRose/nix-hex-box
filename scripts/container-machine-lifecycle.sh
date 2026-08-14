# shellcheck shell=bash disable=SC2154
# Lifecycle helpers embedded in the generated HexBox machine start script.

machine_status() {
  "$timeout_bin" "$machine_inspect_timeout_seconds" "$container_bin" machine inspect "$machine_name" 2> /dev/null |
    /usr/bin/awk -F'"' '/"status"/ { print $4; exit }'
}

machine_exists() {
  "$timeout_bin" "$machine_inspect_timeout_seconds" "$container_bin" machine inspect "$machine_name" > /dev/null 2>&1
}

machine_absent() {
  local inspect_output
  local inspect_status

  set +e
  inspect_output=$(
    "$timeout_bin" "$machine_inspect_timeout_seconds" "$container_bin" machine inspect "$machine_name" 2>&1
  )
  inspect_status=$?
  set -e
  if [ "$inspect_status" -eq 0 ]; then
    return 1
  fi
  case "$inspect_output" in
    *"not found"* | *"No such"* | *"does not exist"*) return 0 ;;
    *) return 1 ;;
  esac
}

machine_state_known() {
  machine_exists || machine_absent
}

stop_machine() {
  local attempts=$machine_status_attempts
  local current_status

  current_status=$(machine_status || true)
  if [ "$current_status" != stopped ]; then
    "$timeout_bin" "$machine_stop_timeout_seconds" "$container_bin" machine stop "$machine_name" > /dev/null 2>&1 || true
  fi

  while [ "$attempts" -gt 0 ]; do
    current_status=$(machine_status || true)
    if [ "$current_status" = stopped ]; then
      return 0
    fi
    attempts=$((attempts - 1))
    /bin/sleep "$machine_status_interval_seconds"
  done
  echo "hexbox: builder machine $machine_name did not stop" >&2
  "$timeout_bin" "$machine_inspect_timeout_seconds" "$container_bin" machine inspect "$machine_name" >&2 || true
  exit 1
}

machine_run_probe() {
  if boot_output=$(
    "$timeout_bin" "$machine_run_timeout_seconds" "$container_bin" machine run \
      --root -i -n "$machine_name" true < /dev/null 2>&1
  ); then
    return 0
  fi
  return 1
}

try_boot_machine() {
  local attempts=$machine_boot_attempts

  while [ "$attempts" -gt 0 ]; do
    if machine_run_probe; then
      return 0
    fi
    attempts=$((attempts - 1))
    if [ "$attempts" -gt 0 ]; then
      stop_machine
      /bin/sleep "$machine_boot_retry_delay_seconds"
    fi
  done
  return 1
}

boot_machine() {
  if try_boot_machine; then
    return 0
  fi
  echo "hexbox: failed to boot builder machine $machine_name" >&2
  echo "hexbox: container machine run output:" >&2
  printf '%s\n' "$boot_output" >&2
  exit 1
}

create_machine() {
  "$timeout_bin" "$machine_create_timeout_seconds" "$container_bin" machine create "$image_tag" \
    --name "$machine_name" \
    --cpus "$machine_create_cpus" \
    --memory "$machine_create_memory" \
    --home-mount "$machine_create_home_mount"
}

start_container_system() {
  "$timeout_bin" "$machine_system_timeout_seconds" "$container_bin" system start
}

start_container_system_with_kernel_install() {
  "$timeout_bin" "$machine_system_timeout_seconds" "$container_bin" system start --enable-kernel-install
}

restart_container_system() {
  "$timeout_bin" "$machine_system_timeout_seconds" "$container_bin" system stop > /dev/null 2>&1 || true
  start_container_system
}

remove_machine() {
  "$timeout_bin" "$machine_stop_timeout_seconds" "$container_bin" machine stop "$machine_name" > /dev/null 2>&1 || true
  set +e
  rm_output=$(
    "$timeout_bin" "$machine_remove_timeout_seconds" "$container_bin" machine rm "$machine_name" 2>&1
  )
  rm_status=$?
  set -e
  if [ "$rm_status" -ne 0 ] && machine_absent; then
    rm_status=0
  fi
  if [ "$rm_status" -ne 0 ]; then
    echo "hexbox: container machine rm did not complete; restarting Apple container services and retrying" >&2
    set +e
    restart_output=$(restart_container_system 2>&1)
    restart_status=$?
    set -e
    if [ "$restart_status" -eq 0 ]; then
      rm_output=$(
        "$timeout_bin" "$machine_remove_timeout_seconds" "$container_bin" machine rm "$machine_name" 2>&1
      )
      rm_status=$?
    else
      rm_output="$rm_output
hexbox: Apple container service restart output:
$restart_output"
    fi
    if [ "$rm_status" -ne 0 ] && machine_absent; then
      rm_status=0
    fi
  fi
  if [ "$rm_status" -ne 0 ]; then
    echo "hexbox: failed to remove builder machine $machine_name" >&2
    printf '%s\n' "$rm_output" >&2
    exit 1
  fi
}
