# Release input manifests

Each shippable release needs a checked-in `v<version>.manifest` that pins the
inputs used to build it. `UNRESOLVED` is allowed while a development manifest is
being assembled, but `release/check.sh ship` rejects it.

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

The manifest is line-oriented, rejects duplicate keys, and has a required
schema version. Source revisions are 40-character Git object IDs; SHA-256
values are lowercase hexadecimal digests. Do not replace an unknown value with
a branch name or a guessed hash.
