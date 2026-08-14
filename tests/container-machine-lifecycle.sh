#!/usr/bin/env bash
# shellcheck shell=bash disable=SC1091,SC2034
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

fake_timeout="$tmp_dir/timeout"
fake_container="$tmp_dir/container"
state_file="$tmp_dir/state"
log_file="$tmp_dir/container.log"

cat > "$fake_timeout" << 'EOF'
#!/bin/sh
shift
exec "$@"
EOF
chmod 0755 "$fake_timeout"

cat > "$fake_container" << 'EOF'
#!/bin/sh
set -eu

state_file=${STATE_FILE:?}
log_file=${LOG_FILE:?}
printf '%s\n' "$*" >> "$log_file"

if [ "$1" = machine ] && [ "$2" = inspect ]; then
  state=$(cat "$state_file")
  case "$state" in
    missing) printf '%s\n' 'container machine not found' >&2; exit 1 ;;
    stopped) printf '[{"status":"stopped"}]\n' ;;
    running) printf '[{"status":"running"}]\n' ;;
    running-dead) printf '[{"status":"running"}]\n' ;;
    *) printf 'unknown state: %s\n' "$state" >&2; exit 2 ;;
  esac
  exit 0
fi

if [ "$1" = machine ] && [ "$2" = create ]; then
  case " $* " in
    *' --no-boot '*) printf '%s\n' 'machine create must use its normal boot path' >&2; exit 3 ;;
  esac
  printf '%s\n' running > "$state_file"
  exit 0
fi

if [ "$1" = machine ] && [ "$2" = run ]; then
  state=$(cat "$state_file")
  case "$state" in
    running-dead)
      exit 1
      ;;
    stopped)
      printf '%s\n' running > "$state_file"
      exit 0
      ;;
    running)
      exit 0
      ;;
    *)
      printf 'cannot run from state: %s\n' "$state" >&2
      exit 1
      ;;
  esac
fi

if [ "$1" = machine ] && [ "$2" = stop ]; then
  printf '%s\n' stopped > "$state_file"
  exit 0
fi

printf 'unexpected fake container command: %s\n' "$*" >&2
exit 4
EOF
chmod 0755 "$fake_container"

export STATE_FILE="$state_file"
export LOG_FILE="$log_file"
container_bin="$fake_container"
timeout_bin="$fake_timeout"
machine_name=nix-builder
image_tag=example/builder:latest
machine_create_cpus=4
machine_create_memory=8G
machine_create_home_mount=none
machine_create_timeout_seconds=300
machine_inspect_timeout_seconds=15
machine_run_timeout_seconds=60
machine_stop_timeout_seconds=30
machine_status_attempts=3
machine_status_interval_seconds=0
machine_boot_attempts=3
machine_boot_retry_delay_seconds=0

# shellcheck source=../scripts/container-machine-lifecycle.sh
source "$script_dir/scripts/container-machine-lifecycle.sh"

assert_log_contains() {
  local expected=$1
  grep -F -- "$expected" "$log_file" > /dev/null
}

assert_log_not_contains() {
  local unexpected=$1
  if grep -F -- "$unexpected" "$log_file" > /dev/null; then
    printf 'unexpected command in fake container log: %s\n' "$unexpected" >&2
    return 1
  fi
}

: > "$log_file"
printf '%s\n' missing > "$state_file"
machine_state_known
create_machine
assert_log_contains 'machine create example/builder:latest --name nix-builder'
assert_log_not_contains '--no-boot'

: > "$log_file"
printf '%s\n' stopped > "$state_file"
boot_machine
assert_log_contains 'machine run --root -i -n nix-builder true'
assert_log_not_contains '/sbin/init'
[ "$(cat "$state_file")" = running ]

: > "$log_file"
printf '%s\n' running-dead > "$state_file"
boot_machine
[ "$(cat "$state_file")" = running ]
assert_log_contains 'machine stop nix-builder'
[ "$(grep -c '^machine run --root -i -n nix-builder true$' "$log_file")" -eq 2 ]
[ "$(grep -c '^machine stop nix-builder$' "$log_file")" -eq 1 ]

printf '%s\n' 'container machine lifecycle tests passed'
