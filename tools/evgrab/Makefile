# evgrab: builds for the Android host side (runs as root outside the guest).
# Static so it doesn't care about bionic vs glibc.
#
# Pick a toolchain, in preference order:
#   make NDK=~/android-ndk-r27      (bionic, most correct)
#   make CC=aarch64-linux-gnu-gcc   (glibc cross, static)
#   make host                       (host-arch build, syntax/logic check only)

CFLAGS ?= -O2 -Wall -Wextra -static

ifdef NDK
CC := $(NDK)/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android29-clang
CFLAGS := -O2 -Wall -Wextra  # bionic has no full -static; NDK binaries are fine
endif

evgrab: evgrab.c
	$(CC) $(CFLAGS) -o $@ $<

host: evgrab.c
	$(CC) -O2 -Wall -Wextra -o evgrab-host $<

clean:
	rm -f evgrab evgrab-host

.PHONY: host clean
