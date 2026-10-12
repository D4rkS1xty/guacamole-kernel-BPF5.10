#!/usr/bin/env bash
set -euo pipefail

on_err() {
  local rc=$?
  echo "::error::apply-patches.sh failed (rc=$rc) at line ${LINENO}: ${BASH_COMMAND}"
}
trap 'on_err' ERR

: "${DEFCONFIG:?DEFCONFIG is not set}"
ROOT="${GITHUB_WORKSPACE:-$PWD}"
cd "$ROOT/kernel"

git config --global user.email "ci@localhost"
git config --global user.name "guacamole-builder"
git config --global advice.detachedHead false

# ---------------------------------------------------------------------------
# 1) KernelSU-Next (legacy / non-GKI integration)
# ---------------------------------------------------------------------------
echo "::group::KernelSU-Next legacy setup"
KSU_URL="https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh"
LOG="$(mktemp)"
curl -fLSs "$KSU_URL" -o /tmp/ksu-setup.sh
set +e
bash /tmp/ksu-setup.sh legacy 2>&1 | tee "$LOG"
KSU_RC=${PIPESTATUS[0]}
set -e
if [ "$KSU_RC" -ne 0 ]; then
  echo "::error::KernelSU-Next setup failed (rc=$KSU_RC). Last log lines:"
  tail -n 60 "$LOG" | sed 's/^/  /' | while IFS= read -r line; do echo "::error::ksu: $line"; done
  exit 1
fi
echo "KernelSU-Next setup OK"
git add -A
git commit -q -m "Add KernelSU-Next" || true
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 2) SUSFS (kernel-4.14). Best effort: revert cleanly if the patch conflicts.
# ---------------------------------------------------------------------------
echo "::group::SUSFS (kernel-4.14)"
SUSFS=/tmp/susfs4ksu
rm -rf "$SUSFS"
git clone --depth=1 -b kernel-4.14 https://gitlab.com/simonpunk/susfs4ksu.git "$SUSFS"

if (
  set -e
  cp "$SUSFS"/kernel_patches/include/linux/*.h include/linux/
  cp "$SUSFS"/kernel_patches/fs/*.c fs/
  KSUDIR="KernelSU-Next"
  [ -d "$KSUDIR" ] || KSUDIR="KernelSU"
  ( cd "$KSUDIR" && patch -p1 < "$SUSFS/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" )
  patch -p1 < "$SUSFS/kernel_patches/50_add_susfs_in_kernel-4.14.patch"
); then
  git add -A
  git commit -q -m "Add SUSFS" || true
  echo "SUSFS applied"
else
  echo "::warning::SUSFS patch did not apply cleanly - building WITHOUT SUSFS"
  git checkout -- .
  git clean -fd include/linux fs >/dev/null 2>&1 || true
fi
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 3) defconfig tweaks: KernelSU, kprobe hook, SUSFS, SELinux permissive
# ---------------------------------------------------------------------------
echo "::group::defconfig tweaks ($DEFCONFIG)"
CFG="arch/arm64/configs/$DEFCONFIG"
[ -f "$CFG" ] || { echo "::error::defconfig $CFG not found"; exit 1; }

cat >> "$CFG" <<'EOF'

# --- KernelSU-Next ---
CONFIG_KSU=y
CONFIG_KPROBES=y
CONFIG_KRETPROBES=y
CONFIG_KPROBE_EVENTS=y
CONFIG_MODULES=y
CONFIG_KSU_KPROBES_HOOK=y
CONFIG_KSU_KPROBE_HOOKS=y

# --- SUSFS ---
CONFIG_KSU_SUSFS=y

# --- SELinux: permissive by default ---
CONFIG_SECURITY_SELINUX_BOOTPARAM=y
CONFIG_SECURITY_SELINUX_BOOTPARAM_VALUE=0
CONFIG_SECURITY_SELINUX_DEVELOP=y
EOF
echo "::endgroup::"
