#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Backport the 5.10 BPF stack onto the ArrowOS guacamole (4.14) tree
# (ArrowOS-Devices/android_kernel_oneplus_sm8150, branch arrow-12.1).
#
# This cherry-picks the exact range given in 4.14_5.10bpf_commits.txt:
#
#   git fetch https://github.com/PhoenixKernel/linux.git android-4.14-phoenix
#   git cherry-pick cc47ca5651d869c037f90cb5276d60f240c00719^..7b031620e7605c2cae5597bdc53f306e030ffd4a
#
# Because ArrowOS's tree is not byte-identical to PhoenixKernel's, some
# commits conflict. This script applies them one at a time with
#   git cherry-pick -x -X theirs
# so that conflicts are resolved per-hunk by taking the incoming (PhoenixKernel)
# side while the surrounding base-tree code is preserved.  A whole-file
# fallback is used only for the handful of files git cannot merge at all, and
# commits that still cannot be applied are skipped and reported; the build then
# continues so we can see what is still missing.
#
# The range's first commit already uses PIDTYPE_TGID, which landed *before* the
# range in PhoenixKernel but is absent from ArrowOS's tree.  Those prerequisite
# commits (the 4.15 pid rework) are cherry-picked first -- see BPF_PREREQS.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="${GITHUB_WORKSPACE:-$PWD}"
KDIR="$ROOT/kernel"
: "${BPF_REPO:?BPF_REPO not set}"
: "${BPF_BRANCH:?BPF_BRANCH not set}"
: "${BPF_START:?BPF_START not set}"
: "${BPF_END:?BPF_END not set}"
BPF_DEPTH="${BPF_DEPTH:-1300}"
# Pre-range commits the backport depends on that the ArrowOS tree does not
# have: the complete 4.15 "pid rework" series that sits immediately below the
# range in PhoenixKernel.  The range's first commit already passes PIDTYPE_TGID
# into group_send_sig_info(), later ones drop init/init_task.c's thread-union
# definition in favour of the linker-script one, and the whole series assumes
# signal_struct::leader_pid / ::pgrp / ::session -- none of which exist in
# ArrowOS's 4.14 tree, so the entire series has to come across first.  Given as
# a commit range and expanded (oldest first) once the history is fetched.
BPF_PREREQ_RANGE="${BPF_PREREQ_RANGE:-218e8b8c448fb0294965ae92a6c229b3ca489165^..554c38ad4f7f99babf7f58324a38e3fa71238e7b}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

cd "$KDIR"
git config user.email "ci@localhost"
git config user.name  "guacamole-builder"
git config advice.detachedHead false

echo "=========== BPF backport ==========="
echo "repo   : $BPF_REPO"
echo "branch : $BPF_BRANCH"
echo "start  : $BPF_START (cc47ca5)"
echo "end    : $BPF_END (7b03162)"
echo "depth  : $BPF_DEPTH"

echo "::group::fetch backport source"
git remote remove bpf 2>/dev/null || true
git remote add bpf "$BPF_REPO"
# Shallow fetch of exactly the backport tip (with blobs) so all cherry-pick
# merges happen locally without lazy-fetch round trips.
fetch_range() {
  local depth="$1"
  git fetch --no-tags --depth="$depth" bpf "$BPF_END"
}
# The oldest prerequisite is the deepest history we need beyond the range.
oldest_prereq="${BPF_PREREQ_RANGE%%..*}"
oldest_prereq="${oldest_prereq%^}"
needs_deeper() {
  git rev-parse --verify --quiet "${BPF_START}^" >/dev/null || return 0
  git rev-parse --verify --quiet "$oldest_prereq" >/dev/null || return 0
  return 1
}
fetch_range "$BPF_DEPTH"
while needs_deeper; do
  if [ "$BPF_DEPTH" -ge 8192 ]; then
    echo "::warning::depth $BPF_DEPTH still missing the range base or prerequisites"
    break
  fi
  echo "::warning::depth $BPF_DEPTH did not reach the range base/prereqs, retrying deeper"
  BPF_DEPTH=$((BPF_DEPTH * 2))
  fetch_range "$BPF_DEPTH"
done
git rev-parse --verify --quiet "${BPF_END}^{commit}" >/dev/null \
  || { echo "::error::cannot resolve $BPF_END after fetch"; exit 1; }
git rev-parse --verify --quiet "${BPF_START}^" >/dev/null \
  || { echo "::error::cannot resolve ${BPF_START}^ (range base) after fetch"; exit 1; }
git rev-parse --verify --quiet "$oldest_prereq" >/dev/null \
  || { echo "::error::cannot resolve prerequisite $oldest_prereq after fetch"; exit 1; }
echo "fetched $(git rev-list --count "$BPF_START^..$BPF_END") commits in range"
git log --oneline -1 "$BPF_END"
echo "::endgroup::"

# Diagnostic only: merge-base may be unavailable on a shallow fetch.
echo "merge-base(ArrowOS HEAD, BPF) = $(git merge-base HEAD "$BPF_END" 2>/dev/null || echo 'unavailable (shallow)')"

# Tag the pristine base so the tree can always be reset/rebuilt from it.
git branch -f base HEAD

mapfile -t COMMITS < <(git rev-list --reverse "$BPF_START^..$BPF_END")
TOTAL=${#COMMITS[@]}
echo "::notice::cherry-picking $TOTAL commits"

declare -a skip_list=()
declare -a conflict_files=()
declare -a prereq_report=()

# Apply one commit.  Returns 0 if it applied cleanly, 1 if git resolved it
# (per-hunk with -X theirs, or via the whole-file fallback), 2 if it had to be
# skipped.
pick() {
  local c="$1"
  if git cherry-pick -x -X theirs --allow-empty --keep-redundant-commits "$c" >/tmp/cp.log 2>&1; then
    return 0
  fi

  # A conflict git could not resolve even with -X theirs: take the whole file
  # from the incoming side for the unmergeable files only.
  if [ -f .git/CHERRY_PICK_HEAD ] || [ -d .git/rebase-merge ] || [ -d .git/sequencer ]; then
    mapfile -t conflicted < <(git diff --name-only --diff-filter=U 2>/dev/null || true)
    if [ "${#conflicted[@]}" -gt 0 ]; then
      for f in "${conflicted[@]}"; do
        conflict_files+=("$f")
        if git checkout --theirs -- "$f" >/dev/null 2>&1; then
          git add -- "$f"
        else
          git rm -f --ignore-unmatch -- "$f" >/dev/null 2>&1 || true
        fi
      done
    fi
    if git -c core.editor=true cherry-pick --continue >/tmp/cp.log 2>&1; then
      return 1
    fi
  fi

  git cherry-pick --abort >/dev/null 2>&1 || true
  return 2
}

# --- prerequisites (pre-range commits the range depends on) ----------------
mapfile -t PREREQS < <(git rev-list --reverse "$BPF_PREREQ_RANGE" 2>/dev/null)
if [ "${#PREREQS[@]}" -eq 0 ]; then
  echo "::error::could not expand prerequisite range $BPF_PREREQ_RANGE"
  exit 1
fi
echo "::group::cherry-picking prerequisites (${#PREREQS[@]} pid-rework commits)"
for p in "${PREREQS[@]}"; do
  psub="$(git log -1 --format=%s "$p" 2>/dev/null || echo '?')"
  pick "$p"; rc=$?
  case $rc in
    0) st=clean ;;
    1) st=resolved ;;
    *) st=skipped ;;
  esac
  prereq_report+=("$st  ${p:0:12}  $psub")
  echo "  ${p:0:12} $psub -> $st"
done
echo "::endgroup::"

mapfile -t COMMITS < <(git rev-list --reverse "$BPF_START^..$BPF_END")
TOTAL=${#COMMITS[@]}
echo "::notice::cherry-picking $TOTAL commits"

applied=0; resolved=0; skipped=0

for c in "${COMMITS[@]}"; do
  subject="$(git log -1 --format=%s "$c")"
  pick "$c"; rc=$?
  case $rc in
    0) applied=$((applied+1)) ;;
    1) resolved=$((resolved+1)) ;;
    2) skipped=$((skipped+1)); skip_list+=("${c:0:12} $subject") ;;
  esac
done

echo "::notice::backport summary: applied=$applied resolved-with-conflicts=$resolved skipped=$skipped"

if [ "$skipped" -gt 0 ]; then
  echo "::warning::$skipped BPF commit(s) could not be applied and were skipped"
  for s in "${skip_list[@]}"; do echo "::warning::SKIPPED $s"; done
fi

{
  echo ""
  echo "## 5.10 BPF backport"
  if [ "${#prereq_report[@]}" -gt 0 ]; then
    echo ""
    echo "### Prerequisites (pre-range pid rework)"
    echo '```'
    printf '%s\n' "${prereq_report[@]}"
    echo '```'
  fi
  echo "- range: \`cc47ca5^..7b03162\` ($TOTAL commits)"
  echo "- applied cleanly: **$applied**"
  echo "- applied after auto-resolving conflicts: **$resolved**"
  echo "- skipped: **$skipped**"
  if [ "$skipped" -gt 0 ]; then
    echo ""
    echo "### Skipped commits"
    echo '```'
    printf '%s\n' "${skip_list[@]}"
    echo '```'
  fi
  echo ""
  echo "### Conflicted files (auto-resolved with PhoenixKernel side)"
  echo '```'
  printf '%s\n' "${conflict_files[@]}" | sort -u
  echo '```'
} >> "$SUMMARY"

# --- critical backport artifacts -------------------------------------------
# CONFIG_BPF_LSM cannot work (and the tree cannot link) unless the LSM refactor
# (9a610266 "security: Refactor declaration of LSM hooks") and the BPF LSM
# plumbing (60c272bf "bpf: lsm: Initialize the BPF LSM hooks") actually landed.
# If any of these are missing a commit was skipped -- fail fast here instead of
# burning a full kernel compile on a tree that cannot possibly build.
echo "::group::critical backport artifacts"
critical_missing=0
for f in include/linux/lsm_hook_defs.h \
         security/bpf/hooks.c \
         security/bpf/Makefile \
         security/lockdown/lockdown.c \
         security/safesetid/lsm.c; do
  if [ -e "$f" ]; then
    echo "OK      $f"
  else
    echo "::error::critical backport file missing: $f"
    critical_missing=1
  fi
done
if grep -q '^config BPF_LSM' init/Kconfig; then
  echo "OK      init/Kconfig: config BPF_LSM"
else
  echo "::error::init/Kconfig has no 'config BPF_LSM' (LSM-refactor commit skipped?)"
  critical_missing=1
fi
if grep -q 'lsm_hook_defs.h' include/linux/lsm_hooks.h; then
  echo "OK      include/linux/lsm_hooks.h includes lsm_hook_defs.h"
else
  echo "::warning::include/linux/lsm_hooks.h does not include lsm_hook_defs.h"
fi
echo "::endgroup::"
if [ "$critical_missing" != 0 ]; then
  echo "::error::the LSM/BPF-LSM backport did not land -- aborting before compile"
  for s in "${skip_list[@]}"; do echo "::error::SKIPPED $s"; done
  exit 1
fi

echo "HEAD is now: $(git log --oneline -1)"
echo "commits added on top of base: $(git rev-list --count base..HEAD)"
echo "=========== BPF backport done ==========="
