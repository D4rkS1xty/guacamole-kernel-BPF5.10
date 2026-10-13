# guacamole-kernel-builder

GitHub Actions build for the **OnePlus 7 Pro (guacamole)** kernel.

## What this builds

| | |
|---|---|
| Base kernel | [`PixelPlusUI-Devices/kernel_oneplus_guacamole`](https://github.com/PixelPlusUI-Devices/kernel_oneplus_guacamole) branch `tiramisu` (Linux 4.14.282) |
| BPF backport | Full **5.10 BPF** stack, cherry-picked from [`PhoenixKernel/linux`](https://github.com/PhoenixKernel/linux) branch `android-4.14-phoenix` |
| Backport range | `cc47ca5651d869c037f90cb5276d60f240c00719^..7b031620e7605c2cae5597bdc53f306e030ffd4a` (1023 commits) |
| Toolchain | Android clang r547379 + `ld.lld` |
| Output | `dist/guacamole-bpf5.10-<date>.zip` — flashable from TWRP (AnyKernel3) |

Both trees share the upstream base **`b8f3be29 Linux 4.14.282`**, which is why the
backport mostly applies.

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

> Note: the requested string used `apparmour`; the correct LSM name is `apparmor`.
> Unknown entries in `CONFIG_LSM` are ignored at boot, but the correct spelling is used here.

## Pipeline (`scripts/`)

1. `setup-toolchain.sh` — installs build deps and the Android clang toolchain.
2. `backport-bpf.sh` — fetches the PhoenixKernel range and cherry-picks it one
   commit at a time. Conflicts are auto-resolved by taking the PhoenixKernel
   side; unrecoverable commits are skipped and reported (job summary + warnings).
3. `apply-defconfig.sh` — adds the BPF/LSM configs and SELinux permissive defaults.
4. `build.sh` — builds, and **verifies** `CONFIG_BPF_LSM=y`, `CONFIG_BPF_PRELOAD=y`,
   `CONFIG_BPF_SYSCALL=y` and `CONFIG_LSM` survived `olddefconfig`.
5. `package.sh` — wraps `arch/arm64/boot/Image*` into an AnyKernel3 zip
   (`device.name1=OnePlus7Pro`, `device.name2=guacamole`, `BLOCK=boot`).

## How to run

- Push to `main`/`master`, or
- **Actions → Build guacamole kernel → Run workflow** (optionally change `defconfig`
  or set `skip_bpf=1` to test the base tree without the backport).

The resulting TWRP zip is attached to the workflow run as the
`guacamole-ppui-bpf5.10` artifact.

## Root

This build is intentionally a **plain kernel** (no KernelSU/SUSFS). The previous
KernelSU+SUSFS pipeline against `yaap/kernel_oneplus_sm8150@sixteen-bpfgore` is
preserved in `legacy/build-yaap-bpfgore.yml` and `patches/`.
