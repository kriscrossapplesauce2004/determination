# Artifact retention policy

`artifacts/` contains curated engineering evidence, not an unbounded build
output directory. The tracked inventory is in `artifacts/manifest.json`.

## Retain in Git

Keep small, reviewable evidence that supports a documented hardware claim:
structured probe output, concise qualification logs, selected screenshots, and
configuration snapshots. Every retained file needs provenance, a SHA-256 hash,
size, purpose, and retention class in the manifest.

## Keep out of Git

Boot images, install archives, APKs, raw serial/kernel logs, rootfs archives,
and disposable build outputs belong in a release asset or external artifact
store. Keep their provenance and checksum in the manifest when documentation
depends on them. Do not place replacements in the source tree merely because a
local build produced them.

## Adding evidence

1. Remove secrets and unrelated personal data.
2. Prefer a concise derived report over a raw log.
3. Add the manifest entry before staging the file.
4. Run `./tools/check-host.sh`, which includes link and repository-policy
   checks.

The policy affects new commits only. It does not rewrite existing Git history.
