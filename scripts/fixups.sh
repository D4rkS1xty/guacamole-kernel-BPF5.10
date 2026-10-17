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

if [ "$changed" = 1 ]; then
  git add -A
  git commit -q -m "fixup: restore core endpoint headers + atomic/skb helpers + Makefile for 5.10 BPF backport" || true
  echo "fixups committed"
else
  echo "no fixups needed"
fi
