# guacamole-kernel-builder

GitHub Actions build for the **OnePlus 7 Pro (guacamole)** kernel, producing a
kernel that is dropped into the ColorOS 15 boot image.

## What this builds

| | |
|---|---|
| Base kernel | [`ArrowOS-Devices/android_kernel_oneplus_sm8150`](https://github.com/ArrowOS-Devices/android_kernel_oneplus_sm8150) branch `arrow-12.1` (Linux 4.14.274) |
| BPF backport | Full **5.10 BPF** stack, cherry-picked from [`PhoenixKernel/linux`](https://github.com/PhoenixKernel/linux) branch `android-4.14-phoenix` |
| Backport range | `cc47ca5651d869c037f90cb5276d60f240c00719^..7b031620e7605c2cae5597bdc53f306e030ffd4a` (1023 commits) |
| Toolchain | Android clang r547379 + `ld.lld` |
| Defconfig | `stock_defconfig` |
| Output | `dist/Image.gz` (raw kernel) + `dist/guacamole-*.zip` (AnyKernel3) |
| Root manager | **none** — no KernelSU, no SUSFS, no Magisk |
| SELinux | permissive by default |

`arrow-12.1` is used because its 4.14.274 base is the closest of the ArrowOS
branches to the `b8f3be29 Linux 4.14.282` tree the PhoenixKernel 5.10-BPF
backport was authored against, so the cherry-pick applies with the fewest
conflicts. `arrow-12.0` is 4.14.264 and `arrow-11.0` is 4.14.246.

### Why Image.gz and no modules

The target boot image (`ColorOS15.0-OnePlus7Pro-250207-beta1/images/boot.img`)
is an Android boot image with header v2:

```
kernel    Image.gz      12,639,079 bytes   @ 4096
ramdisk   (gzip cpio)   23,899,503 bytes   @ 12644352   <- TWRP recovery ramdisk, Magisk-patched
dtb blob  (v2 header)    4,252,351 bytes   @ 36544512   <- 15 concatenated DTBs
cmdline   ... androidboot.selinux=permissive
```

* Its kernel is a plain `Image.gz` (no appended DTB) and the device tree lives
  in the header's separate dtb blob, which must be **kept** (it is the port's
  own DT).
* The ROM carries **no kernel modules anywhere** (no `.ko` in the ramdisk and
  none in the vendor partition), and `arrow-12.1`'s `stock_defconfig` builds
  every driver that matters as built-in. Its only `=m` entries are wil6210
  (60 GHz wifi), DVB/tspp (TV tuners), `USB_GSPCA` (webcams), `MMC_TEST`,
  `MSM_RDBG`, `MSM_11AD`, `LLCC_PERFMON`, `IR_MSM_GENI` and
  `BRIDGE_NETFILTER` — nothing guacamole loads. The kernel is effectively
  monolithic, so `build.sh` only builds `Image.gz` (no modules, no `dtbs`).

## Config changes (`scripts/apply-defconfig.sh`)

```
CONFIG_BPF_LSM=y
CONFIG_BPF_PRELOAD=y
CONFIG_LSM="lockdown,yama,loadpin,safesetid,integrity,selinux,smack,tomoyo,apparmor,bpf"

# SELinux permissive by default
CONFIG_SECURITY_SELINUX_BOOTPARAM=y
CONFIG_SECURITY_SELINUX_BOOTPARAM_VALUE=0
CONFIG_SECURITY_SELINUX_DEVELOP=y
```

plus the SM8150 CPU topology masks (`CONFIG_{LITTLE,BIG,PRIME}_CPU_MASK`) and
`# CONFIG_MODVERSIONS is not set` (the `__crc_*` relocations MODVERSIONS emits
are rejected by `ld.lld` when linking the PIE arm64 `vmlinux`).

## Pipeline (`scripts/`)

1. `setup-toolchain.sh` — installs build deps and the Android clang toolchain.
2. `backport-bpf.sh` — fetches the PhoenixKernel range, cherry-picks the two
   pre-range `pid` rework prerequisites, then the 1023 commits one at a time.
   Conflicts are auto-resolved with `-X theirs` (PhoenixKernel side), with a
   whole-file fallback for unmergeable files; unrecoverable commits are skipped
   and reported (job summary + warnings).
3. `fixups.sh` — re-adds the few helpers the backport uses but this tree lacks
   (`sizeof_field`, `skb_*_gso_size`, `atomic_fetch_add_unless`, ...). Guarded,
   so it is idempotent.
4. `apply-defconfig.sh` — adds the BPF/LSM configs and SELinux permissive
   defaults.
5. `build.sh` — builds, and **verifies** `CONFIG_BPF_LSM=y`,
   `CONFIG_BPF_PRELOAD=y`, `CONFIG_BPF_SYSCALL=y`, `CONFIG_LSM` and that no
   root-manager symbol (`CONFIG_KSU*`/`CONFIG_SUSFS*`) is set.
6. `package.sh` — copies `Image.gz` + `System.map` + `.config` to `dist/`, and
   best-effort wraps the kernel in an AnyKernel3 flashable zip.

## Repacking the boot image

`tools/repack_bootimg.py` (plain Python 3, runs on Windows) replaces only the
kernel section of the boot image and keeps everything else byte-for-byte:

```powershell
# inspect the current image
python tools/repack_bootimg.py --base images\boot.img --info

# put the freshly built kernel into a copy of it
python tools/repack_bootimg.py `
  --base images\boot.img `
  --kernel dist\Image.gz `
  --out   images\boot-new.img
```

It updates `kernel_size` in the header, keeps the ramdisk / second stage /
recovery dtbo / v2 dtb blob untouched, pads the result back to the original
file size (so it still fits the partition), and verifies afterwards that the
ramdisk, second stage and dtb sections are unchanged.

Sanity check: repacking the image with its own kernel reproduces the original
file byte-for-byte.

Flash it with fastboot (`fastboot flash boot boot-new.img`) or by replacing
`images/boot.img` in the ROM package and running `FlashScript.bat`.

No ramdisk change is needed: the kernel is monolithic and the ROM has no
modules to load.

## How to run

- **Actions → Build guacamole kernel (ArrowOS + 5.10 BPF) → Run workflow**
  (optionally change `defconfig`, or set `skip_bpf=1` to test the base tree
  without the backport), or
- push to `main`/`master`.

Each successful run uploads the artifacts and also publishes them to a
`kernel-latest` release, so `Image.gz` always has a stable download URL.

## Legacy

This repository previously built a `PixelPlusUI + 5.10 BPF` kernel (AnyKernel3
only) and, before that, a KernelSU/SUSFS kernel. The KernelSU/SUSFS patches
(`patches/`) and their pipeline (`scripts/apply-patches.sh`) are unused by this
workflow and kept only for reference, as is `legacy/build-yaap-bpfgore.yml`.
This build intentionally contains **no root manager**.
