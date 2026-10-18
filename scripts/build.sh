#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Configure and build the ArrowOS guacamole (sm8150) kernel with the 5.10 BPF
# backport applied.
#
# Only arch/arm64/boot/Image.gz is built:
#
#   * the target boot.img carries its own device-tree blob in the v2 header
#     (a 4.25 MB concatenation of 15 DTBs), so no -dtb image is needed;
#   * the target ROM has no kernel modules anywhere (its vendor partition
#     ships no .ko files), and arrow-12.1's stock_defconfig builds every
#     driver that matters as built-in -- its only =m entries are wil6210
#     (60 GHz wifi), DVB/tspp (TV tuners), USB_GSPCA (webcams), MMC_TEST,
#     MSM_RDBG, MSM_11AD, LLCC_PERFMON, IR_MSM_GENI and BRIDGE_NETFILTER,
#     none of which guacamole loads.
#
# So the kernel is effectively monolithic and there is nothing to install into
# the boot ramdisk.
# ---------------------------------------------------------------------------
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

# -ferror-limit=0: clang normally stops after 20 errors per translation unit,
# so a broken core header (a lot of this backport is one) hides every later
# error behind the first twenty copies of the same one.  Report them all.
MAKE=(make -C "$KDIR" ARCH=arm64
  CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm
  OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
  KCFLAGS=-ferror-limit=0)

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
  # A broken header repeats the same diagnostic once per translation unit, so
  # show the distinct messages with a count instead of 150 copies of one line.
  echo "::group::distinct compile errors (count, message)"
  grep -oE '[^ ]+\.(c|h|S):[0-9]+:[0-9]+: (error|fatal error): .*' "$LOG" 2>/dev/null \
    | sed -E 's/^[^ ]*:[0-9]+:[0-9]+: //' \
    | sort | uniq -c | sort -rn | head -n 40 || true
  echo "::endgroup::"
  {
    echo ""
    echo "### Distinct compile errors"
    echo '```'
    grep -oE '[^ ]+\.(c|h|S):[0-9]+:[0-9]+: (error|fatal error): .*' "$LOG" 2>/dev/null \
      | sort -u | head -n 60 || true
    echo '```'
  } >> "$SUMMARY"
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

# --- guard: unresolved symbols show up as empty "CONFIG_FOO=" lines.  If any
# --- remain, `make` will re-run silentoldconfig and abort on a prompt.
empties=$(grep -nE '^CONFIG_[A-Za-z0-9_]+=$' "$KDIR/.config" || true)
if [ -n "$empties" ]; then
  echo "::warning::.config has unresolved (empty) symbols; silentoldconfig may prompt:"
  printf '%s\n' "$empties" | sed 's/^/  /'
fi

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
echo "ROOT MANAGERS   : $(grep -E '^CONFIG_(KSU|SUSFS)' "$KDIR/.config" || echo 'none (expected)')"
echo "::endgroup::"
if [ "$verify_ok" != 1 ]; then
  echo "::error::required BPF/LSM config options were not applied"
  exit 1
fi

echo "===== make -k -j$(nproc) Image.gz (keep going: report every error) ====="
"${MAKE[@]}" -k -j"$(nproc)" Image.gz 2>&1 | tee -a "$LOG"

IMG="$KDIR/arch/arm64/boot/Image.gz"
[ -f "$IMG" ] || { echo "::error::Image.gz was not produced"; ls -l "$KDIR/arch/arm64/boot/" || true; exit 1; }

echo "::group::build output"
ls -l "$KDIR/arch/arm64/boot/" || true
gzip -t "$IMG" && echo "Image.gz: gzip integrity OK"
echo "kernel release : $(cat "$KDIR/include/config/kernel.release" 2>/dev/null || echo '?')"
echo "Image.gz size  : $(stat -c %s "$IMG")"
echo "::endgroup::"

# Record the exact kernel tree revision the image was built from, so the
# packaging step can name the artifact after it.
git -C "$KDIR" rev-parse HEAD > "$ROOT/kernel-rev.txt" 2>/dev/null || echo unknown > "$ROOT/kernel-rev.txt"
echo "kernel rev: $(cat "$ROOT/kernel-rev.txt")"
