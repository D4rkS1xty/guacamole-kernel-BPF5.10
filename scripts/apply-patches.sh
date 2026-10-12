#!/usr/bin/env bash
set -euo pipefail

on_err() {
  local rc=$?
  echo "::error::apply-patches.sh failed (rc=$rc) at line ${LINENO}: ${BASH_COMMAND}"
}
trap 'on_err' ERR

: "${DEFCONFIG:?DEFCONFIG is not set}"
ROOT="${GITHUB_WORKSPACE:-$PWD}"
PATCHDIR="$ROOT/patches"
cd "$ROOT/kernel"

git config --global user.email "ci@localhost"
git config --global user.name "guacamole-builder"
git config --global advice.detachedHead false

# ---------------------------------------------------------------------------
# 1) Tree fixes for regressions in the WIP sixteen-bpfgore branch
# ---------------------------------------------------------------------------
echo "::group::tree fixes"

# printk.c (backported from a newer kernel) uses KMSG_DUMP_MAX, but the enum
# in include/linux/kmsg_dump.h was not updated -> compile error. Add it.
if [ -f include/linux/kmsg_dump.h ] && ! grep -q 'KMSG_DUMP_MAX' include/linux/kmsg_dump.h; then
  sed -i '/KMSG_DUMP_POWEROFF/a\\tKMSG_DUMP_MAX,' include/linux/kmsg_dump.h
  echo "tree fix: added KMSG_DUMP_MAX to include/linux/kmsg_dump.h"
fi

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
fi
if grep -q 'security_shm_alloc(shp)' ipc/shm.c; then
  sed -i 's/\(security_shm_[a-z_]*\)(shp/\1(\&shp->shm_perm/g' ipc/shm.c
fi
if grep -q 'security_sem_alloc(sma)' ipc/sem.c; then
  sed -i 's/\(security_sem_[a-z_]*\)(sma/\1(\&sma->sem_perm/g' ipc/sem.c
fi

# net/core/filter.c (BPF backport) uses sizeof_field(); that macro is missing
# from this 4.14 tree's include/linux/stddef.h. Insert it before the FINAL
# #endif (include guard): the first bare #endif closes the
# #ifdef __compiler_offsetof/#else block, so inserting there puts the macro in
# the inactive #else branch and it is never defined.
if ! grep -q 'define sizeof_field' include/linux/stddef.h; then
  awk '
    { a[NR]=$0 }
    END {
      last=0
      for (i=NR;i>=1;i--) if (a[i]=="#endif") { last=i; break }
      for (i=1;i<=NR;i++) {
        if (i==last) print "#define sizeof_field(TYPE, MEMBER) sizeof((((TYPE *)0)->MEMBER))"
        print a[i]
      }
    }' include/linux/stddef.h > include/linux/stddef.h.tmp
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

# include/linux/devfreq_boost.h: the !CONFIG_DEVFREQ_BOOST stub for
# devfreq_boost_kick_max() has a stray 3rd parameter (bool always) while every
# caller (kernel/fork.c, drm) passes 2 args -> "too few arguments". stock
# defconfig does not enable CONFIG_DEVFREQ_BOOST, so the buggy stub is active.
if grep -q 'int duration_ms, bool always' include/linux/devfreq_boost.h; then
  sed -i 's/void devfreq_boost_kick_max(enum df_device device, unsigned int duration_ms, bool always)/void devfreq_boost_kick_max(enum df_device device, unsigned int duration_ms)/' \
    include/linux/devfreq_boost.h
  echo "tree fix: fixed devfreq_boost_kick_max stub (3 args -> 2 args)"
fi

# arch/arm64/kernel/cpu_errata.c: the CONFIG_ARM64_ERRATUM_1188873 Kryo-4G entry
# calls the 5-arg ERRATA_MIDR_RANGE() with only 3 args (model + two
# MIDR_CPU_VAR_REV()). That yields "too few arguments to function-like macro
# invocation" and "use of undeclared identifier 'ERRATA_MIDR_RANGE'". It should
# use ERRATA_MIDR_REV_RANGE(model, var, r_min, r_max). Only built by stock
# (which enables CONFIG_ARM64_ERRATUM_1188873).
if grep -q 'ERRATA_MIDR_RANGE(MIDR_KRYO4G,' arch/arm64/kernel/cpu_errata.c; then
  perl -0777 -i -pe 's/ERRATA_MIDR_RANGE\(MIDR_KRYO4G,\s*\n\s*MIDR_CPU_VAR_REV\(15, 14\),\s*\n\s*MIDR_CPU_VAR_REV\(15, 15\)\)/ERRATA_MIDR_REV_RANGE(MIDR_KRYO4G, 15, 14, 15)/s' \
    arch/arm64/kernel/cpu_errata.c
  echo "tree fix: cpu_errata ERRATA_MIDR_RANGE(MIDR_KRYO4G) -> ERRATA_MIDR_REV_RANGE"
fi

# kernel/sched/fair.c lost upstream's "#include <trace/events/sched.h>".
# check_schedstat_required() references trace_sched_stat_{wait,sleep,iowait,
# blocked,runtime}_enabled() under CONFIG_SCHEDSTATS; without the include those
# static inline accessors are undeclared -> -Werror=implicit-function-declaration.
# Only built by stock (which sets CONFIG_SCHEDSTATS=y). Restore the include.
if ! grep -q 'trace/events/sched.h' kernel/sched/fair.c; then
  perl -0777 -i -pe 's/(#include <linux\/rbtree_augmented\.h>\n)/$1#include <trace\/events\/sched.h>\n/' \
    kernel/sched/fair.c
  echo "tree fix: restored #include <trace/events/sched.h> in kernel/sched/fair.c"
fi

# include/linux/sched.h (struct task_struct) is missing irq_config, which
# include/linux/irqflags.h's lockdep_hrtimer_enter()/exit() write under
# CONFIG_TRACE_IRQFLAGS (enabled by stock) -> "no member named 'irq_config'".
if ! grep -q 'irq_config' include/linux/sched.h; then
  perl -0777 -i -pe 's/(\tint\t+softirq_context;\n)/$1\tint\t\t\t\tirq_config;\n/' \
    include/linux/sched.h
  echo "tree fix: added irq_config to struct task_struct"
fi

# net/packet/af_packet.c is a vendor variant that uses the OpenWrt
# "packet_socket_type" option (PACKET_RECV_TYPE + PACKET_MASK_ANY), but the
# UAPI header was not updated -> undeclared identifiers. Values from
# openwrt pending-4.14/630-packet_socket_type.patch (4.14 has no
# PACKET_IGNORE_OUTGOING, so PACKET_RECV_TYPE is 23).
if ! grep -q 'PACKET_MASK_ANY' include/uapi/linux/if_packet.h; then
  perl -0777 -i -pe 's/(#define PACKET_FASTROUTE[^\n]*\n)/$1#define PACKET_MASK_ANY\t\t0xffffffff\t\/* mask for packet type bits *\/\n/' \
    include/uapi/linux/if_packet.h
  echo "tree fix: added PACKET_MASK_ANY to include/uapi/linux/if_packet.h"
fi
if ! grep -q 'PACKET_RECV_TYPE' include/uapi/linux/if_packet.h; then
  perl -0777 -i -pe 's/(#define PACKET_FANOUT_DATA[^\n]*\n)/$1#define PACKET_RECV_TYPE\t\t23\n/' \
    include/uapi/linux/if_packet.h
  echo "tree fix: added PACKET_RECV_TYPE to include/uapi/linux/if_packet.h"
fi

# net/netfilter/xt_owner.c is a backported version whose check() uses
# XT_OWNER_SUPPL_GROUPS, but the UAPI enum lacks it -> undeclared.
if ! grep -q 'XT_OWNER_SUPPL_GROUPS' include/uapi/linux/netfilter/xt_owner.h; then
  perl -0777 -i -pe 's/(\tXT_OWNER_SOCKET = 1 << 2,\n)/$1\tXT_OWNER_SUPPL_GROUPS = 1 << 3,\n/' \
    include/uapi/linux/netfilter/xt_owner.h
  echo "tree fix: added XT_OWNER_SUPPL_GROUPS to xt_owner.h"
fi

git add -A
git commit -q -m "tree fix: bpfgore regressions (kmsg/ipc/stddef/gso/lz4/lse/devfreq/errata/sched-trace/irq-config/packet/xt_owner)" || true
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 2) SukiSU-Ultra (builtin branch) + SUSFS v1.5.5 root hiding.
#    Ported verbatim from the proven themaxmarchuk/kernel_oneplus_sm8150-ksu
#    "sixteen-suki" integration (SukiSU-Ultra v4.1.3 builtin + SUSFS v1.5.5).
#    The patches live in $ROOT/patches and are verified to apply to
#    yaap/kernel_oneplus_sm8150@sixteen-bpfgore.
# ---------------------------------------------------------------------------
echo "::group::SukiSU-Ultra + SUSFS integration"

# 2a) Vendored SukiSU-Ultra kernel tree (drivers/kernelsu -> KernelSU/kernel)
git apply --whitespace=nowarn "$PATCHDIR/0003-KernelSU-builtin-v4.1.3.patch"
echo "applied SukiSU-Ultra KernelSU tree"

# 2b) SUSFS v1.5.5 kernel-side hooks (fs/, include/linux/, kernel/)
git apply --whitespace=nowarn "$PATCHDIR/0001-susfs-kernel-4.14.patch"
echo "applied SUSFS kernel-side patch"

# 2c) Manual KernelSU entry-point hooks (execveat/faccessat/stat/read/input)
git apply --whitespace=nowarn "$PATCHDIR/0002-kernelsu-hooks.patch"
echo "applied KernelSU manual hook patch"

# 2d) Wire the driver: symlink + Kbuild + Kconfig
ln -sfn ../KernelSU/kernel drivers/kernelsu
if ! grep -q 'kernelsu/' drivers/Makefile; then
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
fi
if ! grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig; then
  printf '\nsource "drivers/kernelsu/Kconfig"\n' >> drivers/Kconfig
fi
echo "wired drivers/kernelsu"

git add -A
git commit -q -m "Integrate SukiSU-Ultra builtin + SUSFS v1.5.5" || true
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 3) defconfig tweaks: SukiSU + SUSFS, CPU masks, SELinux permissive
# ---------------------------------------------------------------------------
echo "::group::defconfig tweaks ($DEFCONFIG)"
CFG="arch/arm64/configs/$DEFCONFIG"
[ -f "$CFG" ] || { echo "::error::defconfig $CFG not found"; exit 1; }

cat >> "$CFG" <<'EOF'

# --- SukiSU-Ultra (manual-hook / builtin branch) ---
CONFIG_MODULES=y
CONFIG_KSU=y
CONFIG_KSU_DEBUG=y

# --- SUSFS v1.5.5 (KernelSU addon) ---
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_OVERLAYFS=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
# CONFIG_KSU_SUSFS_ENABLE_LOG is not set
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y

# --- SoC / sched symbols missing from some defconfigs ---
CONFIG_LITTLE_CPU_MASK=15
CONFIG_BIG_CPU_MASK=112
CONFIG_PRIME_CPU_MASK=128

# --- Disable the Smack LSM: it still uses the pre-kern_ipc_perm IPC hook
#     signatures and otherwise fails to compile (only enabled in stock). ---
# CONFIG_SECURITY_SMACK is not set

# --- Features whose kernel code is inconsistent in this WIP branch; disable
#     so stock_defconfig builds. /proc/slabinfo needs CONFIG_SLUB_DEBUG's
#     total_objects (mm/slab.h); incfs verity expects a newer fsverity API. ---
# CONFIG_SLABINFO is not set
# CONFIG_SLAB_STAT_DEBUG is not set
# CONFIG_INCREMENTAL_FS is not set

# --- SELinux: permissive by default ---
CONFIG_SECURITY_SELINUX_BOOTPARAM=y
CONFIG_SECURITY_SELINUX_BOOTPARAM_VALUE=0
CONFIG_SECURITY_SELINUX_DEVELOP=y
EOF
echo "::endgroup::"
