# Contributing to Determination

## Scope and safety

Determination changes display ownership, boot images, and Android services. Do
not run device mutation, flashing, or recovery commands as part of a host-side
change unless the device qualification owner has explicitly approved that run.
Phone mode is the recovery baseline.

Start with the [documentation home](docs/README.md), then read the relevant
task guide. Keep a change limited to one ownership area unless the orchestrator
has agreed an interface change.

## Before opening a pull request

Run the available host checks from the repository root:

```sh
./tools/check-host.sh
```

The repository intentionally does not depend on a hosted CI runner. GitHub has
locked Actions for the project account because of its billing state, and the
maintainer does not intend to add billing. Contributors and reviewers therefore
record the local host-check result in the pull request.

Run component tests when modifying their area. Do not claim device verification
without a dated hardware record that identifies the commit, build manifest, and
result.

## Change rules

- Keep active prose direct, factual, and free of em dashes.
- Do not commit generated packages, raw logs, boot images, or captures unless
  they are listed in `artifacts/manifest.json` and meet the retention policy.
- Add or update a test when changing a parser, protocol, release gate, or
  generated configuration.
- Treat release inputs as immutable. A branch name is not a release pin.
- Preserve an independent phone recovery path when touching lifecycle work.

## Commit and review

Use focused commits with a descriptive subject. Explain user impact, host
validation, device qualification still required, and rollback implications in
the pull request. Never add keys, credentials, device identifiers not needed
for a reproducible report, or private logs.
