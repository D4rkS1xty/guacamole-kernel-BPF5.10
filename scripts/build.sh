#!/usr/bin/env bash
set -euo pipefail

: "${DEFCONFIG:?DEFCONFIG is not set}"
ROOT="${GITHUB_WORKSPACE:-$PWD}"
CLANG="$ROOT/tc/clang/bin"
KDIR="$ROOT/kernel"
LOG="$ROOT/build-${TARGET:-kernel}.log"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

export PATH="$CLANG:$PATH"
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
export KBUILD_BUILD_USER="${GITHUB_ACTOR:-builder}"
export KBUILD_BUILD_HOST="github-actions"
export KBUILD_BUILD_VERSION=1

MAKE=(make -C "$KDIR" ARCH=arm64
  CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm
  OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip)

dump_diag() {
  local rc=$?
  echo "::error::build.sh failed (rc=$rc) DEFCONFIG=$DEFCONFIG target=${TARGET:-}"
  tail -n 10 "$LOG" 2>/dev/null | while IFS= read -r l; do echo "::error::$l"; done || true
  {
    echo ""
    echo "### Compile failure: DEFCONFIG=$DEFCONFIG rc=$rc"
    echo '```'
    grep -n -iE 'error:|Error [0-9]+|Cannot use|No rule|not supported|fatal error|command not found' "$LOG" 2>/dev/null | head -n 60 || true
    echo "----- last 150 lines -----"
    tail -n 150 "$LOG" 2>/dev/null || true
    echo '```'
  } >> "$SUMMARY"
}
trap 'dump_diag' ERR

echo "::group::toolchain"
command -v clang || true
clang --version | head -n 1 || true
for f in "-fstack-protector-strong" "-mllvm -polly" "-flto=thin"; do
  if clang $f -c -x c /dev/null -o /dev/null >/dev/null 2>&1; then r=OK; else r=FAIL; fi
  echo "::notice::clang probe ${f} = ${r}"
done
echo "::endgroup::"

{
  echo "===== make $DEFCONFIG ====="
  "${MAKE[@]}" "$DEFCONFIG"
  echo "===== make olddefconfig ====="
  "${MAKE[@]}" olddefconfig
  echo "===== make -j$(nproc) ====="
  "${MAKE[@]}" -j"$(nproc)"
} 2>&1 | tee "$LOG"

echo "::group::build output"
ls -l "$KDIR/arch/arm64/boot/"
echo "::endgroup::"
