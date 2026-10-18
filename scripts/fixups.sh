#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# W-approach fixups: reset non-island to base (A), apply island-only grafts.
set -euo pipefail

on_err() {
  local rc=$?
  echo "::error::fixups.sh failed at line $BASH_LINENO rc=$rc"
  exit $rc
}
trap on_err ERR

ROOT="${GITHUB_WORKSPACE:-$PWD}"
cd "$ROOT/kernel"

# Resolve ArrowOS base
ARROW_BASE_REF=base
if ! git rev-parse --verify --quiet "$ARROW_BASE_REF" >/dev/null 2>&1; then
  if git rev-parse --verify --quiet origin/arrow-12.1 >/dev/null 2>&1; then
    ARROW_BASE_REF=origin/arrow-12.1
  else
    echo "::error::cannot find base ref (need base or origin/arrow-12.1)"
    exit 1
  fi
fi
echo "fixups: using ARROW_BASE_REF=$ARROW_BASE_REF"
echo "fixups: HEAD=$(git rev-parse --short HEAD) base=$(git rev-parse --short $ARROW_BASE_REF)"

# Island predicate
is_island() {
  local f="$1"
  [[ "$f" == arch/arm64/net/* ]] && return 0
  [[ "$f" == kernel/bpf/* ]] && return 0
  [[ "$f" == kernel/trace/bpf_trace.c ]] && return 0
  [[ "$f" == net/bpf/* ]] && return 0
  [[ "$f" == net/core/bpf_sk_storage.c ]] && return 0
  [[ "$f" == net/core/filter.c ]] && return 0
  [[ "$f" == net/core/skmsg.c ]] && return 0
  [[ "$f" == net/core/sock_map.c ]] && return 0
  [[ "$f" == net/core/xdp.c ]] && return 0
  [[ "$f" == net/ipv4/tcp_bpf.c ]] && return 0
  [[ "$f" == net/ipv4/bpf_tcp_ca.c ]] && return 0
  [[ "$f" == net/sched/act_bpf.c ]] && return 0
  [[ "$f" == net/sched/cls_bpf.c ]] && return 0
  [[ "$f" == security/bpf/* ]] && return 0
  [[ "$f" == security/security.c ]] && return 0
  [[ "$f" == security/Makefile ]] && return 0
  [[ "$f" == security/Kconfig ]] && return 0
  [[ "$f" == security/lockdown/* ]] && return 0
  [[ "$f" == security/safesetid/* ]] && return 0
  [[ "$f" == scripts/cc-can-link.sh ]] && return 0
  case "$f" in
    include/linux/bpf*|include/linux/bpfilter.h|include/linux/btf.h|include/linux/btf_ids.h|include/linux/filter.h|include/linux/lsm_hook_defs.h|include/linux/lsm_hooks.h|include/linux/skmsg.h|include/linux/tnum.h|include/linux/sockptr.h|include/linux/error-injection.h|include/linux/bpf_lirc.h)
      return 0 ;;
    include/net/netns/xdp.h|include/net/page_pool.h|include/net/xdp.h|include/net/bpf_sk_storage.h|include/net/netns/bpf.h)
      return 0 ;;
    include/trace/events/xdp.h|include/trace/events/bpf_test_run.h)
      return 0 ;;
    include/uapi/linux/bpf.h|include/uapi/linux/bpf_perf_event.h|include/uapi/linux/btf.h|include/uapi/linux/if_xdp.h)
      return 0 ;;
    include/uapi/asm-generic/bpf_perf_event.h|arch/arm64/include/uapi/asm/bpf_perf_event.h)
      return 0 ;;
  esac
  return 1
}

echo "fixups: W0 island reset"
git diff --name-only "$ARROW_BASE_REF" HEAD | while read -r f; do
  [ -z "$f" ] && continue
  if ! is_island "$f"; then
    git checkout "$ARROW_BASE_REF" -- "$f" 2>/dev/null || true
  fi
done
git diff --name-only --diff-filter=A "$ARROW_BASE_REF" HEAD | while read -r f; do
  [ -z "$f" ] && continue
  if ! is_island "$f"; then
    git rm -f -- "$f" 2>/dev/null || true
  fi
done
git diff --name-only --diff-filter=D "$ARROW_BASE_REF" HEAD | while read -r f; do
  [ -z "$f" ] && continue
  if is_island "$f"; then
    continue
  fi
  git checkout "$ARROW_BASE_REF" -- "$f" 2>/dev/null || true
done

echo "fixups: reset complete"
git status --short | wc -l | xargs -I{} echo "fixups: status lines={}"
echo done
