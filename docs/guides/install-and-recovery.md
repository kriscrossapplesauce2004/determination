# Install and recovery

Status: current safety guide
Authority: device qualification maintainers
Last reviewed: 2026-07-30

## Before an install or upgrade

The only supported target is listed in the [device reference](../reference/supported-device.md).
Back up data and retain a verified, target-slot-matched boot image outside the
source checkout. Confirm that the release manifest, compatibility check, and
checksums match the candidate artifacts.

Use a reversible validation path before writing a boot partition. A failed
build, an unknown device profile, or a missing recovery image is a stop
condition, not a reason to continue.

## Recovery baseline

Phone mode is the recovery baseline. The independent emergency restore path
must remain available when the guest, control daemon, or companion is absent.
Collect the relevant bounded logs and run the documented diagnostics before
retrying. Device-level flashing, partition writes, and recovery drills require
an explicit hardware qualification run; they are not host validation steps.

## Upgrade and rollback

Use only complete, versioned payloads with recorded hashes. Verify install,
upgrade, rollback, and restore against the exact supported ROM before a public
release. Keep one known-good payload and do not delete the external recovery
copy after a successful update.
