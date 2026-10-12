#!/usr/bin/env bash
set -euo pipefail

: "${DEFCONFIG:?DEFCONFIG is not set}"
ROOT="${GITHUB_WORKSPACE:-$PWD}"
CLANG="$ROOT/tc/clang/bin"
OUT="$ROOT/out"
LOG="$ROOT/build-${TARGET:-kernel}.log"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

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

dump_diag() {
  local rc=$?
  echo "::error::build.sh failed (rc=$rc) DEFCONFIG=$DEFCONFIG target=${TARGET:-}"
  {
    echo ""
    echo "### Compile failure: DEFCONFIG=$DEFCONFIG rc=$rc"
    echo ""
    echo '```'
    echo "----- matched error lines -----"
    grep -n -iE 'error:|Error [0-9]+|undefined reference|No rule to make|fatal error|command not found|Permission denied' "$LOG" 2>/dev/null | head -n 80 || true
    echo "----- last 200 lines -----"
    tail -n 200 "$LOG" 2>/dev/null || true
    echo '```'
  } >> "$SUMMARY"
  grep -m 20 -iE 'error:|Error [0-9]+|undefined reference|No rule to make|fatal error|command not found' "$LOG" 2>/dev/null | while IFS= read -r l; do echo "::error:: $l"; done || true
}
trap 'dump_diag' ERR

rm -rf "$OUT"
{
  echo "===== make $DEFCONFIG ====="
  "${MAKE[@]}" "$DEFCONFIG"
  echo "===== make -j$(nproc) ====="
  "${MAKE[@]}" -j"$(nproc)"
} 2>&1 | tee "$LOG"

echo "::group::build output"
ls -l "$OUT/arch/arm64/boot/"
echo "::endgroup::"
