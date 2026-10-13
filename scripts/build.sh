#!/usr/bin/env bash
set -euo pipefail

: "${DEFCONFIG:?DEFCONFIG is not set}"
ROOT="${GITHUB_WORKSPACE:-$PWD}"
CLANG="$ROOT/tc/clang/bin"
KDIR="$ROOT/kernel"
LOG="$ROOT/build-kernel.log"
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
  echo "::error::build.sh failed (rc=$rc) DEFCONFIG=$DEFCONFIG"
  local filt='error:|Error [0-9]+|undefined reference|fatal error|No rule to make|Cannot use|not supported by compiler|Killed|out of memory'
  local errs=()
  mapfile -t errs < <(grep -n -iE "$filt" "$LOG" 2>/dev/null)
  local n=${#errs[@]}
  if [ "$n" -gt 0 ]; then
    printf '::error:: %s\n' "${errs[@]:0:8}"
    if [ "$n" -gt 16 ]; then
      printf '::error:: ... (%d error lines omitted) ...\n' "$((n-16))"
      printf '::error:: %s\n' "${errs[@]: -8}"
    fi
  else
    tail -n 9 "$LOG" 2>/dev/null | while IFS= read -r l; do echo "::error:: $l"; done
  fi
  tail -n 10 "$LOG" 2>/dev/null | while IFS= read -r l; do echo "::warning::tail: $l"; done
  {
    echo ""
    echo "### Compile failure: DEFCONFIG=$DEFCONFIG rc=$rc"
    echo '```'
    grep -n -iE "$filt" "$LOG" 2>/dev/null | head -n 150 || true
    echo "----- last 250 lines -----"
    tail -n 250 "$LOG" 2>/dev/null || true
    echo '```'
  } >> "$SUMMARY"
}
trap 'dump_diag' ERR

echo "::group::toolchain"
command -v clang || true
clang --version | head -n 1 || true
echo "::endgroup::"

{
  echo "===== make $DEFCONFIG ====="
  "${MAKE[@]}" "$DEFCONFIG"
  echo "===== make olddefconfig (non-interactive) ====="
  # Avoid interactive prompts from NEW Kconfig symbols in the appended configs
  "${MAKE[@]}" olddefconfig 2>&1 | tee -a "$LOG" || true
  # Retry with all defaults to be safe
  "${MAKE[@]}" olddefconfig
} 2>&1 | tee "$LOG"

# --- verify the requested 5.10 BPF options survived olddefconfig -----------
echo "::group::config verification"
verify_ok=1
check_y() {
  local sym="$1"
  if grep -q "^$sym=y" "$KDIR/.config"; then
    echo "OK   $sym=y"
  else
    echo "::error::MISSING $sym=y in .config (Kconfig symbol absent? backport incomplete?)"
    verify_ok=0
  fi
}
check_y CONFIG_BPF_LSM
check_y CONFIG_BPF_PRELOAD
check_y CONFIG_BPF_SYSCALL
echo "CONFIG_LSM value: $(grep '^CONFIG_LSM=' "$KDIR/.config" || echo '<unset>')"
grep -q '^CONFIG_LSM=' "$KDIR/.config" || { echo "::error::CONFIG_LSM missing"; verify_ok=0; }
echo "SELinux bootparam: $(grep '^CONFIG_SECURITY_SELINUX_BOOTPARAM' "$KDIR/.config" || echo '<unset>')"
echo "SELinux develop : $(grep '^CONFIG_SECURITY_SELINUX_DEVELOP' "$KDIR/.config" || echo '<unset>')"
echo "::endgroup::"
if [ "$verify_ok" != 1 ]; then
  echo "::error::required BPF/LSM config options were not applied"
  exit 1
fi

echo "===== make -j$(nproc) ====="
"${MAKE[@]}" -j"$(nproc)" 2>&1 | tee -a "$LOG"

echo "::group::build output"
ls -l "$KDIR/arch/arm64/boot/" || true
echo "::endgroup::"
