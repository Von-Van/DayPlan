#!/usr/bin/env bash
set -euo pipefail

version=0.32.0
digest=3b12a49c6c4cbafd7ffba5ccba60cbf80274cdc22eea3ead79c646aba888174c
archive="${RUNNER_TEMP:-/tmp}/ollama-darwin-${version}.tgz"
url="https://github.com/ollama/ollama/releases/download/v${version}/ollama-darwin.tgz"
root=src-tauri/resources/ollama

if ! test -f "$archive" || ! echo "$digest  $archive" | shasum -a 256 --check --status; then
  curl --fail --location --retry 3 --output "$archive" "$url"
fi
echo "$digest  $archive" | shasum -a 256 --check
destination="$root/macos-universal"
mkdir -p "$destination"
tar -xzf "$archive" -C "$destination"
test -x "$destination/ollama"
architectures=$(lipo -archs "$destination/ollama")
grep -q arm64 <<< "$architectures"
grep -q x86_64 <<< "$architectures"
