#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  bc bison build-essential ca-certificates ccache cpio curl flex \
  git libelf-dev libssl-dev liblz4-dev libncurses-dev zstd \
  python3 rsync unzip wget xsltproc zip zlib1g-dev \
  gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi

ROOT="${GITHUB_WORKSPACE:-$PWD}"
mkdir -p "$ROOT/tc"
if [ ! -x "$ROOT/tc/clang/bin/clang" ]; then
  git clone --depth=1 "${CLANG_REPO:-https://github.com/kdrag0n/proton-clang}" "$ROOT/tc/clang"
fi

"$ROOT/tc/clang/bin/clang" --version
