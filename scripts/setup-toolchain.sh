#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

sudo apt-get -o Acquire::Retries=5 update -y
sudo apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
  bc bison build-essential ca-certificates ccache cpio curl flex \
  git libelf-dev libssl-dev liblz4-dev libncurses-dev zstd \
  python3 rsync unzip wget xsltproc zip zlib1g-dev device-tree-compiler kmod \
  gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi

ROOT="${GITHUB_WORKSPACE:-$PWD}"
CLANG_DIR="$ROOT/tc/clang"
TARBALL=/tmp/clang-r547379.tar.gz
CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r547379.tar.gz"

if [ ! -x "$CLANG_DIR/bin/clang" ]; then
  mkdir -p "$CLANG_DIR"
  ok=0
  for i in 1 2 3 4 5; do
    rm -f "$TARBALL"
    if curl -fL --retry 5 --retry-all-errors --retry-delay 5 \
         --connect-timeout 30 --max-time 1800 "$CLANG_URL" -o "$TARBALL"; then
      ok=1
      break
    fi
    echo "clang download attempt $i failed; retrying in 15s..."
    sleep 15
  done
  if [ "$ok" != 1 ]; then
    echo "::error::failed to download clang toolchain after 5 attempts"
    exit 1
  fi
  tar -xzf "$TARBALL" -C "$CLANG_DIR"
  rm -f "$TARBALL"
fi

"$CLANG_DIR/bin/clang" --version
