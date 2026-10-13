#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Add the 5.10-BPF related options to the device defconfig.
#
#   CONFIG_BPF_LSM=y
#   CONFIG_BPF_PRELOAD=y
#   CONFIG_LSM="lockdown,yama,loadpin,safesetid,integrity,selinux,smack,tomoyo,apparmor,bpf"
#
# and make SELinux permissive by default.
#
# Note: the "appar mour" spelling from the request was a typo; the LSM symbol
# is "apparmor". Unknown entries in CONFIG_LSM are ignored at boot anyway.
# ---------------------------------------------------------------------------
set -euo pipefail

: "${DEFCONFIG:?DEFCONFIG is not set}"
ROOT="${GITHUB_WORKSPACE:-$PWD}"
KDIR="$ROOT/kernel"
CFG="$KDIR/arch/arm64/configs/$DEFCONFIG"

[ -f "$CFG" ] || { echo "::error::defconfig not found: $CFG"; exit 1; }
echo "Patching $CFG"

# Remove any previous occurrence so the script stays idempotent.
sed -i -E \
  -e '/^CONFIG_BPF_LSM=/d' \
  -e '/^# CONFIG_BPF_LSM is not set/d' \
  -e '/^CONFIG_BPF_PRELOAD=/d' \
  -e '/^CONFIG_LSM=/d' \
  -e '/^CONFIG_SECURITY_SELINUX_BOOTPARAM=/d' \
  -e '/^# CONFIG_SECURITY_SELINUX_BOOTPARAM is not set/d' \
  -e '/^CONFIG_SECURITY_SELINUX_BOOTPARAM_VALUE=/d' \
  -e '/^CONFIG_SECURITY_SELINUX_DEVELOP=/d' \
  -e '/^CONFIG_LITTLE_CPU_MASK=/d' \
  -e '/^CONFIG_BIG_CPU_MASK=/d' \
  -e '/^CONFIG_PRIME_CPU_MASK=/d' \
  "$CFG"

cat >> "$CFG" <<'EOF'

# ---------------------------------------------------------------------------
# CPU topology masks (SM8150: 4x silver / 3x gold / 1x prime).
#
# These are integer Kconfig symbols with no default value, and the device
# "stock_defconfig" does not set them (only the root "defconfig" does).  If
# they are left unset, `make` falls back to `silentoldconfig`, which tries to
# prompt for them and aborts because stdin is redirected.  Set them here so
# `olddefconfig` produces a complete, non-interactive .config.
# ---------------------------------------------------------------------------
CONFIG_LITTLE_CPU_MASK=15
CONFIG_BIG_CPU_MASK=112
CONFIG_PRIME_CPU_MASK=128

# ---------------------------------------------------------------------------
# 5.10 BPF backport (PixelPlusUI guacamole)
# ---------------------------------------------------------------------------
CONFIG_BPF_LSM=y
CONFIG_BPF_PRELOAD=y
CONFIG_LSM="lockdown,yama,loadpin,safesetid,integrity,selinux,smack,tomoyo,apparmor,bpf"

# SELinux: permissive by default
CONFIG_SECURITY_SELINUX_BOOTPARAM=y
CONFIG_SECURITY_SELINUX_BOOTPARAM_VALUE=0
CONFIG_SECURITY_SELINUX_DEVELOP=y
EOF

# The LSM framework also has a legacy "default security" symbol. Make sure it
# points at SELinux (or is absent, in which case CONFIG_LSM decides).
if grep -q '^CONFIG_DEFAULT_SECURITY_' "$CFG"; then
  sed -i -E 's|^CONFIG_DEFAULT_SECURITY_SELINUX=.*|CONFIG_DEFAULT_SECURITY_SELINUX=y|' "$CFG"
fi

echo "::group::defconfig additions"
tail -n 20 "$CFG"
echo "::endgroup::"
