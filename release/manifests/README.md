# Release input manifests

Each shippable release needs a checked-in `v<version>.manifest` that pins the
inputs used to build it. Aqua's manifest does not exist yet because several
critical inputs still follow moving branches; `release/check.sh ship` treats
that absence as a hard failure.

The manifest is plain `key=value` data and must include at least:

- project source commit;
- supported device and ROM build identity;
- pristine boot-image SHA-256;
- kernel repository commit, config SHA-256, and toolchain identity;
- libhybris, wlroots, phoc, Mesa, minigbm, and LXC source commits;
- Android SDK, NDK, Gradle, and companion dependency-lock identity;
- companion signing-certificate SHA-256 (never the key or its password);
- guest base snapshot and package-lock identity;
- every local patch SHA-256.

Generated artifact hashes belong in the release bundle's `SHA256SUMS`, not in
this input manifest.
