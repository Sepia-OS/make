# make

This repository builds and provides the `make` package for SepiaOS.

The result is GNU `make` cross-compiled for **aarch64**, linked **dynamically**
against musl, and installed to **`/usr/bin`** on the device. It is the build
driver that goes on the card beside the compiler from
[llvm](https://github.com/Sepia-OS/llvm): together they let the Pi build
software for itself.

The sources are the release tarball from the GNU mirrors, pinned to a version
and checked against a digest recorded in [checksums/](checksums). Upstream's
own two steps are then run in upstream's order: `./configure`, then
`./build.sh` — the script GNU make ships for building itself *in the absence of
any `make` program*.

> The `git://git.savannah.gnu.org/make` repository is upstream's development
> tree, and it is deliberately not what is built here. It ships `configure.ac`
> and `Makefile.am` but no `configure` and no `Makefile.in`, so a checkout
> cannot be configured until `./bootstrap` has fetched gnulib and regenerated
> them — which would put autoconf, automake, autopoint and gettext on every
> development machine and in CI for no gain. The release tarball ships a
> working `configure` and is what upstream signs.

The build is compiled with the same musl-targeting cross-toolchain that
[llvm](https://github.com/Sepia-OS/llvm) uses, against the same musl version
that [rootfs](https://github.com/Sepia-OS/rootfs) ships. Nothing needs root,
and nothing is written outside `build/`.

## Prerequisites

`gmake` (GNU Make ≥ 4.0), `curl`, `tar` and `xz`.

```sh
brew install make xz          # macOS
sudo apt install make curl xz-utils   # Debian / Ubuntu
```

> **On macOS, run `gmake`, not `make`.** `/usr/bin/make` is GNU Make 3.81,
> which compares file timestamps only to the whole second and will silently
> reuse a stale object after a fast edit. The Makefile refuses to run on it.

The cross-toolchain is downloaded automatically — messense on macOS, bootlin
on Linux, because no single vendor publishes a musl-targeting aarch64
toolchain for both hosts. Point `CROSS_COMPILE` at one you already have to skip
the download.

## Quick start

```sh
gmake toolchain-check    # prove the compiler builds C against musl
gmake make               # cross-build it
gmake stage-check        # prove the result is aarch64 and needs only musl
gmake dist               # pack it as a release asset
```

Run `gmake help` for the full list.

## Targets

| Target | What it does |
|---|---|
| `help` | targets and variables (the default goal) |
| `toolchain` | fetch and verify the musl-targeting cross-compiler |
| `toolchain-check` | compile and link C against musl, dynamically and statically |
| `sysroot` | build musl into `build/sysroot`, plus the Linux UAPI headers |
| `sysroot-check` | prove C links dynamically against that sysroot |
| `sources` | fetch, verify and unpack the GNU make release tarball |
| `verify-downloads` | check the sources against the recorded digest |
| `make` | `./configure` and `./build.sh` — the cross-build |
| `stage` | install the binary into a staged `/usr` tree |
| `stage-check` | assert aarch64, the musl loader, and a dependency on nothing but musl |
| `dist` | pack the staged tree into `dist/` with `SHA256SUMS` |
| `*-info` | what version, from where, how big |
| `clean` / `distclean` | drop `build/` / also drop `downloads/` and `dist/` |

## Variables

| Variable | Default | Meaning |
|---|---|---|
| `GNU_MAKE_VERSION` | `4.4.1` | upstream release to build |
| `MUSL_VERSION` | `1.2.6` | target musl — must match what `rootfs` ships |
| `PREFIX` | `/usr` | where the binary lands on the device |
| `CONFIGURE_FLAGS` | see `gmake help` | passed to upstream's `configure` |
| `CROSS_COMPILE` | *(empty)* | use a musl cross-toolchain you already have |
| `WITH_STRIP` | `1` | strip the staged binary |
| `DIST_TAG` | *(empty)* | release tag to name the asset after |
| `JOBS` | host CPUs | parallelism for the musl build |

It is **not** called `MAKE_VERSION`: that name is a GNU make built-in holding
the version of the `make` reading the Makefile, and the ≥ 4.0 check depends on
it.

## What ships

```
usr/bin/make                          the binary, stripped
usr/share/licenses/make/COPYING       make is GPLv3 and this ships a binary of it
```

musl is deliberately **not** in the asset: the device's libc comes from
`rootfs`, and a second copy on the card is two libcs disagreeing. `stage-check`
asserts it.

A local build produces `dist/sepiaos-make-<version>-aarch64-musl.tar.xz`
(112 KB for 4.4.1) and its `SHA256SUMS`, which is what `rootfs` is expected to
unpack into the root filesystem — siblings consume each other's published
releases, never each other's build trees.
