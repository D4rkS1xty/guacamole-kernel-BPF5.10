#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# Drop a freshly built kernel (arch/arm64/boot/Image.gz) into an Android boot
# image, keeping everything else byte-for-byte: the ramdisk (this ROM's is a
# TWRP recovery ramdisk patched by Magisk), the second stage, the recovery
# dtbo and -- importantly -- the separate v2-header device-tree blob (15
# concatenated DTBs) that the ColorOS15 port relies on.
#
# Only the "kernel" section and the header's kernel_size change.
#
# Supported: boot image header v0, v1 and v2 (this ROM is v2).
#
# Examples
#   python tools/repack_bootimg.py --info images/boot.img
#   python tools/repack_bootimg.py --base images/boot.img --kernel dist/Image.gz \
#          --out images/boot-new.img
# ---------------------------------------------------------------------------
import argparse
import gzip
import hashlib
import re
import struct
import sys
from pathlib import Path

MAGIC = b'ANDROID!'


def u32(buf, off):
    return struct.unpack_from('<I', buf, off)[0]


def u64(buf, off):
    return struct.unpack_from('<Q', buf, off)[0]


def pages(n, page):
    return (n + page - 1) // page


def pad_to(data, page):
    r = len(data) % page
    return data + b'\x00' * (page - r) if r else data


class BootImage:
    def __init__(self, path, raw):
        if raw[:8] != MAGIC:
            raise ValueError(f"{path}: not an Android boot image (magic {raw[:8]!r})")
        self.path = Path(path)
        self.raw = raw
        self.kernel_size = u32(raw, 8)
        self.kernel_addr = u32(raw, 12)
        self.ramdisk_size = u32(raw, 16)
        self.ramdisk_addr = u32(raw, 20)
        self.second_size = u32(raw, 24)
        self.second_addr = u32(raw, 28)
        self.tags_addr = u32(raw, 32)
        self.page_size = u32(raw, 36)
        self.header_version = u32(raw, 40)
        self.os_version = u32(raw, 44)
        self.name = raw[48:64].rstrip(b'\x00')
        self.cmdline = raw[64:576].split(b'\x00')[0]
        self.id = raw[576:608]
        self.extra_cmdline = raw[608:1632].split(b'\x00')[0]
        self.recovery_dtbo_size = 0
        self.recovery_dtbo_offset = 0
        self.header_size = 1632
        self.dtb_size = 0
        self.dtb_addr = 0
        if self.header_version >= 1:
            self.recovery_dtbo_size = u32(raw, 1632)
            self.recovery_dtbo_offset = u64(raw, 1636)
            self.header_size = u32(raw, 1644)
        if self.header_version >= 2:
            self.dtb_size = u32(raw, 1648)
            self.dtb_addr = u64(raw, 1652)

    # -- section offsets ---------------------------------------------------
    @property
    def off_kernel(self):
        return self.page_size

    @property
    def off_ramdisk(self):
        return self.off_kernel + pages(self.kernel_size, self.page_size) * self.page_size

    @property
    def off_second(self):
        return self.off_ramdisk + pages(self.ramdisk_size, self.page_size) * self.page_size

    @property
    def off_recovery_dtbo(self):
        return self.off_second + pages(self.second_size, self.page_size) * self.page_size

    @property
    def off_dtb(self):
        return self.off_recovery_dtbo + pages(self.recovery_dtbo_size, self.page_size) * self.page_size

    @property
    def content_end(self):
        return self.off_dtb + self.dtb_size

    def section(self, off, size):
        return self.raw[off:off + size]

    def info(self):
        print(f"file           : {self.path}")
        print(f"size           : {len(self.raw)} bytes")
        print(f"header version : {self.header_version} (header_size {self.header_size})")
        print(f"page size      : {self.page_size}")
        print(f"kernel         : off {self.off_kernel} size {self.kernel_size} addr 0x{self.kernel_addr:x}")
        print(f"ramdisk        : off {self.off_ramdisk} size {self.ramdisk_size} addr 0x{self.ramdisk_addr:x}")
        print(f"second         : off {self.off_second} size {self.second_size}")
        print(f"recovery dtbo  : off {self.off_recovery_dtbo} size {self.recovery_dtbo_size}")
        print(f"dtb (v2)       : off {self.off_dtb} size {self.dtb_size} addr 0x{self.dtb_addr:x}")
        print(f"content end    : {self.content_end}")
        print(f"cmdline        : {self.cmdline.decode(errors='replace')}")
        if self.dtb_size:
            blob = self.section(self.off_dtb, self.dtb_size)
            n = len(re.findall(b'\xd0\x0d\xfe\xed', blob))
            print(f"dtb blob       : {n} concatenated FDTs")
        print(f"kernel version : {kernel_version(self.section(self.off_kernel, self.kernel_size))}")
        print(f"ramdisk sha256 : {hashlib.sha256(self.section(self.off_ramdisk, self.ramdisk_size)).hexdigest()[:32]}")


def kernel_version(blob):
    """Return the 'Linux version ...' banner of a (possibly gzipped) kernel."""
    data = blob
    if blob[:2] == b'\x1f\x8b':
        try:
            data = gzip.decompress(blob)
        except Exception as e:  # noqa: BLE001
            return f"<gzip error: {e}>"
    m = re.search(rb'Linux version [^\x00]{1,200}', data)
    if not m:
        return "<not found>"
    return m.group(0).decode(errors='replace')


def repack(base: BootImage, kernel_blob: bytes, out_path: Path,
           dtb_blob=None, pad_to_size=True, dtb_addr=None) -> None:
    if kernel_blob[:2] != b'\x1f\x8b' and kernel_blob[:4] != b'\x00' * 4:
        print(f"warning: new kernel does not look like gzip (first bytes {kernel_blob[:4].hex()})",
              file=sys.stderr)

    raw = bytearray(base.raw[:base.header_size])
    struct.pack_into('<I', raw, 8, len(kernel_blob))
    if dtb_blob is not None:
        struct.pack_into('<I', raw, 1648, len(dtb_blob))
        if dtb_addr is not None:
            struct.pack_into('<Q', raw, 1652, dtb_addr)
    header = pad_to(bytes(raw), base.page_size)

    dtb = dtb_blob if dtb_blob is not None else base.section(base.off_dtb, base.dtb_size)

    out = bytearray()
    out += header
    out += pad_to(kernel_blob, base.page_size)
    out += pad_to(base.section(base.off_ramdisk, base.ramdisk_size), base.page_size)
    if base.second_size:
        out += pad_to(base.section(base.off_second, base.second_size), base.page_size)
    if base.recovery_dtbo_size:
        out += pad_to(base.section(base.off_recovery_dtbo, base.recovery_dtbo_size), base.page_size)
    if dtb:
        out += pad_to(dtb, base.page_size)

    target = len(base.raw) if pad_to_size else len(out)
    if target < len(out):
        raise SystemExit(f"refusing to shrink the image: content {len(out)} > target {target}")
    out += b'\x00' * (target - len(out))

    out_path.write_bytes(bytes(out))
    print(f"wrote {out_path} ({len(out)} bytes)")


def main():
    ap = argparse.ArgumentParser(description="Repack an Android boot image with a new kernel")
    ap.add_argument('--base', required=True, help='boot.img to modify')
    ap.add_argument('--kernel', help='new kernel (Image.gz) to insert')
    ap.add_argument('--dtb', help='optional replacement DTB blob (default: keep the base one)')
    ap.add_argument('--out', help='output path (default: <base>.new.img)')
    ap.add_argument('--info', action='store_true', help='just print the layout and exit')
    ap.add_argument('--no-pad', action='store_true',
                    help='do not pad the output to the original file size')
    args = ap.parse_args()

    base = BootImage(args.base, Path(args.base).read_bytes())
    base.info()
    if args.info:
        return

    if not args.kernel:
        ap.error('--kernel is required unless --info is used')

    kernel = Path(args.kernel).read_bytes()
    dtb = Path(args.dtb).read_bytes() if args.dtb else None
    out = Path(args.out) if args.out else Path(args.base).with_suffix('.new.img')

    print(f"new kernel version: {kernel_version(kernel)}")
    repack(base, kernel, out, dtb_blob=dtb, pad_to_size=not args.no_pad)

    new = BootImage(out, out.read_bytes())
    print("--- result ---")
    new.info()

    # sanity: everything except the kernel must be untouched
    if new.raw[:base.header_size] != base.raw[:base.header_size]:
        diffs = [i for i in range(base.header_size) if new.raw[i] != base.raw[i]]
        print(f"header changed at offsets: {diffs}")
    for nm, a, b in (("ramdisk", base.section(base.off_ramdisk, base.ramdisk_size),
                      new.section(new.off_ramdisk, new.ramdisk_size)),
                     ("second", base.section(base.off_second, base.second_size),
                      new.section(new.off_second, new.second_size)),
                     ("dtb", base.section(base.off_dtb, base.dtb_size),
                      new.section(new.off_dtb, new.dtb_size))):
        if a != b:
            raise SystemExit(f"ERROR: {nm} section changed!")
    print("OK: ramdisk / second / dtb preserved exactly; only kernel_size + kernel changed")


if __name__ == '__main__':
    main()
