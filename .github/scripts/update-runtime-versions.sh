#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
versions_file="$repo_root/modules/runtime-versions.nix"

current_apple_version=$(sed -n '/appleContainer = {/,/};/s/.*version = "\([^"]*\)";.*/\1/p' "$versions_file")
current_apple_url=$(sed -n '/appleContainer = {/,/};/s/.*url = "\([^"]*\)";.*/\1/p' "$versions_file")
current_apple_hash=$(sed -n '/appleContainer = {/,/};/s/.*hash = "\([^"]*\)";.*/\1/p' "$versions_file")
current_socktainer_version=$(sed -n '/socktainer = {/,/};/s/.*version = "\([^"]*\)";.*/\1/p' "$versions_file")
current_socktainer_url=$(sed -n '/socktainer = {/,/};/s/.*url = "\([^"]*\)";.*/\1/p' "$versions_file")
current_socktainer_hash=$(sed -n '/socktainer = {/,/};/s/.*hash = "\([^"]*\)";.*/\1/p' "$versions_file")
current_nix_version=$(sed -n '/nixImage = {/,/};/s/.*version = "\([^"]*\)";.*/\1/p' "$versions_file")

latest_apple_version=$(gh api repos/apple/container/releases/latest --jq '.tag_name')
latest_apple_url=$(gh api repos/apple/container/releases/latest --jq '.assets[] | select(.name == "container-'"$latest_apple_version"'-installer-signed.pkg") | .browser_download_url')

latest_socktainer_version=$(gh api repos/socktainer/socktainer/releases/latest --jq '.tag_name')
latest_socktainer_url=$(gh api repos/socktainer/socktainer/releases/latest --jq '.assets[] | select(.name == "socktainer-installer.pkg") | .browser_download_url')

latest_nix_version=$(curl -fsSL 'https://hub.docker.com/v2/repositories/nixos/nix/tags?page_size=100' | jq -r '.results[] | select(.name | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) | .name' | sort -V | tail -n 1)

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

latest_apple_hash=$current_apple_hash
latest_socktainer_hash=$current_socktainer_hash

if [ "$current_apple_version" != "$latest_apple_version" ]; then
  curl -fsSLo "$tmpdir/apple-container.pkg" "$latest_apple_url"
  latest_apple_hash=$(nix hash file --sri "$tmpdir/apple-container.pkg")
fi

if [ "$current_socktainer_version" != "$latest_socktainer_version" ]; then
  curl -fsSLo "$tmpdir/socktainer.pkg" "$latest_socktainer_url"
  latest_socktainer_hash=$(nix hash file --sri "$tmpdir/socktainer.pkg")
fi

updated=false
apple_updated=false
socktainer_updated=false
nix_updated=false
summary_parts=()

if [ "$current_apple_version" != "$latest_apple_version" ]; then
  python3 - "$versions_file" "$current_apple_version" "$latest_apple_version" "$current_apple_url" "$latest_apple_url" "$current_apple_hash" "$latest_apple_hash" << 'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(f'version = "{sys.argv[2]}";', f'version = "{sys.argv[3]}";', 1)
text = text.replace(f'url = "{sys.argv[4]}";', f'url = "{sys.argv[5]}";', 1)
text = text.replace(f'hash = "{sys.argv[6]}";', f'hash = "{sys.argv[7]}";', 1)
path.write_text(text)
PY
  summary_parts+=("Apple Container ${current_apple_version} to ${latest_apple_version}")
  apple_updated=true
  updated=true
fi

if [ "$current_socktainer_version" != "$latest_socktainer_version" ]; then
  python3 - "$versions_file" "$current_socktainer_version" "$latest_socktainer_version" "$current_socktainer_url" "$latest_socktainer_url" "$current_socktainer_hash" "$latest_socktainer_hash" << 'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(f'version = "{sys.argv[2]}";', f'version = "{sys.argv[3]}";', 1)
text = text.replace(f'url = "{sys.argv[4]}";', f'url = "{sys.argv[5]}";', 1)
text = text.replace(f'hash = "{sys.argv[6]}";', f'hash = "{sys.argv[7]}";', 1)
path.write_text(text)
PY
  summary_parts+=("Socktainer ${current_socktainer_version} to ${latest_socktainer_version}")
  socktainer_updated=true
  updated=true
fi

if [ "$current_nix_version" != "$latest_nix_version" ]; then
  python3 - "$versions_file" "$current_nix_version" "$latest_nix_version" << 'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(f'version = "{sys.argv[2]}";', f'version = "{sys.argv[3]}";', 1)
path.write_text(text)
PY
  summary_parts+=("nixos/nix ${current_nix_version} to ${latest_nix_version}")
  nix_updated=true
  updated=true
fi

if [ "${#summary_parts[@]}" -gt 0 ]; then
  subject="fix: bump ${summary_parts[0]}"
  if [ "${#summary_parts[@]}" -gt 1 ]; then
    for part in "${summary_parts[@]:1}"; do
      subject+=" and ${part}"
    done
  fi
else
  subject="fix: bump runtime version defaults"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "updated=$updated"
    echo "apple_updated=$apple_updated"
    echo "socktainer_updated=$socktainer_updated"
    echo "nix_updated=$nix_updated"
    echo "subject=$subject"
    echo "apple_version=$latest_apple_version"
    echo "socktainer_version=$latest_socktainer_version"
    echo "nix_version=$latest_nix_version"
    echo "current_apple_version=$current_apple_version"
    echo "current_socktainer_version=$current_socktainer_version"
    echo "current_nix_version=$current_nix_version"
  } >> "$GITHUB_OUTPUT"
else
  printf 'updated=%s\n' "$updated"
  printf 'apple_updated=%s\n' "$apple_updated"
  printf 'socktainer_updated=%s\n' "$socktainer_updated"
  printf 'nix_updated=%s\n' "$nix_updated"
  printf 'subject=%s\n' "$subject"
fi
