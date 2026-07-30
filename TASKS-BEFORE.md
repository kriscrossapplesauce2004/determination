# Determination Repository Overhaul: Before

Status: frozen implementation baseline  
Baseline commit: `a55c19a9a910`  
Overhaul branch: `agent/repository-overhaul`  
Audit date: 2026-07-30

## Purpose

This document records the task contract before implementation. It is intentionally
specific about scope, ownership, evidence, and validation. `TASKS-AFTER.md` will
map each task ID to its final outcome.

The work is split across three non-overlapping implementation thirds:

| Owner | Repository third |
|---|---|
| T1 | Native core: `control/`, `audio/`, `graphics/`, `audiobridge/`, `hwc2-compat/`, `tools/evgrab/` |
| T2 | Device lifecycle: `guest/`, `toggle/`, `kernel/`, `boot/`, `magisk-module/`, `zygisk/`, `usb-install/`, device profiles, and host lifecycle helpers |
| T3 | Product and maintenance: `companion/`, `website/`, `recon/`, `release/`, active documentation, CI, and repository hygiene |
| ORCH | Cross-boundary architecture, integration, final validation, task accounting, publication |

## Baseline

| Measurement | Result |
|---|---|
| Tracked files | 264 |
| Working checkout plus Git data | 339 MiB |
| Packed Git data | 119.10 MiB |
| Tracked boot images | 3 files, 288 MiB uncompressed |
| Historical module archives | 4 tracked DecemberOS ZIP files |
| Dash-style punctuation matches | 446 across 76 source/prose files |
| Release check | Passed with moving-source and missing-current-package warnings |
| Control host tests | Passed with direct C++20 compilation |
| Audio host fixtures | Passed with direct C++20 compilation |
| Graphics protocol policy test | Passed |
| Python syntax | Passed |
| CMake wrapper validation | Blocked because CMake and CTest are unavailable in the audit environment |
| Android/device validation | Not run during the host-only audit |

## Native core tasks

| ID | Priority | Task | Acceptance criteria |
|---|---:|---|---|
| N01 | P0 | Add bounded detd client receive and send deadlines | A stalled peer cannot block a concurrent ping beyond the configured RPC budget |
| N02 | P0 | Add detd connection quota and clean rejection | Excess peers are rejected without unbounded allocation or daemon starvation |
| N03 | P0 | Add slowloris and stalled-reader protocol tests | Tests cover partial headers, partial bodies, oversized packets, silent peers, and blocked response readers |
| N04 | P0 | Install both required HWC compatibility libraries | The compatibility and UI libraries are staged, verified, and activated as one complete set |
| N05 | P1 | Continuously drain adapter output after the capture limit | A verbose adapter can exit normally after more than 1 MiB of output and reports truncation |
| N06 | P1 | Give adapters a minimal explicit environment | Hostile inherited variables do not reach adapter processes |
| N07 | P1 | Make adapter timeout teardown cover descendants | Timed-out process groups are terminated and no helper remains running |
| N08 | P1 | Serialize audio claim, restore, and recovery | One exclusive lock protects the complete audio ownership transaction |
| N09 | P1 | Add audio generation and owner identity to the journal | Stale or concurrent ownership records are detected without corrupting recovery |
| N10 | P1 | Add concurrent audio ownership fixture tests | Claim, restore, recovery, and killed-helper races have deterministic outcomes |
| N11 | P1 | Add presenter session state and buffer quotas | Duplicate IDs, excessive buffers, excessive pixel counts, and invalid lifecycle operations are rejected |
| N12 | P1 | Validate presenter serials, fences, completions, and teardown | Out-of-order or mismatched completion data cannot leak descriptors or corrupt session state |
| N13 | P1 | Add host presenter lifecycle tests | Tests cover malformed ancillary data, duplicate registration, quota limits, callback cleanup, and FD balance |
| N14 | P1 | Separate admin and guest endpoint authority | Policy tests cover every operation, endpoint, and peer identity combination |
| N15 | P2 | Extract Android-specific control behavior behind adapters | Core state, policy, protocol, journal, and transition logic compile and run on the host without Android headers |
| N16 | P2 | Move Android service and path constants out of neutral logic | Validated platform configuration supplies paths, process names, and Android identities |
| N17 | P2 | Emit structured guest health in observability JSON | Guest reports are objects or null, and unavailable/error/value states are distinct |
| N18 | P2 | Add golden observability schema tests | Phone, desktop, absent guest, audio failure, and presenter failure snapshots are validated |
| N19 | P2 | Add supervised foreground mode to evgrab | The parent receives readiness, owns lifecycle, and can detect startup failure |
| N20 | P2 | Make evgrab discovery deterministic and profile-driven | Input nodes are sorted and selected from an explicit directory and allowlist |
| N21 | P2 | Make evgrab pidfile handling atomic and identity-aware | Stale files and reused PIDs cannot target an unrelated process |
| N22 | P2 | Add evgrab host discovery and lifecycle tests | Injectable directory and ioctl behavior covers success, partial failure, cleanup, and parent loss |
| N23 | P2 | Add control transition fault-injection coverage | Every journal/write boundary resolves to PHONE or explicit RECOVERY |
| N24 | P2 | Pin and verify HWC build inputs | Immutable revisions, HTTPS sources, checksums, device fingerprints, and library hashes are recorded |
| N25 | P2 | Isolate HWC patching and build outputs | Upstream source is not mutated in place and stale device libraries cannot enter the link |
| N26 | P2 | Emit a compatibility build manifest | Inputs, outputs, hashes, SONAMEs, and the device contract are machine-readable |
| N27 | P3 | Remove the dead AAudio bridge and tracked binary | No operational consumer remains and history notes the retired experiment |
| N28 | P3 | Deslopify native comments and prose | No dash-style punctuation or vague speculative comments remain in the owned third |

## Device lifecycle tasks

| ID | Priority | Task | Acceptance criteria |
|---|---:|---|---|
| L01 | P0 | Fix the SurfaceFlinger suppressor startup race | Durable mode state exists before the helper can inspect it and helper liveness is verified |
| L02 | P0 | Add one transition lock and generation | Enter, exit, guest start, boot apply, and host requests cannot race |
| L03 | P0 | Make recorded PIDs identity-aware | PID, process start time, boot ID, role, and generation are verified before signaling |
| L04 | P0 | Prevent phone restoration while a compositor still owns display resources | Exit escalates safely and reaches RECOVERY instead of starting SurfaceFlinger against an ambiguous owner |
| L05 | P0 | Restrict the guest root command surface | Routine mode exit uses the capability RPC and privileged power actions require explicit authority |
| L06 | P1 | Make desktop entry a bounded transaction | Every step has a deadline, structured result, and reverse rollback |
| L07 | P1 | Keep an independent emergency phone restore path | Emergency recovery remains usable when detd or the guest is unavailable |
| L08 | P1 | Replace shell-sourced device profiles with typed parsing | Unknown keys, injection, invalid paths, invalid enums, and invalid numeric values are rejected |
| L09 | P1 | Add device-profile fixtures and golden output tests | Valid and invalid profiles produce deterministic LXC and guest configurations |
| L10 | P1 | Make generated configuration atomic and private | Per-run temporary files are mode-restricted, validated, and atomically renamed |
| L11 | P1 | Serialize config and manifest generation | Concurrent generation cannot produce mismatched or partial results |
| L12 | P1 | Add socket deadlines and framing to the Zygisk bridge | Slow or partial clients cannot block the bridge indefinitely |
| L13 | P1 | Make detd the routine Zygisk request path | Accepted, running, committed, rolled-back, and recovery states replace immediate legacy success |
| L14 | P1 | Create logging directories before redirection | First boot and fresh install logs are preserved |
| L15 | P1 | Bound Magisk boot-completion waiting | Timeout records a degraded or recovery disposition instead of polling forever |
| L16 | P1 | Stage module payloads as versioned complete sets | Installation verifies compatibility and hashes before atomic activation |
| L17 | P1 | Retain one known-good module payload | Interrupted activation and a bad new payload can roll back |
| L18 | P1 | Share boot-image candidate validation | Host and action-zip paths choose the same newest valid image and explain rejected candidates |
| L19 | P1 | Validate restore inputs before any write | Boot magic, partition fit, target slot, and hash are checked |
| L20 | P2 | Add a typed persistent Linux-first boot profile | Desired profile, generation, previous known-good state, attempt count, deadline, and result are atomic |
| L21 | P2 | Apply Linux-first through detd after guest health gates | Linux becomes primary only after LXC, session, display, and input readiness are confirmed |
| L22 | P2 | Automatically fall back to phone mode after a failed Linux-first attempt | One failed automatic attempt disables retry until explicitly re-enabled |
| L23 | P2 | Add explicit Linux-first recovery commands | Online and offline recovery paths force phone mode safely |
| L24 | P2 | Define the minimum Android service policy as typed capabilities | The first profile retains init, required vendor HALs, radio, power, thermal, binder, and qualified networking |
| L25 | P2 | Remove unnecessary Android framework repair from guest supervision | Linux-first does not invoke framework Wi-Fi repair unless a device capability explicitly requires it |
| L26 | P2 | Replace fixed polling with events or adaptive backoff | Idle wakeups from SF, network, backlight, and host-agent loops are reduced and observable |
| L27 | P2 | Upgrade cycle stress into a qualification recorder | It waits for state invariants and emits commit, profile, timing, descriptor, process, and failure evidence |
| L28 | P2 | Pin guest construction inputs | Debian source, repository keys, libhybris, wlroots, and phoc inputs have immutable identities and checksums |
| L29 | P2 | Consolidate duplicate guest bootstrap paths | One declarative profile drives rootfs construction and on-device setup |
| L30 | P2 | Make module and USB archives reproducible | Sorted entries, fixed metadata, and `SOURCE_DATE_EPOCH` produce identical hashes |
| L31 | P3 | Consolidate stale host wrappers | One checked helper replaces the three drifting setup wrappers |
| L32 | P3 | Deslopify lifecycle code and comments | No dash-style punctuation or generated-sounding filler remains in owned active files |

## Product and maintenance tasks

| ID | Priority | Task | Acceptance criteria |
|---|---:|---|---|
| P01 | P0 | Correct public claims about Android availability | Website and active docs distinguish concurrent external mode from time-sliced internal mode |
| P02 | P0 | Make companion state authoritative | Routine status and mode changes use the structured control path, with emergency fallback clearly labeled |
| P03 | P0 | Show transition progress and recovery states | The app distinguishes accepted, running, committed, rolled-back, degraded, and recovery-required |
| P04 | P0 | Remove unsupported compositor choices | Only working sessions are selectable and roadmap sessions cannot write active configuration |
| P05 | P0 | Surface presenter foreground-service failure | The UI cannot report an external presenter as ready after degraded startup |
| P06 | P0 | Add continuous integration | CI runs release checks, syntax checks, native tests, Python validation, documentation checks, and repository policy checks |
| P07 | P0 | Add contributor and security guidance | Contribution, reporting, style, and artifact expectations are discoverable |
| P08 | P0 | Add editor and text normalization policy | Line endings, final newlines, whitespace, and generated/binary handling are explicit |
| P09 | P0 | Pin release-critical sources | Release checks find no moving source references for the current release train |
| P10 | P0 | Add the current Aqua release manifest | Immutable source identities and expected hashes are recorded and validated |
| P11 | P1 | Create a repository-native documentation wiki | A documentation home links task guides, architecture, reference, operations, and history |
| P12 | P1 | Add task-first build and package guidance | A new contributor can identify supported host requirements and build entrypoints |
| P13 | P1 | Add install, upgrade, daily-use, and recovery guides | Risk, backup, rollback, and known limitations are prominent and consistent |
| P14 | P1 | Add a supported device and ROM reference | Proven facts and unverified portability claims are clearly separated |
| P15 | P1 | Add device-profile and boot-profile reference | Typed keys, defaults, invariants, and Linux-first behavior are documented |
| P16 | P1 | Add troubleshooting and qualification references | Common failures map to safe diagnostics and recovery, with device-only gates identified |
| P17 | P1 | Add a standard-library Markdown link checker | Relative paths and local heading anchors are checked locally and in CI |
| P18 | P1 | Move dated reports and reviews into history | Historical material is visibly non-authoritative and absent from current instruction paths |
| P19 | P1 | Remove stale `north-star.md` references | Active and historical navigation contains no broken references |
| P20 | P1 | Deslopify active documentation and product copy | Active prose contains no dash-style punctuation, vague filler, duplicated claims, or stale grandiosity |
| P21 | P1 | Add authority and review metadata to active wiki pages | Readers can tell current instructions from evidence and historical commentary |
| P22 | P2 | Add explicit ADB target selection to recon | Multiple devices cannot be addressed accidentally and the selected serial is recorded |
| P23 | P2 | Add recon dependency and version preflight | Missing tools fail clearly and captured reports record tool versions |
| P24 | P2 | Record per-probe recon success or failure | Partial reports remain machine-readable and explain unavailable evidence |
| P25 | P2 | Add recon classifier fixtures | Representative reports cover composer, mapper, kernel, slot, and failure classification |
| P26 | P2 | Validate release manifest schema and hashes | Missing, malformed, duplicated, or mismatched entries fail release checks |
| P27 | P2 | Validate package contents and signatures | Ship checks inspect checksums, expected archive contents, and APK signing state |
| P28 | P2 | Add a tracked artifact manifest and retention policy | Each retained artifact has purpose, provenance, hash, size, and retention class |
| P29 | P2 | Remove obsolete boot images and historical module ZIPs from the working tree | Operational source paths contain no obsolete release-like binaries |
| P30 | P2 | Remove exact duplicate evidence files | One canonical copy remains with updated references |
| P31 | P2 | Remove or externalize oversized raw logs | Curated evidence remains, while raw logs are represented by provenance and hashes |
| P32 | P2 | Prevent accidental generated artifact commits | Ignore and CI policy reject unmanifested large or generated outputs |
| P33 | P3 | Optimize website images and loading behavior | Image bytes and unnecessary initial work decrease without visible regression |
| P34 | P3 | Improve website navigation, semantics, and accessibility | Pages have consistent navigation, landmarks, keyboard behavior, contrast, and truthful status |

## Integration and publication tasks

| ID | Priority | Task | Acceptance criteria |
|---|---:|---|---|
| X01 | P0 | Preserve non-overlapping ownership during parallel implementation | Agent edits remain within assigned thirds unless ORCH explicitly coordinates an interface |
| X02 | P0 | Reconcile control, lifecycle, Zygisk, and companion interfaces | Protocol versions, states, permissions, timeouts, and fallback behavior agree end to end |
| X03 | P0 | Keep hardware-only actions out of host validation | No ADB, root, flash, partition, or live-device mutation occurs without a separate qualification run |
| X04 | P1 | Add one host validation entrypoint | A clean checkout can run every available static and unit check with one command |
| X05 | P1 | Measure before and after test duration and repository size | `TASKS-AFTER.md` records comparable commands and results |
| X06 | P1 | Review every changed shell script for shell dialect | Files are parsed with the interpreter declared by their shebang |
| X07 | P1 | Review security boundaries and recovery invariants | Display ownership, root authority, profile input, PID identity, and fallback behavior have tests or explicit device gates |
| X08 | P1 | Verify active prose has no dash-style punctuation | A repository check enforces the requested style in active files |
| X09 | P1 | Produce `TASKS-AFTER.md` | Every task ID is completed, partially completed, deferred with reason, rejected with reason, or hardware-gated |
| X10 | P1 | Keep history rewriting outside this change | Working-tree cleanup lands without silently rewriting public Git history |
| X11 | P1 | Commit the integrated scope intentionally | The final diff contains no unrelated or generated local changes |
| X12 | P1 | Publish an overhaul branch and draft pull request | The PR explains changes, user impact, validation, limitations, migration, and device qualification gates |

## Safety and scope boundaries

Host-side code, documentation, tests, static checks, packaging checks, and
deterministic fixtures are in scope for automatic execution. Live device
handoff, service suppression, flashing, partition writes, and recovery drills
remain explicit hardware qualification gates. Code for those gates may be
implemented and host-tested here, but a result is not marked device-verified
without evidence from the actual target.

Public history rewriting is not part of this overhaul. Removing large tracked
files improves new checkouts only after a future history rewrite; the current
change will record the size distinction accurately.
