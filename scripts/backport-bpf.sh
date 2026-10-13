#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Backport the 5.10 BPF stack onto the PixelPlusUI guacamole (4.14) tree.
#
# This cherry-picks the exact range given in 4.14_5.10bpf_commits.txt:
#
#   git fetch https://github.com/PhoenixKernel/linux.git android-4.14-phoenix
#   git cherry-pick cc47ca5651d869c037f90cb5276d60f240c00719^..7b031620e7605c2cae5597bdc53f306e030ffd4a
#
# Because PixelPlusUI's tree is not byte-identical to PhoenixKernel's, some
# commits conflict. This script applies them one at a time and, on conflict,
# resolves by taking the incoming (PhoenixKernel) side, which is what a
# backport wants. Commits that cannot be resolved are skipped and reported;
# the build then continues so we can see what is still missing.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="${GITHUB_WORKSPACE:-$PWD}"
KDIR="$ROOT/kernel"
: "${BPF_REPO:?BPF_REPO not set}"
: "${BPF_BRANCH:?BPF_BRANCH not set}"
: "${BPF_START:?BPF_START not set}"
: "${BPF_END:?BPF_END not set}"
BPF_DEPTH="${BPF_DEPTH:-1300}"
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
fetch_range "$BPF_DEPTH"
if ! git rev-parse --verify --quiet "${BPF_START}^" >/dev/null; then
  echo "::warning::depth $BPF_DEPTH did not reach the range base, retrying deeper"
  BPF_DEPTH=$((BPF_DEPTH * 2))
  fetch_range "$BPF_DEPTH"
fi
git rev-parse --verify --quiet "${BPF_END}^{commit}" >/dev/null \
  || { echo "::error::cannot resolve $BPF_END after fetch"; exit 1; }
git rev-parse --verify --quiet "${BPF_START}^" >/dev/null \
  || { echo "::error::cannot resolve ${BPF_START}^ (range base) after fetch"; exit 1; }
echo "fetched $(git rev-list --count "$BPF_START^..$BPF_END") commits in range"
git log --oneline -1 "$BPF_END"
echo "::endgroup::"

# Diagnostic only: merge-base may be unavailable on a shallow fetch.
echo "merge-base(PixelPlusUI HEAD, BPF) = $(git merge-base HEAD "$BPF_END" 2>/dev/null || echo 'unavailable (shallow)')"

# Tag the pristine base so the tree can always be reset/rebuilt from it.
git branch -f ppui-base HEAD

mapfile -t COMMITS < <(git rev-list --reverse "$BPF_START^..$BPF_END")
TOTAL=${#COMMITS[@]}
echo "::notice::cherry-picking $TOTAL commits"

applied=0; resolved=0; skipped=0
declare -a skip_list=()
declare -a conflict_files=()

for c in "${COMMITS[@]}"; do
  subject="$(git log -1 --format=%s "$c")"
  if git cherry-pick -x --allow-empty --keep-redundant-commits "$c" >/tmp/cp.log 2>&1; then
    applied=$((applied+1))
    continue
  fi

  # Conflicted?
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
      resolved=$((resolved+1))
      continue
    fi
  fi

  # Give up on this commit.
  git cherry-pick --abort >/dev/null 2>&1 || true
  skipped=$((skipped+1))
  skip_list+=("$(short_sha=${c:0:12}; echo "$short_sha $subject")")
done

echo "::notice::backport summary: applied=$applied resolved-with-conflicts=$resolved skipped=$skipped"

if [ "$skipped" -gt 0 ]; then
  echo "::warning::$skipped BPF commit(s) could not be applied and were skipped"
  for s in "${skip_list[@]}"; do echo "::warning::SKIPPED $s"; done
fi

{
  echo ""
  echo "## 5.10 BPF backport"
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

echo "HEAD is now: $(git log --oneline -1)"
echo "commits added on top of ppui-base: $(git rev-list --count ppui-base..HEAD)"
echo "=========== BPF backport done ==========="
