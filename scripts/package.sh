#!/usr/bin/env bash
set -euo pipefail

: "${TARGET:?TARGET is not set}"
ROOT="${GITHUB_WORKSPACE:-$PWD}"
BOOT="$ROOT/kernel/arch/arm64/boot"
DIST="$ROOT/dist"
AK="$ROOT/anykernel"

mkdir -p "$DIST"
rm -rf "$AK"
git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git "$AK"
rm -rf "$AK/.git"

if [ -f "$BOOT/Image.gz-dtb" ]; then
  cp "$BOOT/Image.gz-dtb" "$AK/Image.gz-dtb"
elif [ -f "$BOOT/Image.gz" ]; then
  cp "$BOOT/Image.gz" "$AK/Image.gz"
  find "$BOOT/dts" -name '*.dtb' -exec cat {} + > "$AK/dtb" 2>/dev/null || true
elif [ -f "$BOOT/Image" ]; then
  gzip -9 -c "$BOOT/Image" > "$AK/Image.gz"
  find "$BOOT/dts" -name '*.dtb' -exec cat {} + > "$AK/dtb" 2>/dev/null || true
else
  echo "::error::No kernel image found under $BOOT"
  ls -l "$BOOT" || true
  exit 1
fi

if [ -f "$AK/anykernel.sh" ]; then
  sed -i -E 's|^kernel\.string=.*|kernel.string=SukiSU-Ultra guacamole|' "$AK/anykernel.sh"
  sed -i -E 's|^do\.modules=.*|do.modules=0|' "$AK/anykernel.sh"
  sed -i -E 's|^device\.name1=.*|device.name1=OnePlus7Pro|' "$AK/anykernel.sh"
  sed -i -E 's|^device\.name2=.*|device.name2=guacamole|' "$AK/anykernel.sh"
  for n in 3 4 5; do sed -i -E "s|^device\.name${n}=.*|device.name${n}=|" "$AK/anykernel.sh"; done
  sed -i -E 's|^BLOCK=.*|BLOCK=boot;|' "$AK/anykernel.sh"
fi

STAMP="$(date +%Y%m%d-%H%M)"
ZIP="SukiSU-Ultra-${TARGET}-${STAMP}.zip"
( cd "$AK" && zip -r9 "$DIST/$ZIP" . -x '*.git*' >/dev/null )

echo "Built: $DIST/$ZIP"
ls -l "$DIST"
