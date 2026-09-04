# make

This repository is building and providing the make package.

The sources from the latest release are pulled from
git://git.savannah.gnu.org/make. Afterwards the command `./configure` is
executed to configure the build; the installation target is `/usr/bin`.
The build itself triggered by executing the command `./build.sh`.

The build is compiled with the same cross-toolchain that is used in llvm, the
musl libc shall be used for linkinging the binary dynamically.
