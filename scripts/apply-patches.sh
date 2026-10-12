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

# kernel/sched/walt.c uses the (sd, cpu) form of the capacity helpers, but this
# tree aliases arch_scale_cpu_capacity()/arch_scale_freq_capacity() to the
# single-argument topology_get_{cpu,freq}_scale(cpu) -> "too many arguments".
if grep -q 'arch_scale_cpu_capacity(NULL' kernel/sched/walt.c; then
  sed -i 's/arch_scale_cpu_capacity(NULL, /arch_scale_cpu_capacity(/g; s/arch_scale_freq_capacity(NULL, /arch_scale_freq_capacity(/g' \
    kernel/sched/walt.c
  echo "tree fix: walt.c capacity helpers use the 1-arg form"
fi

# fs/verity/signature.c references an undefined desc/desc_size (leftover from
# the descriptor-signing scheme); this tree signs the formatted digest, so
# bound the signature by FS_VERITY_MAX_SIGNATURE_SIZE instead.
if grep -q 'sig_size > desc_size - sizeof(\*desc)' fs/verity/signature.c; then
  perl -0777 -i -pe 's/sig_size > desc_size - sizeof\(\*desc\)/sig_size > FS_VERITY_MAX_SIGNATURE_SIZE/' \
    fs/verity/signature.c
  echo "tree fix: fs/verity/signature.c uses FS_VERITY_MAX_SIGNATURE_SIZE"
fi

# net/xfrm/xfrm_policy.c uses memset_after(), a helper that only exists in
# newer kernels; add the 5.x definition (string.h here predates it).
if ! grep -q 'define memset_after' include/linux/string.h; then
  sed -i '$d' include/linux/string.h
  cat >> include/linux/string.h <<'EOF'
/**
 * memset_after - Set the bytes after a given member of a struct to a given value
 * @p: pointer to the struct
 * @c: value to set
 * @member: name of the member
 */
#define memset_after(p, c, member)					\
({									\
	typeof(*(p)) *__pf = (p);					\
	memset((void *)__pf + offsetof(typeof(*__pf), member) +		\
	       sizeof(__pf->member), c,					\
	       sizeof(*__pf) - offsetof(typeof(*__pf), member) -		\
	       sizeof(__pf->member));					\
	__pf;								\
})

#endif /* _LINUX_STRING_H_ */
EOF
  echo "tree fix: added memset_after() to include/linux/string.h"
fi

# drivers/soc/qcom/subsystem_restart.c calls __getnstimeofday64(), which was
# removed from this tree's timekeeping; use the public ktime_get_real_ts64().
if grep -q '__getnstimeofday64' drivers/soc/qcom/subsystem_restart.c; then
  perl -0777 -i -pe 's/__getnstimeofday64\(&tspec\)/ktime_get_real_ts64(&tspec)/g' \
    drivers/soc/qcom/subsystem_restart.c
  grep -q 'linux/timekeeping.h' drivers/soc/qcom/subsystem_restart.c || \
    sed -i 's|#include <linux/time.h>|#include <linux/time.h>\n#include <linux/timekeeping.h>|' \
      drivers/soc/qcom/subsystem_restart.c
  echo "tree fix: subsystem_restart.c uses ktime_get_real_ts64()"
fi

# kernel/sched/debug.c calls cfs_rq_of(&p->se), but cfs_rq_of() only exists as
# a static inline in fair.c; add the same helper directly to debug.c.
if ! grep -q 'cfs_rq_of(struct sched_entity \*se)' kernel/sched/debug.c; then
  perl -0777 -i -pe 's{(#include "sched.h"\n)}{$1\n#ifdef CONFIG_FAIR_GROUP_SCHED\nstatic inline struct cfs_rq *cfs_rq_of(struct sched_entity *se)\n{\n\treturn se->cfs_rq;\n}\n#else\nstatic inline struct cfs_rq *cfs_rq_of(struct sched_entity *se)\n{\n\tstruct task_struct *p = container_of(se, struct task_struct, se);\n\tstruct rq *rq = task_rq(p);\n\n\treturn &rq->cfs;\n}\n#endif\n}s' \
    kernel/sched/debug.c
  echo "tree fix: added cfs_rq_of() to kernel/sched/debug.c"
fi

# drivers/block/vs_block_server.c calls bio_alloc_pages(), removed from this
# tree's bio layer; restore the classic 4.14 helper.
if ! grep -q 'bio_alloc_pages' block/bio.c; then
  cat >> block/bio.c <<'EOF'

int bio_alloc_pages(struct bio *bio, gfp_t gfp_mask)
{
	struct bio_vec *bv;
	int i;

	bio_for_each_segment_all(bv, bio, i) {
		bv->bv_page = alloc_page(gfp_mask);
		if (!bv->bv_page)
			return -ENOMEM;
	}

	return 0;
}
EXPORT_SYMBOL(bio_alloc_pages);
EOF
  perl -0777 -i -pe 's{(extern struct bio \*bio_alloc_bioset\(gfp_t, unsigned int, struct bio_set \*\);\n)}{$1extern int bio_alloc_pages(struct bio *bio, gfp_t gfp);\n}s' \
    include/linux/bio.h
  echo "tree fix: restored bio_alloc_pages()"
fi

# net/ipv4/tcp_cong.c uses CONFIG_DEFAULT_TCP_CONG unconditionally, but this
# tree's Kconfig leaves the symbol without a prompt, so it is undefined unless a
# DEFAULT_* option happens to be enabled; give it an unconditional fallback.
if ! grep -q 'default "cubic"$' net/ipv4/Kconfig; then
  perl -0777 -i -pe 's{(\tdefault "bbr2" if DEFAULT_BBR2\n)}{$1\tdefault "cubic"\n}s' \
    net/ipv4/Kconfig
  echo "tree fix: DEFAULT_TCP_CONG fallback default"
fi

# drivers/mmc/core/host.c calls mmc_validate_host_caps(), whose definition is
# missing from this WIP tree; add the upstream helper.
if ! grep -q 'mmc_validate_host_caps(struct mmc_host' drivers/mmc/core/host.c; then
  perl -0777 -i -pe 's{(static struct attribute_group dev_attr_grp = \{\n\t\.attrs = dev_attrs,\n\};\n)}{$1\nstatic int mmc_validate_host_caps(struct mmc_host *host)\n{\n\tif (host->caps \& MMC_CAP_SDIO_IRQ \&\& !host->ops->enable_sdio_irq) {\n\t\tdev_warn(host->parent, "MMC_CAP_SDIO_IRQ is supported, but enable_sdio_irq is not implemented\\n");\n\t\treturn -EINVAL;\n\t}\n\n\treturn 0;\n}\n}s' \
    drivers/mmc/core/host.c
  echo "tree fix: added mmc_validate_host_caps()"
fi

# drivers/mmc/host/sdhci.c lost its sdhci_set_ios() locals and the preset-value
# helpers in this WIP tree (only reachable when CONFIG_MMC_SDHCI is enabled,
# i.e. stock_defconfig); restore them from upstream.
if ! grep -q 'sdhci_timing_has_preset' drivers/mmc/host/sdhci.c; then
  perl -0777 -i -pe 's{(EXPORT_SYMBOL\(sdhci_cfg_irq\);\n\n)(void sdhci_set_ios\(struct mmc_host \*mmc, struct mmc_ios \*ios\)\n)}{$1static bool sdhci_timing_has_preset(unsigned char timing)\n{\n\tswitch (timing) {\n\tcase MMC_TIMING_UHS_SDR12:\n\tcase MMC_TIMING_UHS_SDR25:\n\tcase MMC_TIMING_UHS_SDR50:\n\tcase MMC_TIMING_UHS_SDR104:\n\tcase MMC_TIMING_UHS_DDR50:\n\tcase MMC_TIMING_MMC_HS:\n\tcase MMC_TIMING_MMC_DDR52:\n\tcase MMC_TIMING_MMC_HS200:\n\tcase MMC_TIMING_MMC_HS400:\n\t\treturn true;\n\tdefault:\n\t\treturn false;\n\t}\n}\n\nstatic bool sdhci_preset_needed(struct sdhci_host *host, unsigned char timing)\n{\n\treturn !(host->quirks2 \& SDHCI_QUIRK2_PRESET_VALUE_BROKEN) \&\&\n\t       sdhci_timing_has_preset(timing);\n}\n\nstatic bool sdhci_presetable_values_change(struct sdhci_host *host, struct mmc_ios *ios)\n{\n\t/*\n\t * Preset Values are: Driver Strength, Clock Generator and SDCLK/RCLK\n\t * Frequency. Check if preset values need to be enabled, or the Driver\n\t * Strength needs updating. Clock changes are handled separately.\n\t */\n\treturn !host->preset_enabled \&\&\n\t       (sdhci_preset_needed(host, ios->timing) ||\n\t\thost->drv_type != ios->drv_type);\n}\n\n$2}s' \
    drivers/mmc/host/sdhci.c
  echo "tree fix: restored sdhci preset-value helpers"
fi

if ! grep -q 'bool reinit_uhs = host->reinit_uhs' drivers/mmc/host/sdhci.c; then
  perl -0777 -i -pe 's{\tu8 ctrl;\n\tint ret;\n\n\thost->reinit_uhs = false;\n\n\thost->reinit_uhs = false;\n}{\tu8 ctrl;\n\tbool reinit_uhs = host->reinit_uhs;\n\tbool turning_on_clk = false;\n\tint ret;\n\n\thost->reinit_uhs = false;\n}s' \
    drivers/mmc/host/sdhci.c
  echo "tree fix: restored sdhci_set_ios locals"
fi

# drivers/mmc/host/sdhci-msm.c calls atomic_set() on the plain unsigned long
# pm_qos_request::cpus_affine bitmask; assign it directly instead.
if grep -q 'atomic_set(&msm_host->pm_qos_irq.req.cpus_affine' drivers/mmc/host/sdhci-msm.c; then
  perl -0777 -i -pe 's/atomic_set\(&(msm_host->pm_qos_irq\.req|group->req)\.cpus_affine,\s*\n\s*(\*cpumask_bits\([^\n]*\))\);/$1.cpus_affine = $2;/g' \
    drivers/mmc/host/sdhci-msm.c
  echo "tree fix: sdhci-msm.c cpus_affine direct assignment"
fi

# smb5-lib.c includes <linux/passthroughhack.h> only when
# CONFIG_OP_PASSTHROUGH_HACK is set, but references passthrough_hack
# unconditionally; guard the reference the same way (neptune sets it, stock not).
if [ "$(grep -c '#ifdef CONFIG_OP_PASSTHROUGH_HACK' drivers/power/supply/qcom/smb5-lib.c)" = "1" ]; then
  perl -0777 -i -pe 's{(\tif \(passthrough_hack > 0\)\n\t\treturn;\n)}{#ifdef CONFIG_OP_PASSTHROUGH_HACK\n$1#endif\n}s' \
    drivers/power/supply/qcom/smb5-lib.c
  echo "tree fix: guarded smb5-lib.c passthrough_hack reference"
fi

# lib/zstd links zstd_common.o only when CONFIG_ZSTD_COMMON is set, but this
# tree's Kconfig never selects it for COMPRESS/DECOMPRESS, leaving ZSTD_*/HUF_*/
# FSE_* symbols unresolved at vmlinux link; select it from both.
if ! grep -q 'select ZSTD_COMMON' lib/Kconfig; then
  perl -0777 -i -pe 's{(config ZSTD_COMPRESS\n\tselect XXHASH\n)}{$1\tselect ZSTD_COMMON\n}s' lib/Kconfig
  perl -0777 -i -pe 's{(config ZSTD_DECOMPRESS\n\tselect XXHASH\n)}{$1\tselect ZSTD_COMMON\n}s' lib/Kconfig
  echo "tree fix: ZSTD_COMPRESS/DECOMPRESS select ZSTD_COMMON"
fi

# kernel/fork.c unconditionally pokes the input-boost driver (last_mb_time,
# cpu_input_boost_kick_max), which only exists when CONFIG_CPU_INPUT_BOOST is on.
if ! grep -q '#ifdef CONFIG_CPU_INPUT_BOOST' kernel/fork.c; then
  perl -0777 -i -pe 's{(\t/\* Boost DDR bus to the max for 500 ms when userspace launches an app \*/\n\tif \(task_is_zygote\(current\)\) \{\n.*?\n\t\}\n)}{#ifdef CONFIG_CPU_INPUT_BOOST\n$1#endif\n}s' \
    kernel/fork.c
  echo "tree fix: guarded fork.c input-boost block"
fi

# drivers/soc/qcom/msm_bus: the RPMH fabric/debug objects call trace_bus_*()
# (declared in include/trace/events/trace_msm_bus.h), but no object in this WIP
# tree instantiates the tracepoints, leaving __tracepoint_bus_* undefined at
# vmlinux link. Define them once in an always-built RPMH object (not the
# CONFIG_DEBUG_FS-gated debug file).
if [ -f drivers/soc/qcom/msm_bus/msm_bus_fabric_rpmh.c ] && \
   ! grep -q 'CREATE_TRACE_POINTS' drivers/soc/qcom/msm_bus/msm_bus_fabric_rpmh.c; then
  perl -0777 -i -pe 's{(#include <trace/events/trace_msm_bus\.h>\n)}{#define CREATE_TRACE_POINTS\n$1}' \
    drivers/soc/qcom/msm_bus/msm_bus_fabric_rpmh.c
  echo "tree fix: instantiate msm_bus tracepoints (CREATE_TRACE_POINTS)"
fi

# drivers/soc/qcom/watchdog_v2.c calls migrate_disable()/migrate_enable(), which
# have no definition anywhere in this tree (SMP-only APIs this backport never
# wired up). A preempt bracket gives the same "do not migrate between reading
# the CPU and using per-cpu data" guarantee for this short, non-sleeping
# critical section.
if grep -q 'migrate_disable();' drivers/soc/qcom/watchdog_v2.c; then
  grep -q 'linux/preempt.h' drivers/soc/qcom/watchdog_v2.c || \
    sed -i 's|#include <linux/sched.h>|#include <linux/sched.h>\n#include <linux/preempt.h>|' \
      drivers/soc/qcom/watchdog_v2.c
  sed -i 's/migrate_disable();/preempt_disable();/; s/migrate_enable();/preempt_enable();/' \
    drivers/soc/qcom/watchdog_v2.c
  echo "tree fix: watchdog_v2.c migrate_disable/enable -> preempt_disable/enable"
fi

# drivers/staging/android/ion/ion.c defines ion_alloc_dmabuf() but exports
# nothing (this Sultan-ion rewrite dropped the EXPORT_SYMBOL that CAF's was
# built with). stock_defconfig builds CONFIG_DVB_MPQ_DEMUX=m
# (mpq-dmx-hw-plugin.ko, which calls ion_alloc()) so the module stage fails
# MODPOST with an undefined symbol. neptune_defconfig builds no DVB module at
# all, which is why the yaap job never hit this. Export it.
if [ -f drivers/staging/android/ion/ion.c ] && \
   ! grep -q 'EXPORT_SYMBOL(ion_alloc_dmabuf)' drivers/staging/android/ion/ion.c; then
  grep -q '#include <linux/export.h>' drivers/staging/android/ion/ion.c || \
    perl -0777 -i -pe 's{(#include <linux/miscdevice\.h>\n)}{$1#include <linux/export.h>\n}' \
      drivers/staging/android/ion/ion.c
  printf '\nEXPORT_SYMBOL(ion_alloc_dmabuf);\n' >> drivers/staging/android/ion/ion.c
  echo "tree fix: exported ion_alloc_dmabuf for DVB_MPQ_DEMUX module"
fi

git add -A
git commit -q -m "tree fix: bpfgore regressions (kmsg/ipc/stddef/gso/lz4/lse/devfreq/errata/sched-trace/irq-config/packet/xt_owner/walt/fsverity-sig/memset-after/ns-time/cfs-rq/bio-pages/tcp-cong/mmc-caps/sdhci-presets/sdhci-msm-affine/smb5-passthrough/zstd-common/boost-guard)" || true
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

# 2c-2) KernelSU<->SUSFS glue. The vendored KernelSU tree references
#       susfs_extra_works, and the SUSFS 4.14 kernel hooks call
#       ksu_try_umount()/susfs_try_umount_all(), but this SUSFS drop does not
#       define any of them (they normally live in a KernelSU-side integration
#       patch that this recipe never shipped). Provide them here so vmlinux
#       links: the deferred work runs the try_umount pass, ksu_try_umount()
#       performs the actual umount, and susfs_try_umount_all() walks the
#       registered LH_TRY_UMOUNT_PATH list.
if ! grep -q 'susfs_run_extra_works' fs/susfs.c; then
  cat >> fs/susfs.c <<'EOF'

/* ---- KernelSU <-> SUSFS glue (missing from this SUSFS drop) ---- */
#ifdef CONFIG_KSU_SUSFS
#include <linux/workqueue.h>
extern void susfs_run_try_umount_for_current_mnt_ns(void);
static void susfs_run_extra_works(struct work_struct *work);
DECLARE_WORK(susfs_extra_works, susfs_run_extra_works);
static void susfs_run_extra_works(struct work_struct *work)
{
#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
	susfs_run_try_umount_for_current_mnt_ns();
#endif
}
#endif /* CONFIG_KSU_SUSFS */

#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
extern int path_umount(struct path *path, int flags);

void ksu_try_umount(const char *mnt, bool check_mnt, int flags, uid_t uid)
{
	struct path path;
	int err;

	err = kern_path(mnt, 0, &path);
	if (err)
		return;
	err = path_umount(&path, flags);
	if (err)
		pr_warn("susfs: umount '%s' failed: %d\n", mnt, err);
}

void susfs_try_umount_all(uid_t uid)
{
	susfs_try_umount(uid);
}
#endif /* CONFIG_KSU_SUSFS_TRY_UMOUNT */
EOF
  echo "tree fix: added KernelSU<->SUSFS glue to fs/susfs.c"
fi

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

# --- Input boost: this tree's sched/GPU backports read the global
#     last_input_time, which is defined only by
#     drivers/devfreq/devfreq_boost.c when CONFIG_DEVFREQ_BOOST is enabled
#     (via its `#if CONFIG_INPUT_BOOST_DURATION_MS == 0` guard; that symbol
#     is undefined while CONFIG_CPU_INPUT_BOOST is off, so it evaluates to 0).
#     neptune_defconfig sets DEVFREQ_BOOST; stock does not, which left
#     last_input_time undefined at vmlinux link. ---
CONFIG_DEVFREQ_BOOST=y
CONFIG_DEVFREQ_INPUT_BOOST_DURATION_MS=58
CONFIG_DEVFREQ_WAKE_BOOST_DURATION_MS=500

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

# --- MODVERSIONS: the weak __crc_* symbols it emits are rejected by the
#     Android LLD used here ("relocation R_AARCH64_ABS32/PREL32 cannot be
#     used against symbol '__crc_...'; recompile with -fPIC") when linking
#     the PIE arm64 vmlinux. Every module is built in-tree from this same
#     source tree, so symbol versioning is not needed. ---
# CONFIG_MODVERSIONS is not set

# --- SELinux: permissive by default ---
CONFIG_SECURITY_SELINUX_BOOTPARAM=y
CONFIG_SECURITY_SELINUX_BOOTPARAM_VALUE=0
CONFIG_SECURITY_SELINUX_DEVELOP=y
EOF
echo "::endgroup::"
