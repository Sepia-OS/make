# SepiaOS - GNU make for the target
#
# Downloads the GNU make sources and cross-builds the `make` binary to run
# *on* the Pi, linked dynamically against musl, for installation into the
# SepiaOS root filesystem. It is the build driver that goes on the card beside
# the compiler from ../llvm.
#
#   make toolchain-check    prove the cross-compiler builds C against musl
#   make make               cross-build it
#   make stage-check        prove the result is aarch64 and needs only musl
#   make help               every target
#
# No root, no containers: everything is a download plus a cross-build, so the
# same recipes work on macOS and Linux.

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

# Make 3.81 (still /usr/bin/make on macOS) compares timestamps only to the
# second and silently reuses stale outputs after a fast edit.
ifeq ($(filter 4.% 5.%,$(MAKE_VERSION)),)
$(error GNU Make >= 4.0 required, found $(MAKE_VERSION). On macOS: brew install make, then run gmake)
endif

SHELL       := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
.DELETE_ON_ERROR:

# --retry-all-errors is load-bearing rather than decoration: ../llvm measured
# four consecutive single-shot fetches of the musl tarball failing from
# debian:trixie-slim, two with a TLS handshake error, which plain --retry does
# not class as transient and therefore will not retry.
CURL   := curl --fail --silent --show-error --location \
                --retry 5 --retry-delay 2 --retry-connrefused --retry-all-errors
SHA256 := $(shell command -v sha256sum >/dev/null 2>&1 && echo "sha256sum" || echo "shasum -a 256")

DL_DIR    := downloads
BUILD_DIR := build
DIST_DIR  := dist
CHECKSUMS := checksums

HOST_OS   := $(shell uname -s)
HOST_ARCH := $(shell uname -m)

JOBS ?= $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)

# Homebrew sets CPPFLAGS and LDFLAGS in the developer's shell on macOS, and
# both configure and build.sh read them straight onto *cross* compile lines.
# ../llvm found -I/opt/homebrew/opt/include and -L/opt/homebrew/opt/lib in a
# real target link: nothing broke, because nothing was found there, but a host
# header or library that *was* found would have gone into a target binary
# silently. Scrubbed rather than trusted.
SCRUB_ENV := env -u CPPFLAGS -u LDFLAGS -u CFLAGS -u CXXFLAGS \
                 -u LIBRARY_PATH -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH

# Overriding a variable on the command line changes what gets built but touches
# no file, so Make cannot see it: without this, `gmake GNU_MAKE_VERSION=4.3
# make` would report "Nothing to be done" and hand back the 4.4.1 binary. Each
# expensive tree therefore carries a signature of the settings that determine
# its contents, rewritten only when it actually changes so that it works as an
# ordinary prerequisite. Same idiom as ../boot's CONFIG_SIG.
.PHONY: FORCE
FORCE:

# $(1) stamp path, $(2) signature
define config_stamp_rule
$(1): FORCE
	@mkdir -p $$(@D)
	@printf '%s\n' '$(2)' | cmp -s - $$@ || printf '%s\n' '$(2)' > $$@
endef

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# The upstream release to build. Newer: https://ftp.gnu.org/gnu/make/
#
# NOTE the name. This is deliberately *not* MAKE_VERSION: that is a GNU make
# built-in holding the version of the make reading this file, which the
# prerequisite check above tests. Overriding it on the command line would
# defeat that check rather than select a release.
GNU_MAKE_VERSION ?= 4.4.1

# Where the binary lands on the device, per README.md: the installation target
# is /usr/bin. Nothing is ever written outside build/ - the tree is staged
# under DESTDIR and packed, and rootfs unpacks it.
PREFIX ?= /usr

# The triple the product is built for, fixed rather than taken from whichever
# compiler built it. ../llvm pins the same one for the same reason: the two
# toolchain vendors disagree about their own name (messense says
# aarch64-unknown-linux-musl, bootlin says aarch64-buildroot-linux-musl).
TARGET_TRIPLE := aarch64-unknown-linux-musl

# --without-guile is load-bearing on a developer's macOS box: guile is
# auto-detected through pkg-config, which would find the *host's* Homebrew
# guile and configure a target binary against it. --disable-nls keeps gettext
# out of a userland that is musl and busybox and has no locale data.
CONFIGURE_FLAGS ?= --host=$(TARGET_TRIPLE) --prefix=$(PREFIX) \
                   --disable-nls --without-guile

# ---------------------------------------------------------------------------
# Cross-toolchain
#
# The musl-*targeting* toolchain, which is the whole point: this binary has to
# link against the libc that is actually on the card. ../rootfs deliberately
# takes the *gnu* variant of the same release, because it builds musl from
# source and a baked-in musl would make that step a no-op - do not follow it
# here.
#
# Two vendors, because no single one publishes a musl-targeting aarch64
# toolchain for both hosts: messense publishes darwin-hosted builds only,
# bootlin (Buildroot) publishes Linux-hosted x86_64 builds only. So macOS is
# the development host and Linux is the release host, matching ../rootfs and
# ../llvm. TARGET_TRIPLE above is what keeps the product identical either way.
# ---------------------------------------------------------------------------

ifeq ($(HOST_OS),Darwin)
  TC_VENDOR      := messense
  TC_VERSION_DEF := 15.2.0
  TC_PREFIX      := aarch64-unknown-linux-musl-
  ifeq ($(HOST_ARCH),arm64)
    TC_HOST := aarch64-darwin
  else ifeq ($(HOST_ARCH),x86_64)
    TC_HOST := x86_64-darwin
  endif
  TC_ARCHIVE  = aarch64-unknown-linux-musl-$(TC_HOST).tar.gz
  TC_BASE    := https://github.com/messense/homebrew-macos-cross-toolchains/releases/download
  TC_URL      = $(TC_BASE)/v$(TC_VERSION)/$(TC_ARCHIVE)
  TC_SUMS     = $(TC_ARCHIVE).sha256
  TC_SUMS_URL = $(TC_URL).sha256
else ifeq ($(HOST_OS),Linux)
  TC_VENDOR      := bootlin
  TC_VERSION_DEF := 2025.08-1
  # bootlin names its tools aarch64-linux-*, not after the full triple.
  TC_PREFIX      := aarch64-linux-
  ifeq ($(HOST_ARCH),x86_64)
    TC_HOST := x86_64
  endif
  TC_ARCHIVE  = aarch64--musl--stable-$(TC_VERSION).tar.xz
  TC_BASE    := https://toolchains.bootlin.com/downloads/releases/toolchains/aarch64/tarballs
  TC_URL      = $(TC_BASE)/$(TC_ARCHIVE)
  TC_SUMS     = aarch64--musl--stable-$(TC_VERSION).sha256
  TC_SUMS_URL = $(TC_BASE)/$(TC_SUMS)
endif

TC_VERSION ?= $(TC_VERSION_DEF)

# Point this at a musl cross-toolchain you already have and nothing is
# downloaded - the escape hatch for a host neither vendor covers, and the way
# to build against a sibling's already-extracted toolchain.
CROSS_COMPILE ?=

DL_TC     := $(DL_DIR)/toolchain
TC_DIR     = $(DL_TC)/$(TC_VENDOR)-$(TC_VERSION)-$(TC_HOST)
TC_STAMP   = $(TC_DIR)/.extracted
CROSS      = $(or $(CROSS_COMPILE),$(abspath $(TC_DIR))/bin/$(TC_PREFIX))
TOOLCHAIN_DEP = $(if $(CROSS_COMPILE),,$(TC_STAMP))

TC_GOALS := toolchain toolchain-info toolchain-check sysroot sysroot-info \
            sysroot-check make build-info stage stage-check dist
ifneq ($(filter $(TC_GOALS),$(MAKECMDGOALS)),)
  ifeq ($(CROSS_COMPILE),)
    ifeq ($(TC_HOST),)
      $(error No prebuilt musl-targeting aarch64 toolchain is published for $(HOST_OS)/$(HOST_ARCH) (macOS: messense, Linux/x86_64: bootlin). Set CROSS_COMPILE to one you have)
    endif
  endif
endif

# ---------------------------------------------------------------------------
# Step 1 - the cross-toolchain
# ---------------------------------------------------------------------------

.PHONY: toolchain
toolchain: $(TOOLCHAIN_DEP) ## Fetch the musl-targeting aarch64 cross-compiler
	@$(call assert_cross_compiler)
	@echo "  READY    $(if $(CROSS_COMPILE),CROSS_COMPILE -> $(CROSS)gcc,$(TC_VENDOR) $(TC_VERSION) -> $(TC_DIR))"

# Nothing under $(TC_DIR) is a prerequisite: release archives are immutable, so
# once a version is unpacked it is never unpacked again. Change TC_VERSION and
# the path changes with it.
$(TC_STAMP):
	@command -v tar >/dev/null 2>&1 || { echo "tar is required" >&2; exit 1; }
	@mkdir -p $(DL_TC)
	@if [ ! -f $(DL_TC)/$(TC_ARCHIVE) ]; then \
	   echo "  FETCH    $(TC_ARCHIVE) (78 MiB bootlin, 132 MiB messense)"; \
	   $(CURL) -o $(DL_TC)/$(TC_ARCHIVE).part "$(TC_URL)"; \
	   mv -f $(DL_TC)/$(TC_ARCHIVE).part $(DL_TC)/$(TC_ARCHIVE); \
	 fi
	@if [ ! -f $(DL_TC)/$(TC_SUMS) ]; then \
	   $(CURL) -o $(DL_TC)/$(TC_SUMS).part "$(TC_SUMS_URL)"; \
	   mv -f $(DL_TC)/$(TC_SUMS).part $(DL_TC)/$(TC_SUMS); \
	 fi
	@echo "  VERIFY   $(TC_ARCHIVE)"
	@( cd $(DL_TC) && $(SHA256) --check --quiet $(TC_SUMS) ) || { \
	   echo "  FAIL     $(TC_ARCHIVE) does not match upstream's digest; delete $(DL_TC) and retry" >&2; \
	   exit 1; }
	@echo "  UNPACK   $(TC_ARCHIVE) -> $(TC_DIR)"
	@rm -rf $(TC_DIR)
	@mkdir -p $(TC_DIR)
	@tar -xf $(DL_TC)/$(TC_ARCHIVE) -C $(TC_DIR) --strip-components=1
	@touch $@
	@$(call assert_cross_compiler)

# A cross-compiler for the wrong host arch extracts happily and then fails to
# exec; one for the wrong target compiles happily and produces the wrong
# binaries. -dumpmachine catches both in one cheap call - and here it must say
# musl, because a gnu toolchain would link this binary against glibc.
define assert_cross_compiler
	command -v $(CROSS)gcc >/dev/null 2>&1 || { \
	  echo "  FAIL     no $(CROSS)gcc" >&2; exit 1; }; \
	m=$$($(CROSS)gcc -dumpmachine) || { \
	  echo "  FAIL     $(CROSS)gcc will not run on $(HOST_OS)/$(HOST_ARCH)" >&2; exit 1; }; \
	case "$$m" in \
	  aarch64-*linux-musl*) ;; \
	  aarch64-*linux*) echo "  FAIL     $(CROSS)gcc targets $$m - that is a gnu toolchain, so it would link make against glibc" >&2; exit 1;; \
	  *) echo "  FAIL     $(CROSS)gcc targets $$m, not aarch64 linux musl" >&2; exit 1;; \
	esac
endef

.PHONY: toolchain-info
toolchain-info: $(TOOLCHAIN_DEP) ## Show the cross-compiler in use
	@echo "  host     $(HOST_OS) $(HOST_ARCH)"
	@echo "  source   $(if $(CROSS_COMPILE),CROSS_COMPILE override,$(TC_VENDOR) $(TC_VERSION))"
	@echo "  prefix   $(CROSS)"
	@echo "  target   $$($(CROSS)gcc -dumpmachine)"
	@$(CROSS)gcc --version | sed -n '1s/^/  gcc      /p'
	@$(CROSS)ld --version | sed -n '1s/^/  ld       /p'
	@echo "  sysroot  $$($(CROSS)gcc -print-sysroot)"

TC_CHECK_DIR := $(BUILD_DIR)/toolchain-check

# GNU make is C, so unlike ../llvm this only has to prove C - but it proves it
# dynamically *and* statically, because a toolchain that can only do one of
# them fails much later, in the middle of a build.
.PHONY: toolchain-check
toolchain-check: $(TOOLCHAIN_DEP) ## Prove the cross-compiler builds C against musl
	@$(call assert_cross_compiler)
	@mkdir -p $(TC_CHECK_DIR)
	@printf '%s\n' \
	  '#include <stdio.h>' \
	  '#include <stdlib.h>' \
	  'int main(void) { printf("sepiaos\n"); return EXIT_SUCCESS; }' \
	  > $(TC_CHECK_DIR)/t.c
	@$(CROSS)gcc -O2 -o $(TC_CHECK_DIR)/t.dyn $(TC_CHECK_DIR)/t.c \
	  || { echo "  FAIL     C does not compile for musl dynamically" >&2; exit 1; }
	@echo "  OK       dynamic  $$($(CROSS)readelf -d $(TC_CHECK_DIR)/t.dyn | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | tr '\n' ' ')"
	@$(CROSS)gcc -O2 -static -o $(TC_CHECK_DIR)/t.static $(TC_CHECK_DIR)/t.c \
	  || { echo "  FAIL     C does not link statically against musl" >&2; exit 1; }
	@echo "  OK       static   $$(wc -c < $(TC_CHECK_DIR)/t.static | tr -d ' ') bytes"
	@echo "  READY    $(if $(CROSS_COMPILE),CROSS_COMPILE,$(TC_VENDOR) $(TC_VERSION)) builds C against musl"

# ---------------------------------------------------------------------------
# Step 2 - the target sysroot
#
# musl is built here rather than read out of ../rootfs/build/sysroot: sibling
# repositories consume each other's *published releases*, never each other's
# build trees, which is what keeps each of them buildable alone and in CI.
#
# The version is pinned to whatever rootfs ships, because this binary is
# dynamically linked and has to run against the musl that is on the device.
#
#   CAUTION: rootfs resolves musl as "latest" by default, so it can move out
#   from under this pin, and ../llvm pins the same version for the same reason.
#   When rootfs moves, move both.
#
# The cross-toolchain has musl 1.2.5 baked into its own sysroot, which is not
# what ships, so --sysroot points at this tree instead.
# ---------------------------------------------------------------------------

MUSL_VERSION ?= 1.2.6
MUSL_BASE    := https://musl.libc.org/releases
MUSL_ARCHIVE  = musl-$(MUSL_VERSION).tar.gz
MUSL_URL      = $(MUSL_BASE)/$(MUSL_ARCHIVE)
MUSL_SUMS     = $(CHECKSUMS)/musl-$(MUSL_VERSION).sha256

DL_MUSL    := $(DL_DIR)/musl
MUSL_DIR   := $(BUILD_DIR)/musl
MUSL_SRC    = $(MUSL_DIR)/musl-$(MUSL_VERSION)
MUSL_STAMP  = $(MUSL_DIR)/.installed
SYSROOT    := $(BUILD_DIR)/sysroot

MUSL_CFG := $(MUSL_DIR)/.config
MUSL_SIG  = $(MUSL_VERSION)|$(TC_VENDOR)|$(TC_VERSION)|$(CROSS_COMPILE)
$(eval $(call config_stamp_rule,$(MUSL_CFG),$(MUSL_SIG)))

.PHONY: sysroot
sysroot: $(MUSL_STAMP) ## Build the musl sysroot the target binary links against
	@echo "  READY    musl $(MUSL_VERSION) -> $(SYSROOT)"

# configure and make are noisy and only interesting when they fail, so the
# output goes to a log and the tail of it is what surfaces on an error.
$(MUSL_STAMP): $(TOOLCHAIN_DEP) $(MUSL_CFG) Makefile
	@$(call assert_cross_compiler)
	@mkdir -p $(DL_MUSL) $(MUSL_DIR) $(CHECKSUMS)
	@if [ ! -f $(DL_MUSL)/$(MUSL_ARCHIVE) ]; then \
	   echo "  FETCH    $(MUSL_ARCHIVE)"; \
	   $(CURL) -o $(DL_MUSL)/$(MUSL_ARCHIVE).part "$(MUSL_URL)"; \
	   mv -f $(DL_MUSL)/$(MUSL_ARCHIVE).part $(DL_MUSL)/$(MUSL_ARCHIVE); \
	 fi
	@if [ -f $(MUSL_SUMS) ]; then \
	   echo "  VERIFY   $(MUSL_ARCHIVE)"; \
	   ( cd $(DL_MUSL) && $(SHA256) --check --quiet $(abspath $(MUSL_SUMS)) ) || { \
	     echo "  FAIL     $(MUSL_ARCHIVE) does not match $(MUSL_SUMS)" >&2; exit 1; }; \
	 else \
	   ( cd $(DL_MUSL) && $(SHA256) $(MUSL_ARCHIVE) ) > $(MUSL_SUMS); \
	   echo "  RECORD   $(MUSL_SUMS) - first fetch of this version, commit it"; \
	 fi
	@echo "  UNPACK   $(MUSL_ARCHIVE)"
	@rm -rf $(MUSL_SRC)
	@tar -xf $(DL_MUSL)/$(MUSL_ARCHIVE) -C $(MUSL_DIR)
	@echo "  CONFIG   musl $(MUSL_VERSION) (static + shared)"
	@( cd $(MUSL_SRC) && $(SCRUB_ENV) ./configure --prefix=/usr --syslibdir=/lib \
	       --enable-static --enable-shared --disable-wrapper \
	       CROSS_COMPILE=$(CROSS) ) > $(MUSL_SRC)/configure.log 2>&1 || { \
	   tail -20 $(MUSL_SRC)/configure.log >&2; \
	   echo "  FAIL     configure (full log: $(MUSL_SRC)/configure.log)" >&2; exit 1; }
	@echo "  BUILD    musl $(MUSL_VERSION) (-j$(JOBS))"
	@$(MAKE) --no-print-directory -C $(MUSL_SRC) -j$(JOBS) > $(MUSL_SRC)/build.log 2>&1 || { \
	   tail -30 $(MUSL_SRC)/build.log >&2; \
	   echo "  FAIL     build (full log: $(MUSL_SRC)/build.log)" >&2; exit 1; }
	@echo "  INSTALL  -> $(SYSROOT)"
	@rm -rf $(SYSROOT)/usr/include $(SYSROOT)/usr/lib $(SYSROOT)/lib/ld-musl-*
	@mkdir -p $(SYSROOT)
	@$(MAKE) --no-print-directory -C $(MUSL_SRC) install DESTDIR=$(abspath $(SYSROOT)) \
	   >> $(MUSL_SRC)/build.log 2>&1 || { \
	   tail -30 $(MUSL_SRC)/build.log >&2; \
	   echo "  FAIL     install (full log: $(MUSL_SRC)/build.log)" >&2; exit 1; }
	@$(call install_uapi_headers)
	@touch $@

# musl installs libc headers and nothing else, which is not a usable sysroot:
# anything that talks to the kernel needs the Linux UAPI headers too. They come
# from the cross-toolchain's own sysroot rather than being downloaded, so this
# costs nothing and cannot drift from the compiler. Same approach as ../rootfs
# and ../llvm.
define install_uapi_headers
	set -e; \
	k=$$($(CROSS)gcc -print-sysroot)/usr/include; \
	[ -d "$$k" ] || { echo "  FAIL     $(CROSS)gcc has no sysroot to take UAPI headers from" >&2; exit 1; }; \
	i=$(abspath $(SYSROOT))/usr/include; mkdir -p "$$i"; \
	for d in linux asm asm-generic mtd rdma sound video drm misc scsi xen; do \
	  if [ -d "$$k/$$d" ]; then rm -rf "$$i/$$d"; cp -R "$$k/$$d" "$$i/$$d"; fi; \
	done; \
	[ -f $(abspath $(SYSROOT))/usr/include/linux/kd.h ] \
	  || { echo "  FAIL     no Linux UAPI headers landed in $(SYSROOT)" >&2; exit 1; }
endef

# musl stamps its version into libc.so as a bare "1.2.6" line. Read in two
# steps rather than one pipeline: under `set -o pipefail` a `grep -m1` exits
# early, SIGPIPEs its producer and fails the pipeline *after* printing the
# answer, so a trailing `|| echo unknown` fires too and both lines appear.
# `strings` is not available (binutils is absent from debian:trixie-slim) and
# BSD `tr` cannot read NUL bytes, so `grep -a -o` is the portable probe.
define musl_version_of
$(shell LC_ALL=C grep -a -o -E '1\.[0-9]+\.[0-9]+' $(1) 2>/dev/null | sed -n '1p')
endef

.PHONY: sysroot-info
sysroot-info: $(MUSL_STAMP) ## Show the sysroot's musl version and layout
	@echo "  sysroot  $(SYSROOT)"
	@echo "  pinned   $(MUSL_VERSION)"
	@v='$(call musl_version_of,$(SYSROOT)/usr/lib/libc.so)'; \
	 if [ -z "$$v" ]; then \
	   echo "  built    unknown - could not read a version out of libc.so"; \
	 elif [ "$$v" != "$(MUSL_VERSION)" ]; then \
	   echo "  FAIL     the sysroot holds $$v, not the pinned $(MUSL_VERSION)" >&2; exit 1; \
	 else \
	   echo "  built    $$v"; \
	 fi
	@ls -l $(SYSROOT)/lib/ld-musl-aarch64.so.1 | sed 's/^/  loader   /'

.PHONY: sysroot-check
sysroot-check: $(MUSL_STAMP) ## Prove C links dynamically against this sysroot
	@mkdir -p $(TC_CHECK_DIR)
	@printf '%s\n' \
	  '#include <stdio.h>' \
	  'int main(void) { printf("sepiaos\n"); return 0; }' > $(TC_CHECK_DIR)/s.c
	@$(CROSS)gcc --sysroot=$(abspath $(SYSROOT)) -O2 -o $(TC_CHECK_DIR)/s.dyn $(TC_CHECK_DIR)/s.c \
	  || { echo "  FAIL     C does not link dynamically against $(SYSROOT)" >&2; exit 1; }
	@$(call assert_target_elf,$(TC_CHECK_DIR)/s.dyn,the test binary)
	@echo "  READY    C links dynamically against musl $(MUSL_VERSION)"

# ---------------------------------------------------------------------------
# Step 3 - the GNU make sources
#
# The release tarball, not a clone. The Savannah git tree ships configure.ac
# and Makefile.am but *no* configure and no Makefile.in, so a checkout cannot
# be configured until ./bootstrap has fetched gnulib and regenerated them -
# which would put autoconf, automake, autopoint and gettext on every developer
# machine and in CI for no gain. The release tarball ships a working configure
# and is what upstream signs.
#
# GNU publishes a detached GPG signature but no sha256 sidecar, so - as
# ../llvm and ../rootfs both do - the digest is recorded here on first fetch
# and checked on every fetch after that. Commit checksums/ to make the pin mean
# something to anyone else.
# ---------------------------------------------------------------------------

MAKE_ARCHIVE  = make-$(GNU_MAKE_VERSION).tar.gz
MAKE_URL      = https://ftp.gnu.org/gnu/make/$(MAKE_ARCHIVE)
MAKE_SUMS     = $(CHECKSUMS)/make-$(GNU_MAKE_VERSION).sha256

DL_SRC     := $(DL_DIR)/make
# Unpacked under build/, not downloads/: build.sh compiles in-tree, so this is
# a build artifact that `clean` should remove. The tarball in downloads/ is the
# immutable thing, and re-unpacking from it costs a second.
SRC_DIR    := $(BUILD_DIR)/src
MAKE_SRC    = $(SRC_DIR)/make-$(GNU_MAKE_VERSION)
SRC_STAMP   = $(MAKE_SRC)/.unpacked

.PHONY: sources
sources: $(SRC_STAMP) ## Download, verify and unpack the GNU make sources
	@echo "  READY    make $(GNU_MAKE_VERSION) -> $(MAKE_SRC)"

$(SRC_STAMP):
	@command -v tar >/dev/null 2>&1 || { echo "tar is required" >&2; exit 1; }
	@mkdir -p $(DL_SRC) $(SRC_DIR) $(CHECKSUMS)
	@if [ ! -f $(DL_SRC)/$(MAKE_ARCHIVE) ]; then \
	   echo "  FETCH    $(MAKE_ARCHIVE)"; \
	   $(CURL) -o $(DL_SRC)/$(MAKE_ARCHIVE).part "$(MAKE_URL)"; \
	   mv -f $(DL_SRC)/$(MAKE_ARCHIVE).part $(DL_SRC)/$(MAKE_ARCHIVE); \
	 fi
	@if [ -f $(MAKE_SUMS) ]; then \
	   echo "  VERIFY   $(MAKE_ARCHIVE)"; \
	   ( cd $(DL_SRC) && $(SHA256) --check --quiet $(abspath $(MAKE_SUMS)) ) || { \
	     echo "  FAIL     $(MAKE_ARCHIVE) does not match $(MAKE_SUMS)" >&2; exit 1; }; \
	 else \
	   ( cd $(DL_SRC) && $(SHA256) $(MAKE_ARCHIVE) ) > $(MAKE_SUMS); \
	   echo "  RECORD   $(MAKE_SUMS) - first fetch of this version, commit it"; \
	 fi
	@echo "  UNPACK   $(MAKE_ARCHIVE) -> $(MAKE_SRC)"
	@rm -rf $(MAKE_SRC)
	@mkdir -p $(MAKE_SRC)
	@tar -xf $(DL_SRC)/$(MAKE_ARCHIVE) -C $(MAKE_SRC) --strip-components=1
	@$(call assert_source_version)
	@touch $@

# The unpacked tree has to be the version that was pinned. A mismatch means the
# tarball, the digest and GNU_MAKE_VERSION disagree, and everything after this
# would build something other than what the manifest claims.
define assert_source_version
	set -e; \
	v=$$(sed -n "s/^PACKAGE_VERSION='\(.*\)'/\1/p" $(MAKE_SRC)/configure | sed -n '1p'); \
	[ -n "$$v" ] || { echo "  FAIL     no PACKAGE_VERSION in $(MAKE_SRC)/configure" >&2; exit 1; }; \
	[ "$$v" = "$(GNU_MAKE_VERSION)" ] || { \
	  echo "  FAIL     the tree declares $$v but GNU_MAKE_VERSION is $(GNU_MAKE_VERSION)" >&2; exit 1; }; \
	[ -f $(MAKE_SRC)/build.sh ] || { \
	  echo "  FAIL     no build.sh in the tree - README.md's build step does not exist" >&2; exit 1; }
endef

.PHONY: sources-info
sources-info: $(SRC_STAMP) ## Show the source version and where it came from
	@echo "  version  $(GNU_MAKE_VERSION)"
	@echo "  archive  $(DL_SRC)/$(MAKE_ARCHIVE)"
	@echo "  source   $(MAKE_SRC)"
	@echo "  size     $$(du -sh $(MAKE_SRC) | cut -f1)"
	@sed 's/^/  sha256   /' $(MAKE_SUMS)

.PHONY: verify-downloads
verify-downloads: ## Check the sources against the recorded digest
	@test -f $(MAKE_SUMS) || { echo "No $(MAKE_SUMS); run 'make sources' first." >&2; exit 1; }
	@( cd $(DL_SRC) && $(SHA256) --check --quiet $(abspath $(MAKE_SUMS)) )
	@echo "  OK       $(MAKE_SUMS)"

# ---------------------------------------------------------------------------
# Step 4 - configure and build
#
# README.md's two steps, in its order: ./configure, then ./build.sh.
#
# build.sh is upstream's own script - "Shell script to build GNU Make in the
# absence of any 'make' program" - not something this repository provides. It
# reads ./build.cfg, which configure generates, so every value it compiles with
# (CC, CFLAGS, LDFLAGS, AR) arrives from the configure line below and the
# script itself needs no cross awareness.
#
# CC, AR, RANLIB and STRIP are passed explicitly rather than left to autoconf's
# --host search. Autoconf would look for $(TARGET_TRIPLE)-ar on PATH, which is
# not there (the toolchain lives under downloads/) and is not even the right
# name on Linux, where bootlin calls its tools aarch64-linux-*. It would then
# silently fall back to the *host's* ar and produce a Mach-O archive that the
# aarch64 link cannot use.
# ---------------------------------------------------------------------------

# -std=gnu17 is not a style preference, it is what makes 4.4.1 compile at all
# with a modern GCC. GCC 15 defaults to C23, where an empty parameter list means
# (void), and make's bundled gnulib still declares `extern char *getenv ();` in
# lib/fnmatch.c - which then conflicts with the real prototype and is an error,
# not a warning:
#
#   lib/fnmatch.c:124:14: error: conflicting types for 'getenv';
#                                have 'char *(void)'
#
# It surfaces *only* when cross-compiling. configure cannot run its "does the
# system fnmatch work" probe against the target, so it conservatively builds the
# gnulib replacement - the file a native build never compiles. Drop this flag
# and the build dies ~15 files in.
TARGET_CFLAGS  ?= -O2 -std=gnu17 --sysroot=$(abspath $(SYSROOT))
TARGET_LDFLAGS ?= --sysroot=$(abspath $(SYSROOT))

MAKE_BIN    = $(MAKE_SRC)/make
BUILD_LOG   = $(MAKE_SRC)/build.log
BUILD_CFG  := $(BUILD_DIR)/.config
BUILD_SIG   = $(GNU_MAKE_VERSION)|$(TARGET_TRIPLE)|$(PREFIX)|$(CONFIGURE_FLAGS)|$(TARGET_CFLAGS)|$(TARGET_LDFLAGS)|$(MUSL_VERSION)|$(TC_VENDOR)|$(TC_VERSION)|$(CROSS_COMPILE)
$(eval $(call config_stamp_rule,$(BUILD_CFG),$(BUILD_SIG)))

.PHONY: make
make: $(MAKE_BIN) ## Cross-build the make binary for the target
	@echo "  READY    make $(GNU_MAKE_VERSION) -> $(MAKE_BIN)"

$(MAKE_BIN): $(SRC_STAMP) $(MUSL_STAMP) $(BUILD_CFG) Makefile
	@$(call assert_cross_compiler)
	@echo "  CONFIG   make $(GNU_MAKE_VERSION) for $(TARGET_TRIPLE)"
	@( cd $(MAKE_SRC) && $(SCRUB_ENV) ./configure $(CONFIGURE_FLAGS) \
	       CC="$(CROSS)gcc" AR="$(CROSS)ar" RANLIB="$(CROSS)ranlib" \
	       STRIP="$(CROSS)strip" \
	       CFLAGS="$(TARGET_CFLAGS)" LDFLAGS="$(TARGET_LDFLAGS)" ) \
	     > $(MAKE_SRC)/configure.log 2>&1 || { \
	   tail -30 $(MAKE_SRC)/configure.log >&2; \
	   echo "  FAIL     configure (full log: $(MAKE_SRC)/configure.log)" >&2; exit 1; }
	@test -f $(MAKE_SRC)/build.cfg || { \
	   echo "  FAIL     configure did not generate build.cfg, which build.sh sources" >&2; exit 1; }
	@echo "  BUILD    build.sh (upstream's bootstrap script)"
	@( cd $(MAKE_SRC) && $(SCRUB_ENV) sh build.sh ) > $(BUILD_LOG) 2>&1 || { \
	   tail -30 $(BUILD_LOG) >&2; \
	   echo "  FAIL     build.sh (full log: $(BUILD_LOG))" >&2; exit 1; }
	@test -f $@ || { \
	   echo "  FAIL     build.sh produced no $@" >&2; exit 1; }
	@$(call assert_target_elf,$@,the built make)

# A cross-build succeeds just as happily having produced a binary for the build
# host, and nothing downstream would notice until the card did. So every
# product is read back: aarch64, and pointing at the loader the device has.
# $(1) file, $(2) what to call it in a message
define assert_target_elf
	set -e; \
	$(CROSS)readelf -h $(1) | grep -q AArch64 \
	  || { echo "  FAIL     $(2) is not aarch64" >&2; exit 1; }; \
	$(CROSS)readelf -l $(1) | grep -q 'ld-musl-aarch64.so.1' \
	  || { echo "  FAIL     $(2) does not use the musl loader - is it static?" >&2; exit 1; }; \
	echo "  OK       $(2): aarch64, musl loader, needs $$($(CROSS)readelf -d $(1) | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | tr '\n' ' ')"
endef

.PHONY: build-info
build-info: $(MAKE_BIN) ## Show the built binary and what it needs
	@echo "  binary   $(MAKE_BIN)"
	@echo "  size     $$(wc -c < $(MAKE_BIN) | tr -d ' ') bytes"
	@echo "  machine  $$($(CROSS)readelf -h $(MAKE_BIN) | sed -n 's/ *Machine: *//p')"
	@echo "  loader   $$($(CROSS)readelf -l $(MAKE_BIN) | sed -n 's/.*program interpreter: \(.*\)\]/\1/p')"
	@echo "  needs    $$($(CROSS)readelf -d $(MAKE_BIN) | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# Step 5 - stage the install tree
#
# The tree is laid out exactly as it will sit on the device - prefix /usr, so
# usr/bin/make - without anything being written outside build/.
#
# The binary is copied rather than installed by upstream's `install` target,
# and that is not a shortcut. Upstream's README says to run `./make install`
# using the make that was just built: here that binary is aarch64 and cannot
# execute on the build host. Running the *host's* make against the generated
# Makefile would work, but it recompiles the whole program a second time with
# the same compiler to produce the same binary build.sh already linked.
#
# COPYING travels with it: make is GPLv3 and this ships a binary of it.
#
# musl is deliberately not staged - the device's libc comes from ../rootfs, and
# a second copy on the card is two libcs disagreeing.
# ---------------------------------------------------------------------------

STAGE_DIR   := $(BUILD_DIR)/stage
STAGE_STAMP  = $(STAGE_DIR)/.staged
STAGE_BIN    = $(STAGE_DIR)$(PREFIX)/bin/make

# Measured on 4.4.1: 304,816 bytes unstripped, 270,896 stripped. A 34 KB
# saving is not dramatic, but there is no debugger on the device to want the
# symbols, so it is free.
WITH_STRIP ?= 1

# Both of these change what lands in the staged tree without changing any file
# the tree is built from, so they need their own signature: $(STAGE_STAMP)
# depends on the built binary alone, and `WITH_STRIP=0 gmake stage` would
# otherwise report nothing to be done and hand back the stripped tree.
STAGE_CFG := $(STAGE_DIR)/.config
STAGE_SIG  = $(PREFIX)|$(WITH_STRIP)|$(GNU_MAKE_VERSION)
$(eval $(call config_stamp_rule,$(STAGE_CFG),$(STAGE_SIG)))

.PHONY: stage
stage: $(STAGE_STAMP) ## Install the binary into a staged /usr tree
	@echo "  READY    staged $$(du -sh $(STAGE_DIR) | cut -f1) -> $(STAGE_DIR)"

# The staged tree is wiped and rebuilt rather than updated in place, so a
# renamed or removed file cannot survive into a later build - ../boot rebuilds
# its image for the same reason. $(STAGE_CFG) lives inside it, so it is written
# after the wipe, not before.
$(STAGE_STAMP): $(MAKE_BIN) $(STAGE_CFG)
	@rm -rf $(STAGE_DIR)
	@mkdir -p $(STAGE_DIR)$(PREFIX)/bin $(STAGE_DIR)$(PREFIX)/share/licenses/make
	@printf '%s\n' '$(STAGE_SIG)' > $(STAGE_CFG)
	@echo "  INSTALL  $(PREFIX)/bin/make"
	@cp $(MAKE_BIN) $(STAGE_BIN)
ifeq ($(WITH_STRIP),1)
	@$(CROSS)strip $(STAGE_BIN)
endif
	@cp $(MAKE_SRC)/COPYING $(STAGE_DIR)$(PREFIX)/share/licenses/make/COPYING
	@touch $@

.PHONY: stage-check
stage-check: $(STAGE_STAMP) ## Verify the staged tree is aarch64 and needs only musl
	@test -x $(STAGE_BIN) || { echo "  FAIL     no executable at $(STAGE_BIN)" >&2; exit 1; }
	@$(call assert_target_elf,$(STAGE_BIN),staged make)
	@$(call assert_closure,$(STAGE_BIN),staged make)
	@test -f $(STAGE_DIR)$(PREFIX)/share/licenses/make/COPYING \
	  || { echo "  FAIL     COPYING is not staged; this ships a GPL binary" >&2; exit 1; }
	@$(call assert_no_libc)
	@echo "  READY    staged tree is self-contained apart from musl"

# The whole point of the linkage choice: this binary may depend on the device's
# musl and on nothing else. ../llvm learned the hard way that a DT_NEEDED
# nobody checked - libatomic.so.1, recorded without a single symbol referenced -
# kills every program at exec on a card that does not have it.
# $(1) file, $(2) what to call it in a message
define assert_closure
	set -e; \
	bad=""; \
	for n in $$($(CROSS)readelf -d $(1) | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'); do \
	  case "$$n" in libc.so*) ;; *) bad="$$bad $$n";; esac; \
	done; \
	[ -z "$$bad" ] || { \
	  echo "  FAIL     $(2) needs$$bad, which nothing on the card provides" >&2; exit 1; }; \
	echo "  OK       $(2) needs musl and nothing else"
endef

# musl reaching the asset would be a packaging mistake with a long fuse: it
# would install over rootfs's own libc and its loader, and the mismatch would
# only surface as something odd at runtime on the device.
define assert_no_libc
	set -e; \
	found=$$(find $(STAGE_DIR) \( -name 'libc.so*' -o -name 'ld-musl-*' \) -print); \
	if [ -n "$$found" ]; then \
	  echo "  FAIL     musl is in the staged tree; only make ships:" >&2; \
	  printf '           %s\n' $$found >&2; exit 1; \
	fi; \
	echo "  OK       make only - no libc, no loader"
endef

.PHONY: stage-info
stage-info: $(STAGE_STAMP) ## Show what the staged tree contains
	@echo "  stage    $(STAGE_DIR)"
	@echo "  size     $$(du -sh $(STAGE_DIR) | cut -f1)"
	@echo "  stripped $(if $(filter 1,$(WITH_STRIP)),yes,no)"
	@find $(STAGE_DIR) -type f ! -name '.staged' ! -name '.config' \
	  | sed "s|$(STAGE_DIR)/|  file     |"

# ---------------------------------------------------------------------------
# Step 6 - the release asset
#
# The staged tree, tarred and compressed: exactly what rootfs unpacks into the
# root filesystem. Sibling repositories consume each other's *published
# releases* rather than each other's build trees, so this is the supported way
# out of here - nothing should read build/ across the filesystem.
# ---------------------------------------------------------------------------

# Set by the release workflow so the published file names the release it came
# from; empty for a local build, which names the make version alone.
DIST_TAG   ?=
DIST_ASSET  = sepiaos-make-$(GNU_MAKE_VERSION)-aarch64-musl$(if $(DIST_TAG),-$(DIST_TAG)).tar.xz
DIST_SUMS  := SHA256SUMS

.PHONY: dist
dist: $(STAGE_STAMP) ## Pack the staged tree into dist/ as a release asset
	@$(call assert_no_libc)
	@mkdir -p $(DIST_DIR)
	@echo "  PACK     $(DIST_ASSET)"
	@tar -C $(STAGE_DIR) -cf - .$(PREFIX) | xz -9 -T0 -c > $(DIST_DIR)/$(DIST_ASSET).part
	@mv -f $(DIST_DIR)/$(DIST_ASSET).part $(DIST_DIR)/$(DIST_ASSET)
	@( cd $(DIST_DIR) && $(SHA256) $(DIST_ASSET) > $(DIST_SUMS) )
	@echo "  READY    $$(du -h $(DIST_DIR)/$(DIST_ASSET) | cut -f1) -> $(DIST_DIR)/$(DIST_ASSET)"

.PHONY: dist-info
dist-info: ## Show the packed asset and its digest
	@test -f $(DIST_DIR)/$(DIST_ASSET) \
	  || { echo "No $(DIST_DIR)/$(DIST_ASSET); run 'make dist' first." >&2; exit 1; }
	@echo "  asset    $(DIST_DIR)/$(DIST_ASSET)"
	@du -h $(DIST_DIR)/$(DIST_ASSET) | sed 's/^/  size     /' | cut -f1,2
	@sed 's/^/  sha256   /' $(DIST_DIR)/$(DIST_SUMS)
	@tar -tf $(DIST_DIR)/$(DIST_ASSET) | sed 's|^\./|  contents |'

# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------

.PHONY: clean
clean: ## Remove build output (keeps downloads)
	rm -rf $(BUILD_DIR)

.PHONY: distclean
distclean: clean ## Also remove downloaded sources and the toolchain
	rm -rf $(DL_DIR) $(DIST_DIR)

# Read one variable's value, for scripts and CI: make -s print-DIST_ASSET
print-%:
	@echo '$($*)'

.PHONY: help
help: ## Show this help
	@echo "SepiaOS GNU make build"
	@echo
	@echo "Targets:"
	@grep -hE '^[a-zA-Z_-]+([ ]+[a-zA-Z_-]+)*:.*?## ' $(MAKEFILE_LIST) \
	  | sed 's/:.*## /|/' \
	  | awk -F'|' '{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Variables:"
	@printf "  %-18s %s\n" \
	  "GNU_MAKE_VERSION" "upstream make release (default $(GNU_MAKE_VERSION))" \
	  "MUSL_VERSION"     "target musl - must match what rootfs ships (default $(MUSL_VERSION))" \
	  "PREFIX"           "where the binary lands on the device (default $(PREFIX))" \
	  "CONFIGURE_FLAGS"  "passed to upstream's configure" \
	  "CROSS_COMPILE"    "use a musl cross-toolchain you already have" \
	  "WITH_STRIP"       "strip the staged binary (default $(WITH_STRIP))" \
	  "DIST_TAG"         "release tag to name the asset after" \
	  "JOBS"             "parallelism for the musl build (default $(JOBS))"
	@echo
	@echo "Examples:"
	@echo "  make toolchain-check                 prove the compiler works"
	@echo "  make make                            cross-build make"
	@echo "  make stage-check                     prove the result is shippable"
	@echo "  make CROSS_COMPILE=/path/to/aarch64-unknown-linux-musl- make"
