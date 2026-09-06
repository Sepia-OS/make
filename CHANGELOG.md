# Changelog

All notable changes to this repository are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases are named after the **upstream GNU make version** they package, not
after a version of this repository: `v4.4.1` is GNU make 4.4.1, cross-built to
run on the Raspberry Pi.

## [Unreleased]

## [4.4.1] - 2026-09-04

### Added

- The whole build: fetch the GNU make release tarball, verify it against the
  digest committed in `checksums/`, build a musl sysroot, cross-build `make`
  for `aarch64-unknown-linux-musl` and pack it as a release asset.
- Upstream's own two steps in upstream's order — `./configure`, then
  `build.sh`, the script GNU make ships for building itself in the absence of
  any `make`.
- `stage-check`, which asserts the staged binary is aarch64, uses the musl
  loader, and depends on `libc.so` and nothing else.
- CI on every commit and branch, and a manual release workflow gated on a green
  CI run.
- Apache-2.0 licence and a `.gitignore` that deliberately omits the stock C
  section, whose `*.d` pattern also matches directories.

### Notes

- The upstream version is `GNU_MAKE_VERSION`, not `MAKE_VERSION`: the latter is
  a GNU make built-in holding the version of the make reading the file, which
  the ≥ 4.0 prerequisite check depends on.
- `-std=gnu17` is load-bearing and the failure is cross-build-only: GCC 15
  defaults to C23, where make 4.4.1's bundled gnulib `fnmatch.c` fails to
  compile — and only when cross-compiling, because `configure` cannot run its
  probe against the target.

[Unreleased]: https://github.com/Sepia-OS/make/compare/v4.4.1...HEAD
[4.4.1]: https://github.com/Sepia-OS/make/releases/tag/v4.4.1
