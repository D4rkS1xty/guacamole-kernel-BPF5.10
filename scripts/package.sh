#!/usr/bin/env bash
set -euo pipefail

: "${TARGET:?TARGET is not set}"
ROOT="${GITHUB_WORKSPACE:-$PWD}"
OUT="$ROOT/out"
IMG="$OUT/arch/arm64/boot/Image.gz"
IMGDTB="$OUT/arch/arm64/boot/Image.gz-dtb"
DIST="$ROOT/dist"
AK="$ROOT/anykernel"

mkdir -p "$DIST"
rm -rf "$AK"
git clone --depth=1 https://github.com/KernelSU-Next/AnyKernel3.git "$AK"
rm -rf "$AK/.git"

if [ -f "$IMGDTB" ]; then
  cp "$IMGDTB" "$AK/Image.gz-dtb"
elif [ -f "$IMG" ]; then
  cp "$IMG" "$AK/Image.gz"
  find "$OUT/arch/arm64/boot/dts" -name '*.dtb' -exec cat {} + > "$AK/dtb"
else
  echo "No kernel image found (looked for Image.gz-dtb and Image.gz)"
  exit 1
fi

STAMP="$(date +%Y%m%d-%H%M)"
ZIP="KernelSU-Next-${TARGET}-${STAMP}.zip"
( cd "$AK" && zip -r9 "$DIST/$ZIP" . -x '*.git*' >/dev/null )

echo "Built: $DIST/$ZIP"
ls -l "$DIST"
