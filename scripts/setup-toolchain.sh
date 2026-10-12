#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  bc bison build-essential ca-certificates ccache cpio curl flex \
  git libelf-dev libssl-dev liblz4-dev libncurses-dev zstd \
  python3 rsync unzip wget xsltproc zip zlib1g-dev device-tree-compiler kmod \
  gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi

ROOT="${GITHUB_WORKSPACE:-$PWD}"
CLANG_DIR="$ROOT/tc/clang"
TARBALL=/tmp/clang-r547379.tar.gz

if [ ! -x "$CLANG_DIR/bin/clang" ]; then
  mkdir -p "$CLANG_DIR"
  curl -fL --retry 3 \
    "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r547379.tar.gz" \
    -o "$TARBALL"
  tar -xzf "$TARBALL" -C "$CLANG_DIR"
  rm -f "$TARBALL"
fi

"$CLANG_DIR/bin/clang" --version
