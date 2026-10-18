#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Fixups for helpers that the 5.10 BPF backport uses but this 4.14 tree lacks.
#
# The backport range (cc47ca5^..7b03162) was authored against PhoenixKernel's
# 4.14 tree, which already carries a few small helpers that the ArrowOS
# tree does not.  The range does NOT add them (the commits that introduced
# them are older than the range), so they must be re-added here.
#
# Verified for this tree:
#   * include/linux/stddef.h : sizeof_field()      (used by net/core/filter.c,
#                                                    kernel/bpf/local_storage.c)
#   * include/linux/skbuff.h : skb_increase_gso_size()/skb_decrease_gso_size()
#                                                  (used by net/core/filter.c)
#   * include/linux/pid.h    : 4.15 pid layout (PIDTYPE_TGID + pid_links)
#   * atomic headers         : generic atomic_fetch_add_unless(), no
#                              __atomic_add_unless() / renamed call sites
#
# Every step is guarded, so the script is idempotent and a no-op when the
# helper is already present.
# ---------------------------------------------------------------------------
set -euo pipefail

on_err() {
  local rc=$?
  echo "::error::fixups.sh failed (rc=$rc) at line ${LINENO}: ${BASH_COMMAND}"
}
trap 'on_err' ERR

ROOT="${GITHUB_WORKSPACE:-$PWD}"
cd "$ROOT/kernel"

changed=0

# --- sizeof_field() --------------------------------------------------------
# Must go before the FINAL #endif (include guard): the first bare #endif closes
# the #ifdef __compiler_offsetof / #else block, so inserting there would put the
# macro in the inactive branch.
if ! grep -q 'define sizeof_field' include/linux/stddef.h; then
  echo "fixup: adding sizeof_field() to include/linux/stddef.h"
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
  changed=1
fi

# --- skb_increase_gso_size() / skb_decrease_gso_size() ---------------------
if ! grep -q 'skb_increase_gso_size' include/linux/skbuff.h; then
  echo "fixup: adding skb_increase/decrease_gso_size() to include/linux/skbuff.h"
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
  changed=1
fi

# --- core headers restored verbatim from the backport endpoint -------------
# A few "merge-hostile" core files come out of the 1024-commit cherry-pick
# internally inconsistent: git keeps some of ArrowOS's hunks next to the
# incoming ones, so e.g. include/linux/atomic.h still calls
# __atomic_add_unless() (whose arm64 definition the range deletes) while
# include/linux/pid.h keeps the pre-4.15 enum that the range's kernel/pid.c,
# fork.c, exit.c and sched.h no longer agree with.  The endpoint version of
# each of these files is self-consistent by construction, so take it wholesale.
#
#   include/linux/pid.h        -- the range never touches it, yet brings the
#                                 4.15 pid layout (PIDTYPE_TGID,
#                                 task_struct::pid_links, no struct pid_link).
#                                 Also covers a prerequisite being skipped.
#   the atomic headers         -- provide the generic atomic_fetch_add_unless()
#                                 and drop every __atomic_add_unless() user.
restore_endpoint() {
  local f
  for f in "$@"; do
    if ! git cat-file -e "$BPF_END:$f" 2>/dev/null; then
      echo "fixup: $f absent at backport endpoint (skipped)"
      continue
    fi
    if git diff --quiet "$BPF_END" -- "$f" 2>/dev/null; then
      continue
    fi
    echo "fixup: restoring $f from backport endpoint"
    git checkout "$BPF_END" -- "$f"
    changed=1
  done
}
: "${BPF_END:?BPF_END not set}"
restore_endpoint \
  include/linux/pid.h \
  include/linux/atomic.h \
  arch/arm64/include/asm/atomic.h \
  include/asm-generic/atomic.h \
  include/asm-generic/atomic-instrumented.h

# --- arm64 thread_info.h: drop the init_stack macro ------------------------
# The backport's include/linux/sched.h declares init_stack as a real symbol
# (allocated by INIT_TASK_DATA in the linker script), so the old
#   #define init_stack (init_thread_union.stack)
# turns that declaration into "extern unsigned long (init_thread_union.stack)[]"
# and also clashes with task.h's "extern union thread_union init_thread_union".
# The pre-range "Construct init thread stack in the linker script rather than by
# union" commit removes the same line.  Only that line is removed here: ArrowOS
# carries CAF additions in this header (TIF_MM_RELEASED, struct
# thread_info.padding) that lowmemorykiller.c and co. still need, so taking the
# whole file from the endpoint would break them.
TI="arch/arm64/include/asm/thread_info.h"
if grep -qE '^#define[[:space:]]+init_stack([[:space:]]|$)' "$TI" 2>/dev/null; then
  echo "fixup: dropping the init_stack macro from $TI"
  sed -i -E '/^#define[[:space:]]+init_stack([[:space:]]|$)/d' "$TI"
  changed=1
fi

# --- leftover __atomic_add_unless() call sites -----------------------------
# The backport replaces __atomic_add_unless() with atomic_fetch_add_unless()
# (identical "return the previous value, or @u" semantics).  Any call site left
# behind in a subsystem the defconfig builds would otherwise die with an
# implicit function declaration, so rename them.  \b keeps the triple-underscore
# ___atomic_add_unless() macro out of it.
mapfile -t legacy_atomic < <(grep -rlE '\b__atomic_add_unless\b' \
  --include='*.c' --include='*.h' drivers fs net kernel 2>/dev/null || true)
if [ "${#legacy_atomic[@]}" -gt 0 ]; then
  echo "fixup: renaming __atomic_add_unless -> atomic_fetch_add_unless in ${#legacy_atomic[@]} file(s)"
  printf '  %s\n' "${legacy_atomic[@]}"
  sed -i -E 's/\b__atomic_add_unless\b/atomic_fetch_add_unless/g' "${legacy_atomic[@]}"
  changed=1
fi

# --- top-level Makefile: drop the endif leaked by "-X theirs" --------------
# The range's kbuild commits (built-in.a rename, bpfilter CC, BTF ids) were
# authored against a top-level Makefile that carries an
#
#     ifneq ($(LLVM),)
#       ...
#     else
#       ... OBJDUMP = $(CROSS_COMPILE)objdump
#       READELF = $(CROSS_COMPILE)readelf
#       STRIP   = $(CROSS_COMPILE)strip
#     endif
#     PAHOLE  = pahole
#
# block.  This CAF Makefile has no such block, so the merge only picks up the
# block's trailing lines: a duplicated STRIP assignment and the orphan endif.
# That orphan endif then closes the outer "ifeq ($(skip-makefile),)" which
# wraps the whole file, so make dies on the file's real final endif with
#
#     Makefile:1962: *** extraneous 'endif'.  Stop.
#
# before compiling a single file.  Remove exactly that leaked tail.
MK=Makefile
if grep -qE '^READELF[[:space:]]*=[[:space:]]*\$\(CROSS_COMPILE\)readelf[[:space:]]*$' "$MK" 2>/dev/null; then
  awk '
    { a[NR]=$0 }
    END {
      for (i=1;i<=NR;i++) {
        if (a[i] !~ /^READELF[ \t]*=[ \t]*\$\(CROSS_COMPILE\)readelf[ \t]*$/) continue
        if (a[i+1] ~ /^STRIP[ \t]*=[ \t]*\$\(CROSS_COMPILE\)strip[ \t]*$/ \
            && a[i+2] ~ /^endif[ \t]*$/ \
            && a[i+3] ~ /^PAHOLE[ \t]*=[ \t]*pahole[ \t]*$/) {
          skip[i+1]=1; skip[i+2]=1
        } else if (a[i+1] ~ /^endif[ \t]*$/ \
            && a[i+2] ~ /^PAHOLE[ \t]*=[ \t]*pahole[ \t]*$/) {
          skip[i+1]=1
        }
      }
      for (i=1;i<=NR;i++) if (!skip[i]) print a[i]
    }' "$MK" > "$MK.tmp"
  if ! cmp -s "$MK" "$MK.tmp"; then
    echo "fixup: dropping the leaked endif (and duplicate STRIP) from the top-level Makefile"
    mv "$MK.tmp" "$MK"
    changed=1
  else
    rm -f "$MK.tmp"
  fi
fi

# --- 5.10 BPF cluster: restore the endpoint's files wholesale --------------
# The range was authored against PhoenixKernel's tree, so for the files that
# make up the BPF core the "-X theirs" cherry-pick still leaves a hybrid: git
# keeps ArrowOS's hunks next to the incoming ones.  Concretely, the merged
# include/linux/filter.h has no bpf_compute_data_pointers() while the incoming
# net/core/filter.c calls the 5.10 helpers, the merged kernel/bpf/*.c mix the
# 5.10 verifier with the 4.14 map/syscall internals, and so on.  Each endpoint
# file is self-consistent by construction (it is what PhoenixKernel builds),
# so take those files wholesale.  Files where ArrowOS/CAF code *must* win
# (include/net/sock.h, net/core/dev.c, kernel/sysctl.c, security/selinux,
# include/linux/lsm_hooks.h, include/linux/cgroup.h, net/tls/*) are
# deliberately not listed.
: "${BPF_END:?BPF_END not set}"

# (a) kernel/bpf/ as a whole, so the verifier, syscall, btf, trampoline,
#     iterators, devmap/cpumap, struct-ops, LSM and preload sources all match
#     the endpoint's include/linux/bpf*.h.  git checkout <tree> -- <dir> also
#     brings in the pre-range files the range's Makefile references but never
#     created (disasm.c, offload.c, sysfs_btf.c).
if git cat-file -e "$BPF_END:kernel/bpf/Makefile" 2>/dev/null; then
  if ! git diff --quiet "$BPF_END" -- kernel/bpf 2>/dev/null; then
    echo "fixup: restoring kernel/bpf/ from the backport endpoint"
    git checkout "$BPF_END" -- kernel/bpf
    changed=1
  fi
  # Drop files the endpoint does not carry (the 4.14-only kernel/bpf/sockmap.c,
  # whose CONFIG_STREAM_PARSER Makefile line is gone in the endpoint).
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    if git cat-file -e "$BPF_END:$f" 2>/dev/null; then
      continue
    fi
    echo "fixup: removing $f (not present at the backport endpoint)"
    git rm -q -f -- "$f" || true
    changed=1
  done < <(git ls-files -- kernel/bpf)
else
  echo "::warning::kernel/bpf/Makefile missing at $BPF_END"
fi

# (b) the headers and the net/ sources the rest of the kernel includes.
#     include/net/page_pool.h is a new file the range's net/core/xdp.c and
#     kernel/bpf/{devmap,cpumap}.c need; CONFIG_PAGE_POOL stays unset, and its
#     page_pool_* bodies are #ifdef CONFIG_PAGE_POOL, so only the inline
#     accessors are used.
restore_endpoint \
  include/linux/bpf.h \
  include/linux/bpf-cgroup.h \
  include/linux/bpf_verifier.h \
  include/linux/bpf_types.h \
  include/linux/bpf_lsm.h \
  include/linux/bpf_local_storage.h \
  include/linux/bpf-netns.h \
  include/linux/btf.h \
  include/linux/btf_ids.h \
  include/linux/filter.h \
  include/linux/skmsg.h \
  include/linux/bpfilter.h \
  include/linux/bpf_trace.h \
  include/linux/lsm_hook_defs.h \
  include/uapi/linux/bpf.h \
  include/uapi/linux/btf.h \
  include/uapi/linux/bpf_perf_event.h \
  include/uapi/asm-generic/bpf_perf_event.h \
  include/net/bpf_sk_storage.h \
  include/net/netns/bpf.h \
  include/net/xdp.h \
  include/net/xdp_sock.h \
  include/net/page_pool.h \
  include/trace/events/xdp.h \
  net/core/filter.c \
  net/core/skmsg.c \
  net/core/sock_map.c \
  net/core/xdp.c \
  net/core/bpf_sk_storage.c \
  net/bpf/test_run.c \
  net/bpf/Makefile \
  net/ipv4/tcp_bpf.c \
  net/ipv4/bpf_tcp_ca.c \
  kernel/trace/bpf_trace.c \
  arch/arm64/net/bpf_jit_comp.c \
  security/bpf

# (c) net/core/Makefile: the endpoint builds xdp.o unconditionally and
#     bpf_sk_storage.o under CONFIG_BPF_SYSCALL (=y).  kernel/bpf/{devmap,
#     cpumap}.c (restored above) call xdp_return_frame*(), and the endpoint's
#     include/linux/bpf_types.h references sk_storage_map_ops, so both objects
#     must exist.  skmsg.o (CONFIG_NET_SOCK_MSG), sock_map.o
#     (CONFIG_BPF_STREAM_PARSER), lwt_bpf.o (CONFIG_LWTUNNEL_BPF) and
#     page_pool.o (CONFIG_PAGE_POOL) all stay out: their configs are unset.
NCM=net/core/Makefile
if [ -f "$NCM" ]; then
  if ! grep -qE '(^|[^A-Za-z0-9_])xdp\.o([^A-Za-z0-9_]|$)' "$NCM"; then
    if grep -qE 'fib_notifier\.o[[:space:]]*$' "$NCM"; then
      awk '{ if (!done && $0 ~ /fib_notifier\.o[[:space:]]*$/) {
               sub(/fib_notifier\.o[[:space:]]*$/, "fib_notifier.o xdp.o"); done=1
             }
             print }' "$NCM" > "$NCM.tmp"
      if ! cmp -s "$NCM" "$NCM.tmp"; then
        echo "fixup: adding xdp.o to $NCM"
        mv "$NCM.tmp" "$NCM"
        changed=1
      else
        rm -f "$NCM.tmp"
      fi
    else
      echo "::warning::$NCM has no 'fib_notifier.o' line; xdp.o not added"
    fi
  fi
  if ! grep -qE '^obj-\$\(CONFIG_BPF_SYSCALL\)[[:space:]]*\+=[[:space:]]*bpf_sk_storage\.o' "$NCM"; then
    echo "fixup: adding bpf_sk_storage.o to $NCM"
    printf '\nobj-$(CONFIG_BPF_SYSCALL) += bpf_sk_storage.o\n' >> "$NCM"
    changed=1
  fi
fi

# (d) net/ipv4/Makefile came out of the merge with the endpoint's obj-y tail
#     ("metrics.o udp_tunnel_stub.o").  udp_tunnel_stub.c *is* part of the
#     range, but metrics.c is a pre-range Phoenix file and the endpoint's copy
#     takes the 5.10 tcp_ca_get_key_by_name(net, ...) API, whose net-namespaced
#     tcp_cong.c/tcp.h are also pre-range and would drag the whole TCP CA layer
#     along.  Nothing calls ip_metrics_convert() in this tree, so drop the
#     object instead of importing the file.
NIM=net/ipv4/Makefile
if [ -f "$NIM" ] && [ ! -f net/ipv4/metrics.c ] \
   && grep -qE '(^|[[:space:]])metrics\.o([[:space:]]|$)' "$NIM"; then
  sed -i -E 's/(^|[[:space:]])metrics\.o[[:space:]]+udp_tunnel_stub\.o/\1udp_tunnel_stub.o/' "$NIM"
  if grep -qE '(^|[[:space:]])metrics\.o([[:space:]]|$)' "$NIM"; then
    echo "::warning::could not drop metrics.o from $NIM"
  else
    echo "fixup: dropping the accidentally-imported metrics.o from $NIM"
    changed=1
  fi
fi

# (e) bpf_compute_data_end_sk_skb() lived in the 4.14-only kernel/bpf/sockmap.c
#     (now removed); the endpoint moved it into include/net/tcp.h next to
#     TCP_SKB_CB().  The endpoint's net/core/filter.c calls it from
#     sk_skb_try_make_writable() and the sk_skb adjust-room path, so re-add it
#     (only bpf.data_end is needed -- the tcp_skb_bpf_* helpers are used by
#     net/core/skmsg.c and net/core/sock_map.c, which this defconfig does not
#     build).
TC=include/net/tcp.h
if [ -f "$TC" ] && ! grep -q 'bpf_compute_data_end_sk_skb' "$TC"; then
  echo "fixup: adding bpf_compute_data_end_sk_skb() to $TC"
  awk '
    { print }
    !done && /^#define[ \t]+TCP_SKB_CB\(/ {
      print ""
      print "static inline void bpf_compute_data_end_sk_skb(struct sk_buff *skb)"
      print "{"
      print "\tTCP_SKB_CB(skb)->bpf.data_end = skb->data + skb_headlen(skb);"
      print "}"
      done=1
    }' "$TC" > "$TC.tmp"
  mv "$TC.tmp" "$TC"
  changed=1
fi

# (f) leftover bpf_compute_data_end() call sites.  The 5.10 helper is
#     bpf_compute_data_pointers(); \b keeps bpf_compute_data_end_sk_skb out of
#     it.  Only net/sched/cls_bpf.c is built out of these (act_bpf is off,
#     lwt_bpf needs CONFIG_LWTUNNEL_BPF, sockmap.c is gone), but rename them
#     all so a later defconfig cannot resurrect the error.
mapfile -t legacy_cdata < <(grep -rlE '\bbpf_compute_data_end\b' \
  --include='*.c' --include='*.h' drivers fs net kernel include 2>/dev/null || true)
if [ "${#legacy_cdata[@]}" -gt 0 ]; then
  echo "fixup: renaming bpf_compute_data_end -> bpf_compute_data_pointers in ${#legacy_cdata[@]} file(s)"
  printf '  %s\n' "${legacy_cdata[@]}"
  sed -i -E 's/\bbpf_compute_data_end\b/bpf_compute_data_pointers/g' "${legacy_cdata[@]}"
  changed=1
fi

# ===========================================================================
# (g) Repair the remaining "-X theirs" hybrids.
#
# "-X theirs" is the right conflict policy for the BPF core, but it is wrong
# wherever an incoming hunk belongs to a prerequisite whose other half never
# reached this tree: the file then carries the endpoint's declarations next to
# ArrowOS's definitions (or the reverse) and nothing compiles.  Every case
# below was diagnosed from the run-#3 compiler log, and for every one of them
# exactly one side is internally consistent.
#
# backport-bpf.sh tags the pristine ArrowOS tip as the "base" branch before it
# starts cherry-picking, so ArrowOS's own copy is always reachable.
# ===========================================================================
ARROW_BASE_REF="${ARROW_BASE_REF:-base}"
if ! git rev-parse --verify -q "${ARROW_BASE_REF}^{commit}" >/dev/null 2>&1; then
  ARROW_BASE_REF="$(git rev-parse --verify -q 'origin/arrow-12.1^{commit}' 2>/dev/null || true)"
fi
if [ -z "$ARROW_BASE_REF" ]; then
  echo "::error::cannot resolve the ArrowOS base ref (tried 'base' and origin/arrow-12.1)"
  exit 1
fi
echo "ArrowOS base ref: $ARROW_BASE_REF"

restore_arrow() {
  local f
  for f in "$@"; do
    if ! git cat-file -e "$ARROW_BASE_REF:$f" 2>/dev/null; then
      echo "::warning::restore_arrow: $f not present in $ARROW_BASE_REF, skipped"
      continue
    fi
    if git diff --quiet "$ARROW_BASE_REF" -- "$f" 2>/dev/null; then
      continue
    fi
    echo "fixup: restoring $f from the ArrowOS base ($ARROW_BASE_REF)"
    git checkout "$ARROW_BASE_REF" -- "$f"
    changed=1
  done
}

# (g1) Endpoint files this tree references but never received.  None of them
#      is created by a commit in the range, so the cherry-pick had nothing to
#      apply and they are simply absent.
#
#      include/net/netns/xdp.h -- the merge kept the endpoint's
#      net/net_namespace.h, which includes it; single largest source of
#      "file not found" diagnostics in run #3 (717 of them, in every
#      translation unit that pulls in the netns headers).
#
#      include/linux/xarray.h -- lib/idr.c and include/linux/idr.h came out of
#      the merge as the endpoint's 5.10 implementation, which sits on
#      Phoenix's lock-only xarray stub (a full 5.10 xarray is a much larger
#      change and would drag in radix-tree rework this tree does not have).
restore_endpoint \
  include/net/netns/xdp.h \
  include/linux/xarray.h

# (g2) ArrowOS's own copy is the only consistent one.  Each of these files is
#      either untouched by the range (so the merge half-applied something
#      unrelated) or a hybrid whose reference side does not exist in this
#      tree.  What they have in common is that ArrowOS's version only ever
#      depended on ArrowOS's headers, which are still the headers around them.
#
#      kernel/umh.c + include/linux/umh.h
#          The merge took the endpoint's copy, which uses call_usermodehelper
#          's 5.10 "struct file *" flow (subprocess_info::file, do_execve_file,
#          PF_UMH).  Nothing in this tree can provide those: the only caller of
#          the new API is kernel/usermode_driver.c, which is built only when
#          CONFIG_USERMODE_DRIVER=y -- and that symbol is selected by
#          CONFIG_BPF_PRELOAD, which this defconfig no longer sets.
#      kernel/signal.c
#          Carries the pid-rework hunks (cgroup_task_frozen, JOBCTL_TRAP_FREEZE,
#          add_to_oom_reaper) without the cgroup and mm changes they belong to.
#      kernel/trace/blktrace.c
#          The endpoint's version drives the 5.10 kernfs node-id API with the
#          wrong arity against ArrowOS's kernfs headers (8 pointer-to-integer
#          conversion errors).  ArrowOS's copy is the one whose 10 uses match.
#      kernel/trace/trace_event_perf.c
#          Taken from the endpoint by step (d); it calls
#          create_local_trace_uprobe() and reads uprobe_path/probe_offset,
#          which live in the endpoint's trace_uprobe.c and uapi perf_event.h.
#          Pulling those two in as well would drag a third and a fourth file
#          behind them; ArrowOS's copy works with the perf machinery this tree
#          actually has.
#      drivers/char/random.c
#          The merge kept ArrowOS's body but took the endpoint's renamed
#          cryptohash primitives (sha_init -> sha1_init) and its sysctl
#          signature, which produced a redefinition of 'buf'.  ArrowOS's copy
#          plus the three sha1 renames below is the self-consistent pair.
restore_arrow \
  include/linux/umh.h \
  kernel/umh.c \
  kernel/signal.c \
  kernel/trace/blktrace.c \
  kernel/trace/trace_event_perf.c \
  drivers/char/random.c

# (g2a) drivers/char/random.c was written against ArrowOS's cryptohash.h; the
#       rest of the tree (lib/sha1.c, the crypto drivers) follows the
#       endpoint's renaming, so keep ArrowOS's file and rename its three
#       primitives to match.
RC=drivers/char/random.c
if [ -f "$RC" ] && grep -qE '\bsha_init\b|\bsha_transform\b|\bSHA_WORKSPACE_WORDS\b' "$RC"; then
  echo "fixup: renaming sha_init/sha_transform/SHA_WORKSPACE_WORDS in $RC"
  sed -i -E \
    -e 's/\bsha_init\b/sha1_init/g' \
    -e 's/\bsha_transform\b/sha1_transform/g' \
    -e 's/\bSHA_WORKSPACE_WORDS\b/SHA1_WORKSPACE_WORDS/g' "$RC"
  changed=1
fi

# (g3) include/linux/skbuff.h: restore ArrowOS's 8-argument
#      __skb_flow_dissect() declaration.
#
#      The declaration came out of the merge with the endpoint's
#      net-namespaced 9-argument form, while net/core/flow_dissector.c is
#      ArrowOS's 8-argument definition (the range only added the BPF entry
#      points to that file) and all three inline wrappers plus the one call
#      inside flow_dissector.c pass 8 arguments.  2249 of run #3's
#      diagnostics are "too few arguments, expected 9, have 8"; no file in this
#      tree calls the net-namespaced form, so the parameter goes back.
SB=include/linux/skbuff.h
if [ -f "$SB" ] && grep -q '^bool __skb_flow_dissect(const struct net \*net,$' "$SB"; then
  echo "fixup: restoring ArrowOS's 8-argument __skb_flow_dissect() declaration in $SB"
  perl -0pi -e 's/bool __skb_flow_dissect\(const struct net \*net,\n[ \t]*const struct sk_buff \*skb,/bool __skb_flow_dissect(const struct sk_buff *skb,/' "$SB"
  if grep -q '^bool __skb_flow_dissect(const struct net \*net,$' "$SB"; then
    echo "::warning::could not rewrite the __skb_flow_dissect() declaration in $SB"
  else
    changed=1
  fi
fi

# (g4) include/linux/sched.h: put ArrowOS's wake_up_idle helpers back.
#      fs/proc/base.c and drivers/mmc/core/queue.c call sched_get_wake_up_idle(),
#      sched_set_wake_up_idle() and set_wake_up_idle(); all three are
#      ArrowOS-owned static inlines that live in include/linux/sched.h, which
#      the range rewrote without them (their backing PF_WAKE_UP_IDLE flag did
#      survive the merge, so the helpers only need to be re-added).
SH=include/linux/sched.h
if [ -f "$SH" ] && ! grep -q 'sched_get_wake_up_idle' "$SH"; then
  wakeup_block="$(git show "$ARROW_BASE_REF:$SH" | awk '
    /^static inline u32 sched_get_wake_up_idle\(struct task_struct \*p\)$/ { f=1 }
    f { print; if ($0 == "}") { c++; if (c == 3) exit } }')"
  if [ -n "$wakeup_block" ] && echo "$wakeup_block" | grep -q 'set_wake_up_idle'; then
    echo "fixup: re-adding the wake_up_idle helpers to $SH"
    awk -v blk="$wakeup_block" '
      { a[NR] = $0 }
      END {
        for (i = NR; i >= 1; i--) if (a[i] ~ /^#endif/) { ins = i; break }
        for (i = 1; i <= NR; i++) {
          if (i == ins) { print ""; print blk; print "" }
          print a[i]
        }
      }' "$SH" > "$SH.tmp"
    if cmp -s "$SH" "$SH.tmp"; then
      rm -f "$SH.tmp"
    else
      mv "$SH.tmp" "$SH"
      changed=1
    fi
  else
    echo "::warning::could not extract the wake_up_idle helpers from $ARROW_BASE_REF:$SH"
  fi
fi

# (g5) fs/proc/proc_sysctl.c: include linux/bpf-cgroup.h.
#      The endpoint wired BPF_CGROUP_RUN_PROG_SYSCTL() into the sysctl write
#      path but the include that declares it did not survive the merge, so the
#      macro is an implicit function.  Completing the include keeps the cgroup
#      sysctl program hook working instead of deleting the hook call.
PS=fs/proc/proc_sysctl.c
if [ -f "$PS" ] && grep -q 'BPF_CGROUP_RUN_PROG_SYSCTL' "$PS" \
   && ! grep -qE '^#include <linux/bpf-cgroup\.h>' "$PS"; then
  echo "fixup: adding #include <linux/bpf-cgroup.h> to $PS"
  if grep -qE '^#include <linux/sysctl\.h>$' "$PS"; then
    sed -i "0,/^#include <linux\/sysctl\.h>$/{s|^#include <linux/sysctl\.h>$|#include <linux/sysctl.h>\n#include <linux/bpf-cgroup.h>|}" "$PS"
  else
    sed -i "0,/^#include /{s|^#include |#include <linux/bpf-cgroup.h>\n#include |}" "$PS"
  fi
  changed=1
fi

# (g6) security/commoncap.c + include/linux/security.h: rename cap_capable()'s
#      fourth argument to match the capable LSM hook.
#      include/linux/lsm_hook_defs.h (restored from the endpoint in step (d))
#      declares the hook with "unsigned int opts", while ArrowOS's cap_capable
#      still takes "int audit", which clang reports as
#          incompatible function pointer types initializing
#          'int (*)(const struct cred *, struct user_namespace *, int, unsigned int)'
#      at LSM_HOOK_INIT(capable, cap_capable).  ArrowOS's own cap_capable()
#      stays -- unlike the endpoint's, it still carries the
#      CONFIG_ANDROID_PARANOID_NETWORK AID_NET_RAW/AID_NET_ADMIN group checks --
#      it just takes the argument under the name and type the hook expects.
CC_SRC=security/commoncap.c
if grep -q '^[[:space:]]*int cap, int audit)$' "$CC_SRC" 2>/dev/null; then
  echo "fixup: renaming cap_capable()'s argument to 'unsigned int opts' in $CC_SRC"
  perl -0pi -e 's/int cap_capable\(const struct cred \*cred, struct user_namespace \*targ_ns,\n[ \t]*int cap, int audit\)/int cap_capable(const struct cred *cred, struct user_namespace *targ_ns,\n\t\tint cap, unsigned int opts)/' "$CC_SRC"
  perl -0pi -e 's/return __cap_capable\(cred, targ_ns, cap, audit\);/return __cap_capable(cred, targ_ns, cap, opts);/' "$CC_SRC"
  changed=1
fi
SH_SEC=include/linux/security.h
if grep -q 'int cap, int audit);' "$SH_SEC" 2>/dev/null; then
  echo "fixup: updating the cap_capable() prototype in $SH_SEC"
  perl -0pi -e 's/(extern int cap_capable\(const struct cred \*cred, struct user_namespace \*ns,\n[ \t]*int cap, )int audit\);/${1}unsigned int opts);/' "$SH_SEC"
  changed=1
fi

# (g7) security/selinux/include/classmap.h: retarget the capability guard.
#      The endpoint's copy guards COMMON_CAP2_PERMS with "#if CAP_LAST_CAP >
#      CAP_BPF", but CAP_BPF does not exist in this 4.14 uapi tree, so the
#      preprocessor folds the comparison to false, fires the #error, and the
#      resulting breakage in the generated flask.h shows up as every
#      SECINITSID_* being undeclared.  Guard it on the last capability this
#      tree actually defines; the endpoint's extra "perfmon"/"bpf" permission
#      names are harmless (they only add av permission strings).
CM=security/selinux/include/classmap.h
if grep -q '^#if CAP_LAST_CAP > CAP_BPF$' "$CM" 2>/dev/null; then
  echo "fixup: retargeting the classmap capability guard in $CM"
  sed -i 's/^#if CAP_LAST_CAP > CAP_BPF$/#if CAP_LAST_CAP > CAP_AUDIT_READ/' "$CM"
  changed=1
fi

# (g8) init/main.c: drop the arch_cpu_finalize_init() call.
#      The range's start_kernel calls it, but no arm64 file in this tree
#      defines it (it is part of the 5.10 arm64 bring-up the range did not
#      carry), which surfaces as an implicit function declaration.
IM=init/main.c
if [ -f "$IM" ] && grep -q 'arch_cpu_finalize_init' "$IM"; then
  if ! grep -rq 'arch_cpu_finalize_init' arch include 2>/dev/null; then
    echo "fixup: dropping the arch_cpu_finalize_init() call from $IM"
    sed -i -E '/^[[:space:]]*arch_cpu_finalize_init\(\);[[:space:]]*$/d' "$IM"
    changed=1
  fi
fi

# (g9) init/Kconfig: put config SCHED_CORE_CTL back.
#      The merge lost the symbol (ArrowOS's own scheduler expects it and
#      stock_defconfig sets it), so olddefconfig would silently drop
#      CONFIG_SCHED_CORE_CTL=y and disable Qualcomm core control.  Re-insert
#      ArrowOS's block right after the CGROUPS menu it used to live in.
KCONF=init/Kconfig
if [ -f "$KCONF" ] && ! grep -q '^config SCHED_CORE_CTL$' "$KCONF"; then
  core_ctl_block="$(git show "$ARROW_BASE_REF:$KCONF" | awk '
    /^config SCHED_CORE_CTL$/ { f=1 }
    f { if (started && (/^config / || /^menuconfig /)) exit; print; started = 1 }')"
  if [ -n "$core_ctl_block" ] && echo "$core_ctl_block" | grep -q 'QTI Core Control'; then
    echo "fixup: restoring config SCHED_CORE_CTL to $KCONF"
    awk -v blk="$core_ctl_block" '
      { a[NR] = $0 }
      END {
        for (i = 1; i <= NR; i++) if (a[i] ~ /^endif # CGROUPS[[:space:]]*$/) { ins = i; break }
        for (i = 1; i <= NR; i++) { print a[i]; if (i == ins) { print ""; print blk } }
      }' "$KCONF" > "$KCONF.tmp"
    if cmp -s "$KCONF" "$KCONF.tmp"; then
      rm -f "$KCONF.tmp"
    else
      mv "$KCONF.tmp" "$KCONF"
      changed=1
    fi
  else
    echo "::warning::could not extract config SCHED_CORE_CTL from $ARROW_BASE_REF:$KCONF"
  fi
fi

# (g10) techpack audio: the CAF code assigns one enumeration type to another in
#       two places, which clang -20 turns into -Werror=enum-conversion.  Both
#       conversions are lossless (the enum ranges line up), so an explicit cast
#       is the fix; the code itself is ArrowOS's and untouched by the range.
for cpe in techpack/audio/asoc/codecs/wcd_cpe_services.c \
           techpack/audio/4.0/asoc/codecs/wcd_cpe_services.c; do
  [ -f "$cpe" ] || continue
  if grep -q 'notif\.result = result;' "$cpe"; then
    echo "fixup: adding explicit enum conversions to $cpe"
    sed -i -E \
      -e 's/\bnotif\.result = result;/notif.result = (enum cmi_api_result)result;/' \
      -e 's/\brc = cpe_send_msg_to_inbox\(/rc = (enum cpe_process_result)cpe_send_msg_to_inbox(/' "$cpe"
    changed=1
  fi
done

# (g11) drivers/power/supply/qcom/smb5-lib.c: pm_schg_dcdc_configure_vsysmin()
#       lost its return type (clang -20 rejects implicit int).  It is called
#       only from within the same file, so make it a file-local function the
#       way its neighbours are.
SMB=drivers/power/supply/qcom/smb5-lib.c
if [ -f "$SMB" ] && grep -qE '^pm_schg_dcdc_configure_vsysmin\(' "$SMB"; then
  echo "fixup: giving pm_schg_dcdc_configure_vsysmin() a return type in $SMB"
  sed -i -E 's/^pm_schg_dcdc_configure_vsysmin\(/static int pm_schg_dcdc_configure_vsysmin(/' "$SMB"
  changed=1
fi

# (g12) ANSI prototypes in the vendor drivers.  Several ArrowOS-era CAF files
#       define functions as "type name()" and declare them as "type name();",
#       which clang -20 rejects under -Werror=strict-prototypes (both files
#       are byte-identical to the ArrowOS base -- these are upstream CAF bugs
#       that older clang let through, not merge damage).  Only rewrite a
#       definition when the next line opens its body, and a declaration when
#       the line is exactly a prototype-less one, so statements such as
#       "return foo();" can never be touched.
fix_ansi_prototypes() {
  local f
  for f in $(find "$@" -type f \( -name '*.c' -o -name '*.h' \) 2>/dev/null | sort -u); do
    [ -f "$f" ] || continue
    awk '
      { l[NR] = $0 }
      END {
        for (i = 1; i <= NR; i++) {
          if (l[i] ~ /^[A-Za-z_][A-Za-z_0-9 \*]*\(\)$/ && l[i + 1] ~ /^[ \t]*\{/) {
            sub(/\(\)$/, "(void)", l[i]); n++
          } else if (l[i] ~ /^[A-Za-z_][A-Za-z_0-9 \*]*\(\);$/) {
            sub(/\(\);$/, "(void);", l[i]); n++
          }
        }
        for (i = 1; i <= NR; i++) print l[i]
      }' "$f" > "$f.fixups-tmp"
    if ! cmp -s "$f" "$f.fixups-tmp"; then
      echo "fixup: adding (void) to prototype-less definitions in $f"
      mv "$f.fixups-tmp" "$f"
      changed=1
    else
      rm -f "$f.fixups-tmp"
    fi
  done
}
fix_ansi_prototypes drivers/input/touchscreen/st techpack/audio drivers/power/supply/qcom

# (g13) Scope two of ArrowOS's -Werror upgrades back to warnings for this
#       build.  ArrowOS's top-level Makefile promotes -Werror=implicit-int and
#       -Werror=strict-prototypes (the toolchain supports both, so cc-option
#       keeps them), and clang 20 diagnoses far more code than the clang 11-14
#       those flags were added for: plenty of never-touched CAF vendor code
#       (sound/, drivers/gpu/msm, drivers/net, drivers/media, drivers/staging)
#       defines functions as "T f()".  Any one of them would fail a build that
#       ArrowOS itself shipped, and -k only reveals a handful per run.
#
#       The warnings themselves stay on, so the log keeps listing every site;
#       only their ability to abort the build goes away.  The diagnostics that
#       actually catch merge damage are untouched:
#         -Werror=incompatible-pointer-types  (type mismatches from hybrids)
#         -Werror-implicit-function-declaration (missing declarations)
#         -Werror=designated-init, -Werror=date-time, -Werror=vla
MK=Makefile
if [ -f "$MK" ] && ! grep -q -- '-Wno-error=strict-prototypes' "$MK"; then
  echo "fixup: demoting -Werror={implicit-int,strict-prototypes} to warnings in $MK"
  perl -0pi -e 's/(KBUILD_CFLAGS\s*\+=\s*\$\(call cc-option,-Werror=designated-init\)\n)/$1\n# ArrowOS-era CAF vendor code predates these clang-20 upgrades; keep the\n# warnings in the log but let the build continue past them.\nKBUILD_CFLAGS   += \$(call cc-option,-Wno-error=strict-prototypes)\nKBUILD_CFLAGS   += \$(call cc-option,-Wno-error=implicit-int)\n/' "$MK"
  grep -q -- '-Wno-error=strict-prototypes' "$MK" && changed=1
fi

# --- merge-artifact scan (report only) -------------------------------------
# The cherry-pick resolves every conflict with "-X theirs", which can leave a
# Kbuild file with an orphan or missing conditional; make only ever reports the
# first one it trips over.  So scan them up front and list every file that
# still looks unbalanced -- nothing is modified here.
echo "::group::merge-artifact scan"
mapfile -t mkfiles < <(find arch kernel mm fs net drivers security init lib \
  block ipc crypto scripts include -type f \
  \( -name Makefile -o -name Kbuild -o -name '*.mk' \) 2>/dev/null | sort -u || true)
if [ "${#mkfiles[@]}" -gt 0 ]; then
  awk '
    FNR==1 {
      if (NR>1 && depth>0) print prev ": " depth " unterminated conditional(s)"
      depth=0; prev=FILENAME
    }
    {
      s=$0; t=s
      sub(/\r$/, "", t); sub(/^[ \t]+/, "", t)
      if (substr(s,1,1)=="\t" || t=="" || substr(t,1,1)=="#") next
      if (t ~ /^(ifeq|ifneq|ifdef|ifndef|if)([ \t]|$)/) depth++
      else if (t ~ /^endif([ \t]|$)/) {
        if (depth==0) print FILENAME ":" FNR ": stray endif"
        else depth--
      }
    }
    END { if (depth>0) print prev ": " depth " unterminated conditional(s)" }
  ' "${mkfiles[@]}" || true
fi
mapfile -t markers < <(grep -rlE '^(<<<<<<< |>>>>>>> )' arch kernel mm fs net \
  drivers security init lib block ipc crypto scripts include 2>/dev/null || true)
if [ "${#markers[@]}" -gt 0 ]; then
  echo "::warning::conflict markers left in ${#markers[@]} file(s):"
  printf '  %s\n' "${markers[@]}"
fi
echo "::endgroup::"

# ===========================================================================
# Verification gate.  Each entry is a property the compile step is known to
# depend on; if any of them did not land, the build would only fail ~20
# minutes into "make", so fail here instead and say why.
# ===========================================================================
echo "::group::fixup verification"
vfail=0

if grep -q '^bool __skb_flow_dissect(const struct net \*net,$' include/linux/skbuff.h; then
  vfail=1; echo "::error::__skb_flow_dissect() declaration is still the 9-argument form"
else
  echo "ok: __skb_flow_dissect() declaration is back to 8 arguments"
fi
if [ -f include/net/netns/xdp.h ] && grep -q 'struct netns_xdp' include/net/netns/xdp.h; then
  echo "ok: include/net/netns/xdp.h present"
else
  vfail=1; echo "::error::include/net/netns/xdp.h is still missing"
fi
if [ -f include/linux/xarray.h ] && grep -q 'xa_lock' include/linux/xarray.h; then
  echo "ok: include/linux/xarray.h stub present"
else
  vfail=1; echo "::error::include/linux/xarray.h stub is still missing"
fi
if grep -q '^config SCHED_CORE_CTL$' init/Kconfig; then
  echo "ok: init/Kconfig keeps config SCHED_CORE_CTL"
else
  vfail=1; echo "::error::init/Kconfig lost config SCHED_CORE_CTL"
fi
if grep -q 'create_local_trace_uprobe\|uprobe_path\|probe_offset' kernel/trace/trace_event_perf.c; then
  vfail=1; echo "::error::kernel/trace/trace_event_perf.c still calls endpoint-only uprobe helpers"
else
  echo "ok: kernel/trace/trace_event_perf.c matches the perf machinery in this tree"
fi
if grep -qE '\bsha_init\b|\bsha_transform\b|\bSHA_WORKSPACE_WORDS\b' drivers/char/random.c; then
  vfail=1; echo "::error::drivers/char/random.c still uses the old sha_* cryptohash names"
else
  echo "ok: drivers/char/random.c uses the sha1_* cryptohash names"
fi
if grep -q '^#if CAP_LAST_CAP > CAP_BPF$' security/selinux/include/classmap.h; then
  vfail=1; echo "::error::classmap.h capability guard still references the non-existent CAP_BPF"
else
  echo "ok: classmap.h capability guard retargeted"
fi
if grep -q 'arch_cpu_finalize_init' init/main.c; then
  vfail=1; echo "::error::init/main.c still calls arch_cpu_finalize_init()"
else
  echo "ok: init/main.c no longer calls arch_cpu_finalize_init()"
fi
cap_bad=0
if grep -A1 '^int cap_capable(' security/commoncap.c | grep -q 'int cap, int audit'; then
  cap_bad=1
fi
if grep -A1 'extern int cap_capable(' include/linux/security.h | grep -q 'int cap, int audit'; then
  cap_bad=1
fi
if [ "$cap_bad" -ne 0 ]; then
  vfail=1; echo "::error::cap_capable() still takes 'int audit'"
else
  echo "ok: cap_capable() takes 'unsigned int opts'"
fi
if grep -q 'sched_get_wake_up_idle' include/linux/sched.h && grep -q 'PF_WAKE_UP_IDLE' include/linux/sched.h; then
  echo "ok: include/linux/sched.h carries the wake_up_idle helpers"
else
  vfail=1; echo "::error::include/linux/sched.h is still missing the wake_up_idle helpers"
fi
if grep -rq '__skb_flow_dissect(net' net kernel 2>/dev/null; then
  vfail=1; echo "::error::a caller still uses the net-namespaced __skb_flow_dissect() form"
else
  echo "ok: no caller uses the net-namespaced __skb_flow_dissect() form"
fi
if [ -f kernel/bpf/sockmap.c ] || grep -q 'sockmap\.o' net/core/Makefile kernel/bpf/Makefile 2>/dev/null; then
  vfail=1; echo "::error::kernel/bpf/sockmap.c (the A-only 4.14 sockmap) is back"
else
  echo "ok: kernel/bpf/sockmap.c still removed"
fi
proto_artifacts="$(grep -rn '()void)' arch kernel mm fs net drivers security init lib block ipc \
  crypto scripts include techpack 2>/dev/null | head -5 || true)"
if [ -n "$proto_artifacts" ]; then
  vfail=1; echo "::error::()void) artifacts left by the prototype fixup:"; echo "$proto_artifacts"
else
  echo "ok: no mangled prototypes"
fi
if grep -q '^struct device \*getDev(void)$' drivers/input/touchscreen/st/fts_lib/ftsIO.c \
   && grep -q '^char \*timestamp(void)$' drivers/input/touchscreen/st/fts_lib/ftsTime.c; then
  echo "ok: ST touchscreen getDev()/timestamp() are prototyped"
else
  vfail=1; echo "::error::ST touchscreen prototype-less definitions remain"
fi
symlink_bad=0
for sl in techpack/audio/include/soc/internal.h techpack/audio/soc/core.h \
          techpack/audio/soc/pinctrl-utils.h; do
  [ -e "$sl" ] || continue
  # The prototype fixup must never turn these symlinks (to drivers/base and
  # drivers/pinctrl) into regular files; git's recorded mode is the truth even
  # where Windows checks symlinks out as text.
  git ls-files -s "$sl" 2>/dev/null | grep -q '^120000' || symlink_bad=1
done
if [ "$symlink_bad" -ne 0 ]; then
  vfail=1; echo "::error::a techpack symlink was converted to a regular file"
else
  echo "ok: techpack symlinks untouched"
fi
if grep -q -- '-Wno-error=strict-prototypes' Makefile && grep -q -- '-Wno-error=implicit-int' Makefile; then
  echo "ok: ArrowOS's strict-prototypes/implicit-int -Werror upgrades demoted"
else
  vfail=1; echo "::error::-Wno-error demotion missing from the top-level Makefile"
fi
if [ "$vfail" -ne 0 ]; then
  echo "::error::one or more fixups did not apply; refusing to continue with a tree that is known not to build"
  exit 1
fi
echo "::endgroup::"

if [ "$changed" = 1 ]; then
  git add -A
  git commit -q -m "fixup: restore core endpoint headers + atomic/skb helpers + Makefile for 5.10 BPF backport" || true
  echo "fixups committed"
else
  echo "no fixups needed"
fi
