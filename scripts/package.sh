#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Collect the artifacts produced by build.sh into dist/.
#
# Primary artifact:  dist/Image.gz      <- raw kernel for the boot.img repacker
# Secondary:         dist/*.zip         <- AnyKernel3 flashable zip (TWRP)
# Plus:              dist/System.map, dist/.config, dist/kernel-rev.txt
#
# The AnyKernel3 step is best-effort: a failure there must not lose the kernel
# image that the boot-image tooling needs.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="${GITHUB_WORKSPACE:-$PWD}"
BOOT="$ROOT/kernel/arch/arm64/boot"
DIST="$ROOT/dist"
AK="$ROOT/anykernel"

mkdir -p "$DIST"
rm -rf "$AK"

# --- raw kernel image -----------------------------------------------------
if [ -f "$BOOT/Image.gz" ]; then
  cp -f "$BOOT/Image.gz" "$DIST/Image.gz"
elif [ -f "$BOOT/Image.gz-dtb" ]; then
  # Fall back to the -dtb image (same gzip stream, DTB appended after it).
  # The boot header's own DTB is kept by the repacker, so this is only a
  # last-resort path.
  cp -f "$BOOT/Image.gz-dtb" "$DIST/Image.gz"
else
  echo "::error::no Image.gz under $BOOT"
  ls -l "$BOOT" || true
  exit 1
fi
gzip -t "$DIST/Image.gz" || { echo "::error::dist/Image.gz is not valid gzip"; exit 1; }
echo "kernel image : $DIST/Image.gz ($(stat -c %s "$DIST/Image.gz") bytes)"

# --- reference files ------------------------------------------------------
[ -f "$ROOT/kernel/System.map" ] && cp -f "$ROOT/kernel/System.map" "$DIST/System.map"
[ -f "$ROOT/kernel/.config" ]    && cp -f "$ROOT/kernel/.config"    "$DIST/.config"
cp -f "$ROOT/kernel-rev.txt" "$DIST/kernel-rev.txt" 2>/dev/null || echo unknown > "$DIST/kernel-rev.txt"

REV="$(cut -c1-10 "$DIST/kernel-rev.txt" 2>/dev/null || echo unknown)"
STAMP="$(date +%Y%m%d-%H%M)"

# --- best-effort flashable zip (TWRP / AnyKernel3) -------------------------
if git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git "$AK" >/dev/null 2>&1; then
  rm -rf "$AK/.git"
  if [ -f "$BOOT/Image.gz-dtb" ]; then
    cp -f "$BOOT/Image.gz-dtb" "$AK/Image.gz-dtb"
  else
    cp -f "$DIST/Image.gz" "$AK/Image.gz"
  fi
  if [ -f "$AK/anykernel.sh" ]; then
    sed -i -E 's|^kernel\.string=.*|kernel.string=guacamole 4.14 (ArrowOS) + 5.10 BPF backport|' "$AK/anykernel.sh"
    sed -i -E 's|^do\.modules=.*|do.modules=0|' "$AK/anykernel.sh"
    sed -i -E 's|^device\.name1=.*|device.name1=OnePlus7Pro|' "$AK/anykernel.sh"
    sed -i -E 's|^device\.name2=.*|device.name2=guacamole|' "$AK/anykernel.sh"
    for n in 3 4 5; do sed -i -E "s|^device\.name${n}=.*|device.name${n}=|" "$AK/anykernel.sh"; done
    sed -i -E 's|^BLOCK=.*|BLOCK=boot;|' "$AK/anykernel.sh"
  fi
  ZIP="guacamole-arrow12.1-bpf5.10-${STAMP}-${REV}.zip"
  if ( cd "$AK" && zip -r9 "$DIST/$ZIP" . -x '*.git*' >/dev/null ); then
    echo "flashable zip: $DIST/$ZIP"
  else
    echo "::warning::failed to build the AnyKernel3 zip (ignored)"
  fi
else
  echo "::warning::could not clone AnyKernel3 (ignored)"
fi

echo "::group::dist"
ls -l "$DIST" || true
echo "::endgroup::"
