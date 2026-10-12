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
# 1b) Tree fixes for regressions in the WIP sixteen-bpfgore branch
# ---------------------------------------------------------------------------
echo "::group::tree fixes"
# printk.c (backported from a newer kernel) uses KMSG_DUMP_MAX, but the enum
# in include/linux/kmsg_dump.h was not updated -> compile error. Add it.
if [ -f include/linux/kmsg_dump.h ] && ! grep -q 'KMSG_DUMP_MAX' include/linux/kmsg_dump.h; then
  sed -i '/KMSG_DUMP_POWEROFF/a\\tKMSG_DUMP_MAX,' include/linux/kmsg_dump.h
  echo "tree fix: added KMSG_DUMP_MAX to include/linux/kmsg_dump.h"
else
  echo "tree fix: kmsg_dump.h already has KMSG_DUMP_MAX (or file missing)"
fi
git add -A
git commit -q -m "tree fix: add KMSG_DUMP_MAX to kmsg_dump.h" || true

# The WIP branch half-applied the upstream "struct kern_ipc_perm" LSM rework:
# lsm_hooks.h, security/security.c and SELinux use struct kern_ipc_perm *, but
# include/linux/security.h and ipc/{msg,shm,sem}.c keep the old
# msg_queue/shmid_kernel/sem_array types -> "conflicting types" build errors.
if grep -q 'struct msg_queue \*msq' include/linux/security.h; then
  sed -i \
    -e 's/struct msg_queue \*msq/struct kern_ipc_perm *msq/g' \
    -e 's/struct shmid_kernel \*shp/struct kern_ipc_perm *shp/g' \
    -e 's/struct sem_array \*sma/struct kern_ipc_perm *sma/g' \
    include/linux/security.h
  echo "tree fix: converted include/linux/security.h IPC hooks to kern_ipc_perm"
fi
if grep -q 'security_msg_queue_alloc(msq)' ipc/msg.c; then
  sed -i 's/\(security_msg_queue_[a-z_]*\)(msq/\1(\&msq->q_perm/g' ipc/msg.c
  echo "tree fix: ipc/msg.c -> &msq->q_perm"
fi
if grep -q 'security_shm_alloc(shp)' ipc/shm.c; then
  sed -i 's/\(security_shm_[a-z_]*\)(shp/\1(\&shp->shm_perm/g' ipc/shm.c
  echo "tree fix: ipc/shm.c -> &shp->shm_perm"
fi
if grep -q 'security_sem_alloc(sma)' ipc/sem.c; then
  sed -i 's/\(security_sem_[a-z_]*\)(sma/\1(\&sma->sem_perm/g' ipc/sem.c
  echo "tree fix: ipc/sem.c -> &sma->sem_perm"
fi
git add -A
git commit -q -m "tree fix: complete kern_ipc_perm LSM conversion in security.h + ipc/" || true

# net/core/filter.c (BPF backport) uses sizeof_field(); that macro is missing
# from this 4.14 tree's include/linux/stddef.h.
if ! grep -q 'define sizeof_field' include/linux/stddef.h; then
  awk '{ if ($0=="#endif" && !done) { print "#define sizeof_field(TYPE, MEMBER) sizeof((((TYPE *)0)->MEMBER))"; done=1 } print }' \
    include/linux/stddef.h > include/linux/stddef.h.tmp
  mv include/linux/stddef.h.tmp include/linux/stddef.h
  echo "tree fix: added sizeof_field to include/linux/stddef.h"
fi

# net/core/filter.c (BPF backport) calls skb_increase/decrease_gso_size(),
# helpers that were never added to include/linux/skbuff.h.
if ! grep -q 'skb_increase_gso_size' include/linux/skbuff.h; then
  awk '
    /^struct skb_shared_info \{/ { ins=1 }
    { print }
    ins && /^\};$/ && !done {
      print "static inline void skb_increase_gso_size(struct skb_shared_info *shinfo,"
      print "\t\t\t\t\t u16 increment)"
      print "{"
      print "\tif (WARN_ON_ONCE(shinfo->gso_size == GSO_BY_FRAGS))"
      print "\t\treturn;"
      print "\tshinfo->gso_size += increment;"
      print "}"
      print ""
      print "static inline void skb_decrease_gso_size(struct skb_shared_info *shinfo,"
      print "\t\t\t\t\t u16 decrement)"
      print "{"
      print "\tif (WARN_ON_ONCE(shinfo->gso_size == GSO_BY_FRAGS))"
      print "\t\treturn;"
      print "\tshinfo->gso_size -= decrement;"
      print "}"
      done=1; ins=0
    }
  ' include/linux/skbuff.h > include/linux/skbuff.h.tmp
  mv include/linux/skbuff.h.tmp include/linux/skbuff.h
  echo "tree fix: added skb_increase/decrease_gso_size to include/linux/skbuff.h"
fi

# lib/lz4/lz4_decompress.c EXPORT_SYMBOLs reference a stale 'armv8' name while
# the functions are actually named 'arm64'.
if grep -q 'LZ4_armv8_' lib/lz4/lz4_decompress.c; then
  sed -i 's/LZ4_armv8_/LZ4_arm64_/g' lib/lz4/lz4_decompress.c
  echo "tree fix: lz4 armv8 -> arm64 EXPORT_SYMBOL"
fi

# arch/arm64/include/asm/lse.h: with CONFIG_ARM64_LSE_ATOMICS disabled the
# #else branch never defines ARM64_LSE_ATOMIC_INSN, but cmpxchg.h always uses
# it -> "expected string literal in 'asm'". Define the pass-through variant.
if ! grep -q 'compat: pass-through' arch/arm64/include/asm/lse.h; then
  sed -i '/#define __LL_SC_EXPORT(x)/a\
#define ARM64_LSE_ATOMIC_INSN(lse)	lse /* compat: pass-through for !LSE */' arch/arm64/include/asm/lse.h
  echo "tree fix: define ARM64_LSE_ATOMIC_INSN for !LSE builds"
fi
git add -A
git commit -q -m "tree fix: sizeof_field, gso size helpers, lz4 arm64 exports, lse.h !LSE" || true
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 2) SUSFS (kernel-4.14). Best effort: revert cleanly if the patch conflicts.
# ---------------------------------------------------------------------------
echo "::group::SUSFS (kernel-4.14)"
SUSFS=/tmp/susfs4ksu
rm -rf "$SUSFS"
SUSFS_OK=0
for remote in \
  https://github.com/Star-Seven/susfs4ksu.git \
  https://github.com/ShirkNeko/susfs4ksu.git \
  https://github.com/kutemeikito/susfs4ksu.git ; do
  echo "Trying SUSFS source: $remote"
  if git clone --depth=1 -b kernel-4.14 "$remote" "$SUSFS"; then SUSFS_OK=1; break; fi
  rm -rf "$SUSFS"
done

SUSFS_APPLY_LOG="${RUNNER_TEMP:-/tmp}/susfs-apply.log"
if [ "$SUSFS_OK" -ne 1 ]; then
  echo "::warning::could not fetch SUSFS from any mirror - building WITHOUT SUSFS"
elif (
  set -e
  cp "$SUSFS"/kernel_patches/include/linux/*.h include/linux/
  cp "$SUSFS"/kernel_patches/fs/*.c fs/
  KSUDIR="KernelSU-Next"
  [ -d "$KSUDIR" ] || KSUDIR="KernelSU"
  ( cd "$KSUDIR" && patch -p1 < "$SUSFS/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" )
  patch -p1 < "$SUSFS/kernel_patches/50_add_susfs_in_kernel-4.14.patch"
) > "$SUSFS_APPLY_LOG" 2>&1; then
  git add -A
  git commit -q -m "Add SUSFS" || true
  echo "SUSFS applied"
else
  echo "::warning::SUSFS patch did not apply cleanly - building WITHOUT SUSFS"
  {
    echo ""
    echo "### SUSFS patch failure (see below)"
    echo '```'
    tail -n 80 "$SUSFS_APPLY_LOG" 2>/dev/null || true
    echo '```'
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
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

# --- SoC / sched symbols missing from some defconfigs ---
CONFIG_LITTLE_CPU_MASK=15
CONFIG_BIG_CPU_MASK=112
CONFIG_PRIME_CPU_MASK=128

# --- Disable the Smack LSM: it still uses the pre-kern_ipc_perm IPC hook
#     signatures and otherwise fails to compile (only enabled in stock). ---
# CONFIG_SECURITY_SMACK is not set

# --- SUSFS ---
CONFIG_KSU_SUSFS=y

# --- SELinux: permissive by default ---
CONFIG_SECURITY_SELINUX_BOOTPARAM=y
CONFIG_SECURITY_SELINUX_BOOTPARAM_VALUE=0
CONFIG_SECURITY_SELINUX_DEVELOP=y
EOF
echo "::endgroup::"
