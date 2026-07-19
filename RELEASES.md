# Determination releases

Determination release trains are named after **Deltarune characters**. The
name belongs to the `major.minor` train, so patch releases keep it:

- `0.5.0 "Aqua"`, `0.5.1 "Aqua"`, ...
- `0.6.0 "Seth"`, `0.6.1 "Seth"`, ...
- `1.0.0 "Kris"`, `1.0.1 "Kris"`, ...

Git tags stay machine-friendly (`v0.5.0`). Human-facing titles use
`Determination 0.5 "Aqua"`. New names are assigned only when a release train
gets an actual engineering scope; we do not burn characters on arbitrary
calendar bumps.

## Release map

| Train | Character | State | Meaning |
|---|---|---|---|
| 0.5.x | Aqua | in development | First packaged guacamoleb release of the proven internal convergence stack |
| 0.6.x | Seth | planned | Scope to be fixed after Aqua ships |
| 1.0.x | Kris | reserved | First stable release; its support contract must be written before release work starts |

Active development builds use SemVer prereleases. Aqua therefore begins at
`0.5.0-alpha.1`; the unsuffixed `0.5.0` is reserved for the finished Aqua
release, not reused for changing development binaries.

Starting with Aqua, `version.properties` is the single source of truth for the
project version, character name, release state, and numeric build code. The
Magisk module, companion APK, and kernel install/restore zips all
consume it when built.

Before Aqua, components had unrelated versions: the module reached `0.4.1`, the
companion `0.5.6`, and the kernel actions `0.2.x`.
Aqua deliberately resets their displayed SemVer to the project-wide `0.5.0`.
Its shared `versionCode` starts at 12, one above the highest legacy installable
component, so Android still treats the Aqua companion as an upgrade.

## Aqua: 0.5.0

Aqua is intentionally narrow: one supported phone, one tested ROM line, and a
working internal desktop. It packages what has been proven on the OnePlus 7
`guacamoleb`; it does not pretend the portability hypothesis or concurrent
external convergence is finished.

Included scope:

- Android-hosted Debian LXC guest with an unprivileged desktop session.
- Phosh through libhybris/hwcomposer, including display and input handoff.
- Plasma Mobile through the native KMS + Turnip/minigbm path.
- Companion app and Quick Settings entry/exit controls.
- Verified phone recovery path and boot-image restore tooling.
- The first recon-driven device-profile slice, while retaining guacamoleb as
  the only supported target.

Explicit non-goals:

- Concurrent DP-alt phone + desktop output.
- A claim of general device support.
- A claim that Android remains fully live in internal mode: `system_server` is
  frozen during the handoff.
- Treating the guest as a strong security boundary. Hardware-node permissions
  and host control remain prototype-grade and must be documented as such.

### Aqua ship gates

Before `v0.5.0` is tagged:

- [ ] Reconcile local and remote history; build from a clean release commit.
- [ ] Pin every release-critical external source to an immutable commit or
      package snapshot and record it in the build manifest.
- [ ] Produce the boot image, Magisk module, companion release APK, installer,
      restore payload, checksums, and build manifest from that commit.
- [ ] Sign the companion with the permanent Determination release key and
      verify the APK signature; debug or unsigned APKs are not release assets.
- [ ] Run at least 50 automated phone/desktop round trips with recovery
      verified after induced compositor failure.
- [ ] Complete a multi-hour on-device soak covering Wi-Fi, charging changes,
      suspend/wake, and desktop exit.
- [ ] Verify fresh install, upgrade from module `v0.4.1`, and restore on the
      supported crDroid build.
- [ ] Publish installation instructions, supported-device data, known issues,
      and recovery instructions beside the artifacts.

Run `release/check.sh` for development checks. `release/check.sh ship` applies
the stricter clean-tree, release-status, artifact, and manifest gates.

## Versioning rules

- `version.properties` is authoritative. Do not hard-code a separate product
  version in a component build.
- Project releases use SemVer tags, with prereleases such as
  `v0.5.0-alpha.1`, `v0.5.0-beta.1`, and `v0.5.0-rc.1` when needed.
- `versionCode` is a plain monotonically increasing build number shared by
  installable artifacts. It must increase for every distributed build and is
  never derived from, lowered with, or reused for a SemVer value.
- Pre-1.0 minor releases may change installation or internal interfaces.
- Patch releases contain compatible fixes and retain their character name.
- A post-1.0 minor release does not automatically get a new character; named
  trains are deliberate product milestones, not every routine feature bump.
- The release name never replaces the version in filenames, update checks, or
  compatibility logic.
- `status=development` is for ordinary work, `ready` allows a release candidate
  to pass the ship audit, and `released` records that the matching tag and
  artifacts were published. A status change is not a substitute for the gates.
