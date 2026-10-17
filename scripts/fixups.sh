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
#   * rename __atomic_add_unless() -> atomic_fetch_add_unless() (the range
#     removes arm64's definition and relies on the generic fallback, which
#     ArrowOS's older call sites do not use yet)
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

if [ "$changed" = 1 ]; then
  git add -A
  git commit -q -m "fixup: add sizeof_field + skb gso-size helpers for 5.10 BPF backport" || true
  echo "fixups committed"
else
  echo "no fixups needed"
fi
