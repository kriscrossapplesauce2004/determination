# Determination Repository Overhaul: After

Status: implementation complete and draft pull request published

Baseline commit: `a55c19a9a910`

Task contract commit: `1841406f7ddd`

Overhaul branch: `agent/repository-overhaul`

Review date: 2026-07-30

## Purpose

This document reconciles every task frozen in [TASKS-BEFORE.md](TASKS-BEFORE.md).
It distinguishes host-verified implementation from work that still needs the
supported phone, Android build environment, release signing identity, or final
publication step.

| Outcome | Meaning |
|---|---|
| Complete | Implemented and covered by the available host-safe checks |
| Partial | A substantial safe improvement landed, but part of the acceptance criteria remains |
| Hardware gate | Implemented or documented, but the result cannot be claimed until it runs on the supported device |
| Release gate | Requires clean release inputs, package output, signing, or publication |

## Measured result

| Measurement | Before | After |
|---|---:|---:|
| Tracked files | 264 | 301 |
| Working checkout plus Git data | 339 MiB | 130 MiB |
| Packed Git data | 119.10 MiB | about 119 MiB, unchanged by design |
| Removed working-tree material | 0 | 214 MiB allocated, preserved temporarily outside the checkout |
| Changed paths | 0 | 185 across the task contract and implementation commits |
| Diff size | 0 | 3,354 insertions and 94,697 deletions |
| Active em dash matches | 446 baseline punctuation matches | 0 em dash matches outside artifacts and history |
| Host-safe validation entrypoint | none | `./tools/check-host.sh` |
| Host-safe validation duration | separate checks only | 13 seconds in the final integration run |
| Markdown files checked | no unified check | 41 |
| Website PNG reduction | not measured | 13,509 bytes in the published tree, with a repeatable optimizer for the remaining images |

The large-file cleanup does not rewrite public Git history. Existing clones keep
the old packed objects. A separately reviewed history migration would be needed
to reduce historical clone size.

## Native core outcomes

| ID | Outcome | Result and evidence |
|---|---|---|
| N01 | Complete | Protocol receive and send operations use bounded deadlines; silent and partial peers time out. |
| N02 | Partial | Bounded synchronous handling and deadlines prevent indefinite starvation; a separate concurrent connection-pool quota was not introduced. |
| N03 | Complete | Control tests cover partial frames, oversized frames, silent peers, and blocked I/O deadlines. |
| N04 | Complete | HWC staging installs and verifies both compatibility and UI libraries as one set. |
| N05 | Complete | Adapter output continues draining after the capture limit and reports truncation without blocking child exit. |
| N06 | Complete | Adapter children receive an explicit minimal environment. |
| N07 | Complete | Adapters run in process groups and timeout teardown covers descendants. |
| N08 | Complete | Audio claim, restore, and recovery share one exclusive transaction lock. |
| N09 | Complete | Audio journal state records generation, PID identity, and process start time. |
| N10 | Partial | Ownership and stale-identity fixtures were expanded; killed-helper concurrency still needs device ALSA qualification. |
| N11 | Complete | Presenter session state enforces buffer, pixel, ID, and lifecycle quotas. |
| N12 | Complete | Presenter session validation rejects mismatched serial and invalid lifecycle state, with teardown cleanup. |
| N13 | Complete | Host presenter tests cover duplicate registration, limits, invalid completion, and cleanup. |
| N14 | Complete | Admin and guest endpoint policy is explicit and tested by operation and identity. |
| N15 | Complete | Control state, policy, protocol, journal, transition, and tests build on the host without Android headers. |
| N16 | Partial | Adapter environment and several platform inputs are explicit; remaining Android service names are still part of the current target adapter contract. |
| N17 | Complete | Guest health is structured JSON with distinct unavailable, error, and value states. |
| N18 | Complete | Control tests validate structured observability across representative healthy and unavailable states. |
| N19 | Complete | `evgrab` has supervised foreground operation with readiness and startup failure reporting. |
| N20 | Complete | Input discovery is sorted, directory-configurable, and filtered by the profile allowlist. |
| N21 | Complete | Atomic pidfiles include PID, boot identity, start time, role, and generation checks. |
| N22 | Partial | Discovery and lifecycle code is host-build checked; an injectable ioctl fixture layer remains future work. |
| N23 | Partial | Journal and transition failure tests cover key boundaries, but not every possible write interruption. |
| N24 | Partial | HWC sources require HTTPS, immutable pins, and checksum inputs; target archive hashes remain a release gate. |
| N25 | Complete | Patching and build output use isolated work directories and reject stale device libraries. |
| N26 | Complete | Compatibility builds emit a machine-readable input, output, hash, SONAME, and device manifest. |
| N27 | Complete | The unused AAudio bridge source, build helper, and tracked binary were removed and retained only in history/provenance. |
| N28 | Complete | Active native comments and prose were cleaned of em dashes and speculative filler. |

## Device lifecycle outcomes

| ID | Outcome | Result and evidence |
|---|---|---|
| L01 | Complete | Desktop state is durable before suppressor startup and helper readiness is verified. |
| L02 | Complete | Enter, exit, guest start, boot apply, and host requests share a stale-aware transition lock and generation. |
| L03 | Complete | Recorded processes are checked by PID, start time, boot ID, role, and generation before signaling. |
| L04 | Complete | Exit refuses ambiguous compositor ownership and uses recovery instead of restoring SurfaceFlinger blindly. |
| L05 | Partial | Routine exit uses the capability control path and root-only operations are narrowed; the legacy fallback remains for emergency compatibility. |
| L06 | Partial | Entry is bounded, locked, journalled, and rollback-aware; not every legacy shell sub-step emits a separately typed result. |
| L07 | Complete | `desktop-off --emergency` provides a detd-independent phone restoration path with identity checks. |
| L08 | Complete | Device profiles use a typed key parser with unknown-key, path, enum, number, and injection rejection. |
| L09 | Complete | Lifecycle fixtures cover valid and invalid profile parsing plus deterministic generated configuration. |
| L10 | Complete | Generated configuration uses private temporary files, validation, and atomic rename. |
| L11 | Complete | Configuration and manifest generation share serialization and cannot publish partial pairs. |
| L12 | Complete | Zygisk framing has receive and send deadlines for partial or stalled clients. |
| L13 | Partial | Routine boot apply uses detd and typed transition states; observe-only deployments fall back to the proven locked lifecycle path. |
| L14 | Complete | Magisk logging directories are created before output redirection. |
| L15 | Complete | Boot-completion wait is bounded and records a degraded disposition on timeout. |
| L16 | Complete | Module payload activation uses versioned complete sets and verifies required content before switching. |
| L17 | Complete | The previous complete payload is retained as a known-good rollback target. |
| L18 | Partial | Host and action paths gained matching validation rules and reasons; one shared executable routine is still desirable. |
| L19 | Complete | Restore validates boot magic, size, slot selection, and expected hash before write. |
| L20 | Complete | The Linux-first profile records desired state, generation, known-good state, attempt, deadline, and result atomically. |
| L21 | Hardware gate | Health-gated Linux-first activation is implemented through detd or the proven lifecycle fallback; live display and input readiness needs guacamoleb qualification. |
| L22 | Complete | A failed automatic Linux-first attempt returns to phone mode and disables retry until re-enabled. |
| L23 | Complete | Online apply, disable, and emergency phone recovery commands are exposed through `det linux-first` and lifecycle helpers. |
| L24 | Hardware gate | Typed minimum-Android capabilities retain critical init, vendor HAL, radio, power, thermal, binder, and networking dependencies; the exact service floor needs live qualification. |
| L25 | Complete | Linux-first supervision no longer performs framework Wi-Fi repair unless the device capability requests it. |
| L26 | Partial | Host-agent polling uses bounded adaptive backoff and records retries; remaining platform loops are not fully event-driven. |
| L27 | Complete | Cycle stress waits for invariants and records commit, profile, timing, process identity, descriptors, and failure evidence. |
| L28 | Partial | Critical libhybris, wlroots, and phoc sources are pinned; clean-build base-image and remaining component hashes are release gates. |
| L29 | Partial | Setup wrappers now converge on one checked entrypoint and shared profile generation; some historical bootstrap scripts remain as component steps. |
| L30 | Complete | Module and USB archive builders sort entries, normalize metadata, and honor `SOURCE_DATE_EPOCH`. |
| L31 | Complete | The three drifting host setup wrappers now delegate to `run_guest_setup.sh`. |
| L32 | Complete | Active lifecycle code and comments contain no em dashes or generated-sounding filler. |

## Product and maintenance outcomes

| ID | Outcome | Result and evidence |
|---|---|---|
| P01 | Complete | README, website, and current docs distinguish concurrent external mode from time-sliced internal mode. |
| P02 | Hardware gate | Companion requests and status use structured control states with emergency fallback labels; the Android app needs a target build and device run. |
| P03 | Hardware gate | Accepted, running, committed, rolled-back, degraded, and recovery-required states are represented in the companion; UI behavior needs device validation. |
| P04 | Complete | Unsupported compositor choices were removed from active selection and cannot write active configuration. |
| P05 | Hardware gate | Presenter foreground-service startup exposes degraded state instead of reporting false readiness; Android runtime behavior needs validation. |
| P06 | Partial | Hosted CI was implemented, but GitHub refused to start jobs because the account is billing-locked. The workflow was removed rather than requiring billing; `./tools/check-host.sh` runs the same checks locally. |
| P07 | Complete | `CONTRIBUTING.md` and `SECURITY.md` define contribution, style, validation, reporting, and artifact expectations. |
| P08 | Complete | `.editorconfig`, `.gitattributes`, and repository checks define normalization and binary/generated handling. |
| P09 | Complete | Release-critical libhybris, wlroots, phoc, and HWC inputs use immutable revisions checked against manifests. |
| P10 | Release gate | The Aqua manifest exists and validates; nine clean-build, archive, patch, dependency, or signing hashes remain explicitly unresolved. |
| P11 | Complete | `docs/README.md` provides a repository-native wiki across guides, architecture, reference, operations, and history. |
| P12 | Complete | The build and package guide lists host requirements, component entrypoints, pins, and validation. |
| P13 | Complete | Install, upgrade, daily-use, recovery, backup, rollback, and known limitations have current guides. |
| P14 | Complete | The supported-device reference separates proven guacamoleb facts from portability work. |
| P15 | Complete | Device and boot-profile keys, defaults, invariants, Linux-first states, and recovery are documented. |
| P16 | Complete | Troubleshooting and qualification map failures to safe diagnostics, evidence, recovery, and device-only gates. |
| P17 | Complete | The standard-library link checker validates relative paths and local anchors through the unified host check. |
| P18 | Complete | Dated progress and reviews moved under `docs/history/` and are labeled non-authoritative. |
| P19 | Complete | Active navigation contains no stale `north-star.md` reference. |
| P20 | Complete | Active documentation and product copy were tightened, duplicated claims removed, and em dashes eliminated. |
| P21 | Complete | Current wiki pages identify status, authority, and review date. |
| P22 | Complete | Recon requires explicit target selection when needed and records the selected serial. |
| P23 | Complete | Recon preflight reports missing dependencies and records tool versions. |
| P24 | Complete | Recon records per-probe success or failure in machine-readable output. |
| P25 | Complete | Classifier fixtures cover composer, mapper, kernel, slot, and failed probe results. |
| P26 | Complete | Release checks reject malformed, missing, duplicate, inconsistent, or mismatched manifest entries. |
| P27 | Release gate | Package-content and signing checks exist; current package output and signing identity are not available in this host-only run. |
| P28 | Complete | `ARTIFACTS.md`, `artifacts/manifest.json`, and generated `artifacts/index.json` record retention, provenance, size, and hash policy. |
| P29 | Complete | Obsolete boot images and historical module ZIPs were removed from active source paths. |
| P30 | Complete | Exact duplicate evidence was removed or replaced by one canonical historical copy. |
| P31 | Complete | Oversized raw logs left the checkout and remain represented by provenance and hashes. |
| P32 | Complete | Ignore rules and the unified host policy check reject unmanifested generated or oversized artifact output. |
| P33 | Complete | Website PNGs were losslessly reduced by 13,509 bytes, a repeatable optimizer was added, and image loading attributes were tightened. |
| P34 | Complete | Site pages use consistent navigation, landmarks, keyboard-visible links, alt text, and truthful status copy. |

## Integration and publication outcomes

| ID | Outcome | Result and evidence |
|---|---|---|
| X01 | Complete | Three high-reasoning Terra agents worked in non-overlapping thirds; cross-boundary edits were reconciled by the orchestrator. |
| X02 | Complete | Control, lifecycle, Zygisk, companion, boot-profile, state-file, timeout, and fallback contracts were integrated end to end. |
| X03 | Complete | Validation ran only host-safe static checks, fixtures, and unit tests; no ADB, root, flash, partition, or device transition command ran. |
| X04 | Complete | `./tools/check-host.sh` is the single clean-checkout host validation entrypoint. |
| X05 | Complete | This report records comparable size, duration, file-count, diff, punctuation, and image metrics. |
| X06 | Complete | Changed shell files are parsed according to their declared shell, with POSIX `sh` and Bash handled separately. |
| X07 | Complete | Root authority, display ownership, profile input, PID identity, generation, rollback, and emergency fallback were reviewed and tested or marked device-gated. |
| X08 | Complete | Active files contain zero em dashes outside preserved artifacts and historical evidence, and the unified host check enforces the active-text policy. |
| X09 | Complete | This file maps every native, lifecycle, product, integration, and publication task ID. |
| X10 | Complete | Cleanup removes files from the current tree without rewriting public history. |
| X11 | Complete | The integrated scope passed final review and is committed intentionally as one implementation change after the frozen task-contract commit. |
| X12 | Complete | The branch is published and [draft pull request 1](https://github.com/kriscrossapplesauce2004/determination/pull/1) records scope, impact, validation, migration, limitations, and device gates. |

## Final host validation

Command:

```sh
./tools/check-host.sh
```

Result: passed in 13 seconds.

The entrypoint passed shell and Python syntax, recon fixtures, lifecycle
fixtures, Markdown links for 41 files, artifact-index consistency, static-site
checks, release validation, presenter protocol tests, control-plane tests, and
host compilation of `evgrab`. CMake was unavailable, so the script used its
direct C and C++ compiler fallback.

GitHub Actions is intentionally absent. GitHub refused to start the hosted job
because the project account is locked for billing, and the maintainer does not
intend to enable billing. Local validation remains complete and reproducible
without a hosted runner.

Expected release warnings remain for clean-build boot, Mesa, minigbm, LXC, HWC
archive, companion dependency, guest base, local patch, and signing hashes. The
current Magisk module package was not built in this host-only run.

## Device and release qualification still required

The following work is deliberately not claimed as verified:

- Build the Android companion in the pinned Android toolchain and validate its
  structured transition and presenter-degraded UI states.
- Run Linux-first enter, automatic fallback, explicit disable, and emergency
  restore on the supported guacamoleb/crDroid target.
- Prove the minimum Android service policy preserves radio, power, thermal,
  binder, qualified networking, suspend, wake, input, and phone recovery.
- Qualify direct ALSA ownership and restore, continuous external presentation,
  Zygisk deadline behavior, repeated cycle stress, install, upgrade, restore,
  and non-active-slot boot handling.
- Produce clean release packages, fill every required manifest hash, verify APK
  signing, and run the complete package-content checks.

These gates involve a real phone, privileged transitions, release credentials,
or final package outputs. They remain separate from automatic host validation.
