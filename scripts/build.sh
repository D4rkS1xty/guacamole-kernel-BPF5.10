#!/usr/bin/env bash
set -euo pipefail

: "${DEFCONFIG:?DEFCONFIG is not set}"
ROOT="${GITHUB_WORKSPACE:-$PWD}"
CLANG="$ROOT/tc/clang/bin"
OUT="$ROOT/out"

export PATH="$CLANG:$PATH"
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
export KBUILD_BUILD_USER="${GITHUB_ACTOR:-builder}"
export KBUILD_BUILD_HOST="github-actions"
export KBUILD_BUILD_VERSION=1

MAKE=(make -C "$ROOT/kernel" O="$OUT" ARCH=arm64
  CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm
  OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip)

rm -rf "$OUT"
"${MAKE[@]}" "$DEFCONFIG"
"${MAKE[@]}" -j"$(nproc)"

echo "::group::build output"
ls -l "$OUT/arch/arm64/boot/"
echo "::endgroup::"
