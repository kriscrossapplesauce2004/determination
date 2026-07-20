# Determination platform overhaul

**Status:** execution plan, started 2026-07-20  
**Scope:** the platform after the OnePlus 7 internal-desktop proof  
**Rule:** every phase must leave a recoverable phone, useful evidence, and an
honest compatibility claim.

This is the plan for turning Determination from a remarkably capable collection
of device-bring-up tools into a maintainable convergence platform. It is
deliberately larger than the Aqua release checklist. Aqua may cut from a stable
point while later phases continue.

The plan does not discard the hacks which proved the architecture. It puts an
owner, protocol, tests, limits, and rollback path around them, then replaces
them only when the replacement has passed the same hardware gate.

## 1. Product invariants

These are not negotiable during the overhaul:

1. Android remains PID 1. Determination is not a ROM and does not modify
   `/system` or `/vendor`.
2. Phone mode is the recovery baseline. After a crash, failed update, dead
   guest, or interrupted transition, the system must either reach phone mode or
   explicitly request a reboot into phone mode.
3. Vendor EGL/GLES through libhybris is the compatibility renderer. Native
   Mesa is an opt-in, device-proven optimisation and diagnostic path.
4. Android gralloc owns compatibility buffers. Full native handles and sync
   fences are part of the contract; a single dma-buf fd is not.
5. Internal-panel mode may freeze and replace `system_server` for Aqua. That is
   a scoped compromise, not the final live-Android convergence architecture.
6. External convergence keeps Android, SurfaceFlinger, SystemUI, telephony, and
   the internal panel alive.
7. The desktop session runs unprivileged. Root is a narrow host capability, not
   the desktop's normal identity.
8. Apps never receive arbitrary root-shell access. Privileged operations are
   named, versioned, authenticated, bounded, logged, and independently
   authorisable.
9. Android owns Android display colour state. Determination must not force a
   Night Light temperature, saturation, colour matrix, or display colour mode.
   Desktop colour management is opt-in and session-local; transition code may
   observe Android state but must not rewrite it.
10. A profile field is not portability. A capability becomes public only after
    every consumer uses it and a real device branch exercises it.
11. Notifications are not the product's primary control surface. Prefer Quick
    Settings, launcher shortcuts, share targets, display events, intents, and
    explicit in-app controls.
12. Every dangerous operation has a deadline, a journal entry, and a rollback
    or recovery action.
13. Determination services do not depend on Android framework/media services
    for their core function. In particular, product audio uses direct hardware
    access, not AudioFlinger, AAudio, or a companion-app PCM bridge. Android
    services may be observed or explicitly arbitrated, but they are not the
    desktop service substrate.

## 2. Definition of success

The overhaul is successful when all of these are true:

- one daemon owns desired mode, observed mode, transitions, recovery, and the
  privileged device API;
- `det`, the companion app, the guest session, Quick Settings, and automation
  all use the same versioned API;
- killing any client does not abandon a transition or leave display ownership
  ambiguous;
- a reboot during ENTERING, DESKTOP, EXITING, or RECOVERY reconciles to PHONE;
- `det doctor --json` explains the system without depending on a responsive
  Android framework;
- the shell transition implementation is an adapter behind the daemon, then is
  reduced step by step as native replacements prove themselves;
- external DP-alt convergence shows guest frames through an Android presenter,
  returns input, survives hotplug, and never stops SurfaceFlinger;
- guest audio reaches the hardware directly with measured latency, working
  routing and volume controls, bounded buffering, and independent lifetime;
- installation, upgrade, rollback, and restore are reproducible from a clean
  checkout;
- the supported-device statement is generated from passed capability gates,
  not aspiration;
- a failed feature degrades to a working phone instead of a black panel.

Initial quantitative targets:

| Area | Target |
|---|---:|
| Enter internal desktop, warm guest | p95 under 6 s |
| Exit to interactive Android | p95 under 5 s |
| Control RPC, read-only request | p99 under 20 ms |
| Daemon idle RSS | under 12 MiB |
| Daemon idle wakeups | under 1 per 10 s |
| Direct audio round-trip latency | under 25 ms initially, under 15 ms stretch |
| External presenter steady buffers | 3 per output, hard maximum 6 |
| Presenter queued frames | maximum 2 |
| Enter/exit qualification | 50 consecutive cycles, zero ambiguous states |
| Soak | 8 h with suspend/wake, media, browser, SSH, and cable events |
| Recovery | PHONE or explicit reboot-required within 30 s |

## 3. Target architecture

```text
 Android app / QS tile / shortcuts      host det CLI       guest session
                 |                           |                    |
                 +-------- versioned local RPC ------------------+
                                             |
                                      detd (root, bionic)
                               state owner / policy / journal
                                  /          |          \
                         transition     guest/lxc      services
                          adapters       lifecycle   audio/presenter
                              |              |            |
                        SF + input +     Debian PID1    Android APIs
                        HWC ownership      + agents     and DP display
```

The important boundary is not “C++ good, shell bad.” `detd` owns state and
transactions. Small scripts may remain as leaf adapters where Android's toolbox
already expresses the operation clearly. No script may independently decide
the global mode once the daemon is authoritative.

### 3.1 Native components

| Component | Responsibility | Privilege |
|---|---|---|
| `detd` | state machine, RPC, policy, journal, recovery, service supervision | root host daemon |
| `detctl` | stable CLI and machine-readable client | caller's identity; no implicit escalation |
| `det-guest-agent` | guest health/events and a tiny capability-scoped host command bridge | uid 1000 in guest |
| `det-audiod` | hardware ownership, codec/route policy, metrics and recovery | root host control plus unprivileged guest API |
| `det-presenterd` | Android display presenter lifecycle and protocol policy | Android app/service boundary |
| `det-recond` or `det probe` | capability collection with a stable schema | read-only root where required |
| `det-watchdog` | optional minimal boot recovery if the main daemon cannot start | root, no feature policy |

`detd`, `detctl`, and `det-guest-agent` are the first three replacements. The
others are separate workstreams and must not be coupled merely to share a
long-lived process.

### 3.2 Filesystem contract

```text
/data/determination/
  bin/                 deployed binaries and compatibility adapters
  etc/                 validated persistent configuration
  libexec/             private transition/service adapters
  log/                 rotated human-readable logs
  run/                 boot-local sockets, pidfiles and observed state
  state/               durable desired state and transition journal
  metrics/             bounded snapshots, not append-forever telemetry
  versions/            staged atomic component sets
  current -> versions/<manifest-id>
```

`run/` is always cleared at boot. `state/` survives boot and is reconciled.
Deployments are staged under `versions/`, validated, then switched by one
atomic symlink. The previous complete version remains available for rollback.

## 4. Control-plane replacement

### 4.1 State model

The authoritative mode state machine is:

```text
            +-----------------------------+
            v                             |
PHONE -> ENTERING -> DESKTOP -> EXITING -> PHONE
  ^          |           |          |        ^
  |          +-----------+----------+        |
  |                      v                   |
  +------------------ RECOVERY --------------+
```

External convergence is an orthogonal output state, not another phone mode:

```text
external = DISCONNECTED | CONNECTING | PRESENTING | DEGRADED | STOPPING
```

Audio is also orthogonal:

```text
audio = DISABLED | STARTING | RUNNING | XRUN | RECOVERING | FAILED
```

Each state record contains:

- schema version and boot ID;
- monotonically increasing generation;
- desired and observed state;
- transition owner, start time, deadline, and current step;
- completed journal steps in order;
- last error class, errno/exit status, and bounded diagnostic text;
- recovery disposition: retry, rollback, phone-safe reboot, or manual action;
- component build manifest and device-profile digest.

Only `detd` writes authoritative state. Marker files remain temporary
compatibility outputs for old Zygisk and shell consumers.

### 4.2 Transition semantics

Every transition:

1. authenticates and authorises the request;
2. acquires the global transition lock;
3. rejects or coalesces conflicting desired states;
4. snapshots observations which are safe to read;
5. writes ENTERING or EXITING plus a generation to the durable journal;
6. executes named idempotent steps with monotonic deadlines;
7. records each completed step before beginning the next;
8. verifies the final observed invariants;
9. commits DESKTOP or PHONE;
10. on failure, rolls back completed steps in reverse order;
11. enters RECOVERY if rollback cannot establish a safe state;
12. never waits forever for framework services, a compositor, or a child.

The first implementation calls the proven `desktop-on`, `desktop-off`, and
`guest-start` adapters. Subsequent waves extract their operations into named
steps. This changes ownership before changing hardware behaviour.

### 4.3 RPC protocol

Version 1 uses `AF_UNIX SOCK_SEQPACKET`, bounded binary headers, UTF-8 payloads,
and optional fd passing only for commands which explicitly allow it. It avoids
newline framing ambiguity and makes malformed-message tests straightforward.

Required header fields:

- magic, protocol major/minor, header size, payload size;
- request ID, operation, flags, deadline;
- response status, stable error code, server generation;
- maximum fd count declared by the operation.

Initial operations:

- `HELLO`, `PING`, `CAPABILITIES`;
- `STATUS`, `DOCTOR`, `METRICS_SNAPSHOT`, `LOG_TAIL`;
- `MODE_GET`, `MODE_SET`, `MODE_RECOVER`;
- `GUEST_START`, `GUEST_STOP`, `GUEST_RESTART`;
- `SERVICE_LIST`, `SERVICE_RESTART` for named services only;
- `CONFIG_GET`, `CONFIG_VALIDATE`, `CONFIG_SET` for schema-known keys;
- `FILE_IMPORT` through an already-open fd, never an arbitrary host path;
- `POWER_REBOOT`, `POWER_OFF` with interactive-authorisation metadata;
- `SUBSCRIBE` for bounded state/event updates.

There is no `EXEC`, shell string, arbitrary path write, arbitrary signal, or
arbitrary Android property operation.

### 4.4 Authentication and policy

- The daemon obtains peer identity with `SO_PEERCRED` and labels requests with
  pid, uid, gid, process start time, and socket endpoint.
- Root and the host CLI have the administrative policy.
- The companion reaches the daemon through the existing same-UID Zygisk app
  bridge and Magisk root companion. The root companion forwards structured
  messages, not shell strings.
- The guest endpoint exposes a smaller allowlist: status, exit desktop,
  session logout/reboot/poweroff requests, audio readiness, presenter readiness,
  and health events.
- File modes are defence in depth, not authentication.
- Every mutating operation is audit logged with peer, request ID, old desired
  state, new desired state, result, and duration.
- Rate, connection, request-size, fd, and outstanding-work quotas are enforced
  before allocation.

### 4.5 Compatibility migration

1. Ship daemon and CLI dark; `detctl ping` and `status` only.
2. Let daemon observe markers without owning transitions.
3. Make daemon authoritative while it launches old transition scripts.
4. Move companion and host `det` commands to the API with old paths as fallback.
5. Replace `det-hostagent` with `det-guest-agent`.
6. Extract transition steps from scripts into daemon-owned adapters.
7. Remove direct companion `su` calls command by command.
8. Retain an offline `desktop-off --emergency` recovery adapter which does not
   depend on the daemon.
9. Delete an old path only after device qualification proves the new one and
   rollback installation is tested.

## 5. Replacement one: `detd`

Initial implementation slice:

- small C++20 bionic binary with no runtime dependency outside Android libc++;
- single event loop plus a bounded worker queue;
- signal-safe shutdown and child reaping;
- lock file using `flock`, socket created with controlled umask;
- atomic state writes using write, `fsync`, rename, and parent-directory
  `fsync` for durable commits;
- monotonic clocks for deadlines; wall clock only for presentation;
- boot reconciliation of stale ENTERING/EXITING/DESKTOP journals;
- read-only health probes which do not call `dumpsys` in internal mode;
- adapter runner with fixed executable paths, fixed argv, clean environment,
  process group, stdout/stderr capture, timeout, TERM grace, then KILL;
- graceful degradation if the daemon is from a newer/older module version;
- host-buildable core so parser/state tests run without a phone.

Native extraction order after ownership is proven:

1. marker and pidfile lifecycle;
2. bounded process supervision;
3. input-grab handoff state;
4. SurfaceFlinger observation and start/stop adapters;
5. compositor and session supervision;
6. backlight restore/keeper policy;
7. system_server freezer/respawn observation;
8. boot animation completion;
9. final invariant checks and rollback.

Hardware-specific sysfs operations stay capability adapters rather than being
compiled as OnePlus constants.

## 6. Replacement two: `detctl` and app API

`detctl` is both a human CLI and a reference protocol client:

```text
detctl status [--json]
detctl doctor [--json]
detctl mode phone|desktop [--wait] [--deadline 30s]
detctl recover [--wait]
detctl guest start|stop|restart
detctl service list|restart <known-name>
detctl events [--json-lines]
detctl capabilities [--json]
```

Exit codes are stable: success, rejected, unavailable, deadline, degraded,
recovery-required, protocol mismatch, and internal error. Human text is never
the machine contract.

Companion migration:

- `ZygiskBridge` negotiates protocol version and forwards structured requests;
- `Root.status()` becomes one daemon status call rather than a shell program;
- enter/exit/recover/guest lifecycle use request IDs and state subscriptions;
- share-sheet import sends a content fd plus a sanitised display name;
- power actions require an explicit app confirmation token;
- UI shows accepted, running, committed, rolled back, or recovery-required;
- old module support remains through a version-gated fallback during migration;
- no feature depends on a notification merely to keep the control API alive.

Third-party app API:

- start with explicit Android intents for read-only status and user-mediated
  mode requests;
- add a signature-permission Binder facade in the companion only after the
  daemon protocol is stable;
- expose capability queries, subscriptions, file handoff, and display/session
  requests, not root implementation details;
- never let an arbitrary app silently stop SurfaceFlinger or power off the
  device;
- publish protocol and permission documentation with examples and deprecation
  policy.

## 7. Replacement three: `det-guest-agent`

The native guest agent replaces the inotify command file and scattered helper
signals.

Responsibilities:

- connect to the guest-scoped daemon endpoint with reconnect backoff;
- publish guest boot ID, init pid, session uid, compositor socket, session bus,
  audio, presenter, SSH, DNS, and memory health;
- request only named host actions allowed to the guest;
- subscribe to desired session state and configuration changes;
- supervise guest user services where systemd/logind cannot express the host
  relationship cleanly;
- provide a local D-Bus facade for session-manager, power, volume, display, and
  file-handoff clients;
- buffer a small number of events across transient disconnects and drop old
  telemetry rather than growing without bound;
- include a heartbeat without waking the phone excessively.

Migration maps existing commands exactly before adding new ones:

| Old control-file command | New operation |
|---|---|
| `exit` | `MODE_SET phone` |
| `reboot` | user-confirmed `POWER_REBOOT` |
| `poweroff` | user-confirmed `POWER_OFF` |
| wake/session events | typed guest health/event messages |

The old `det-hostagent` remains an emergency fallback for one release and logs
when it is used.

## 8. Observability and recovery

`det doctor --json` must work while system_server is frozen. It reports:

- build manifest, protocol versions, boot ID, uptime, kernel, profile digest;
- desired/observed internal and external mode;
- transition generation, owner, age, step, deadline, and journal;
- daemon, guest init, LXC monitor, compositor, shell, seatd, audio, presenter,
  SurfaceFlinger, system_server, zygote, and host-agent health;
- pid state and namespace identifiers without depending on process names alone;
- display nodes, known connector state, Android display IDs when available,
  chosen render/allocation/presentation paths, and last fence timings;
- bridge interface, routes, forwarding, DNS, SSH, packet loss, and reconnects;
- memory available, per-component RSS/PSS where safe, zram, PSI, faults, kills;
- battery gauge source, charger nodes, capacity, voltage, thermal summary;
- last failure, rollback outcome, relevant bounded log tails, and suggested
  recovery command;
- warnings when source, module, app, guest, and kernel manifests disagree.

Logs use structured records internally and readable rendering externally.
Rotation is by size and generation. Secrets, share paths, SSH material, and
buffer contents are never logged.

Recovery ladder:

1. retry the current idempotent observation;
2. restart the failed leaf service;
3. restart compositor/session while retaining display ownership;
4. reverse the transition journal to phone mode;
5. run the independent emergency phone restore;
6. mark reboot-required and ask Android/Magisk to reboot;
7. on the next boot, boot recovery clears volatile state before normal launch.

## 9. Performance programme

Performance work follows measurement, not vibes.

### 9.1 Baselines

Capture in PHONE, ENTERING, DESKTOP, EXITING, and external PRESENTING:

- transition step durations and critical path;
- CPU frequency/residency, scheduler pressure, wakeups, thermal zones;
- process PSS/RSS, dmabuf totals, KGSL memory, zram and PSI;
- frame production, latch, present and release-fence latency;
- compositor missed frames and buffer-pool occupancy;
- audio capture/write/play timestamps, queue depth, xruns and drift;
- bridge throughput, latency, packet loss and DNS response time;
- battery discharge over comparable screen-on workloads.

### 9.2 Optimisation rules

- Polling becomes event-driven where the kernel or service exposes an event.
- Remaining polls use monotonic deadlines and adaptive backoff.
- No `lxc-attach` per status refresh; agents publish health once.
- No shell process per companion poll; one RPC returns a coherent snapshot.
- Buffers are pooled; native-handle and minigbm imports do not happen per frame.
- Explicit fences replace `glFinish` in production paths.
- Copy fallback is permitted and measured; “zero-copy” is not allowed to mean
  “occasionally corrupt.”
- Service lifetimes are independent so disabling audio cannot disable display.
- Idle services must demonstrate low wakeups or shut down on demand.
- Optimisations carry a capability gate and an easy compatibility fallback.

## 10. External convergence

### 10.1 Presenter hardening before first product frame

- separate presenter lifetime from `AudioBridgeService`;
- handle same-display mode, size, density, refresh, rotation, and HDR changes;
- check `SO_PEERCRED` plus endpoint ownership;
- cap clients, registered buffers, dimensions, allocation bytes, fds, queued
  presents, and outstanding callbacks;
- validate AHardwareBuffer metadata against protocol declarations;
- make connection, surface, buffer, transaction callback, and fence ownership
  explicit under disconnect and teardown;
- implement backpressure and dropped-frame accounting;
- unregister buffers and release every fence deterministically;
- make presenter death and DP unplug recover without killing the guest session;
- fuzz packet parsing and fd combinations on the host where possible.

### 10.2 First-frame gate

Build a tiny guest producer before touching KWin:

1. connect and negotiate;
2. allocate three Android-gralloc buffers;
3. register complete native handles;
4. render unmistakable colour bars and a changing sequence number with vendor
   GLES;
5. submit acquire fences;
6. receive present and release fences;
7. pace to display feedback;
8. survive presenter restart and cable unplug/replug;
9. record end-to-end timings and buffer ownership;
10. leave Android internal display untouched.

### 10.3 Product integration

- add a presenter output backend to the compositor abstraction;
- start with a nested full-desktop surface, then direct output integration;
- return keyboard, mouse, touch, wheel, and hotplug events through a constrained
  uinput/input protocol;
- map display density and scale intentionally rather than cloning phone DPI;
- support lid-like summon/hide semantics, not destructive mode toggles;
- offer per-display session persistence and window restore;
- degrade to internal desktop or phone without a reboot if DP disappears.

## 11. Audio

Audio is an independent product boundary.

### 11.1 Contract

- PipeWire remains the guest graph and app-facing API.
- Product playback and capture use direct kernel/hardware interfaces exposed to
  the guest: ALSA PCM/control/compress nodes, tinyalsa-compatible controls, and
  device-specific codec/routing adapters where ordinary ALSA UCM is
  insufficient.
- AudioFlinger, AAudio, audioserver and the companion app are not in the PCM
  path. The existing AAudio/app bridges are experiments and migration evidence,
  not the product architecture.
- Internal desktop mode has explicit audio-owner arbitration, just like display
  ownership: quiesce Android audio, verify device release, hand the required
  `/dev/snd` nodes and route controls to PipeWire, then reverse the journal on
  exit before Android audio resumes.
- External concurrent mode prefers independent direct outputs such as DP/HDMI,
  USB audio or a directly managed Bluetooth backend. A phone-codec path which
  cannot be safely shared is advertised as unavailable or requires an explicit
  ownership handoff; it does not silently tunnel through Android.
- A small privileged `det-audiod` owns only hardware arbitration and
  device-specific route operations. PCM stays in PipeWire whenever the kernel
  interface permits it.
- ALSA UCM2 profiles and capability probes describe mixers, codecs, jacks,
  speakers, microphones, HDMI/DP, USB and Bluetooth routes. Hard-coded mixer
  incantations remain device-profile quirks until proven as a class.
- Buffers are fixed-size and latency-bounded; overflow/xrun recovery never
  grows memory without bound.
- Hardware clocks, PipeWire quantum and drift are measured directly.
- Silence detection may idle hardware without destroying the PipeWire graph.
- Calls, alarms and Android ownership conflicts are explicit policy states.

### 11.2 Delivery waves

1. inventory `/dev/snd`, ALSA cards/PCMs/controls, mixer state, codec services,
   Audio HAL ownership and kernel driver topology without changing routes;
2. capture Android's working route state, stop/quiesce Android audio, prove a
   direct tinyalsa/ALSA tone, and restore Android exactly;
3. generate the first guacamoleb UCM2/profile and play normal PipeWire apps
   through `pipewire-pulse` with no app bridge;
4. move volume-key events through the guest control/input path and show desktop
   OSD feedback without calling Android media services;
5. add speaker, wired, DP/HDMI, USB and directly supported Bluetooth routes;
6. qualify suspend/wake, route disconnect, xruns, daemon death, failed handoff
   and reverse-order restore;
7. add microphone capture with a hardware privacy indicator and explicit
   enablement;
8. define honest policy for calls/alarms when internal mode owns the codec, and
   capability reporting for external concurrent routes.

The presenter never depends on audio being enabled. Audio never owns the
control plane. No Android foreground service is required for core audio.

## 12. Portability and compatibility

Recon grows into a schema-versioned capability compiler:

- identity aliases and build fingerprint;
- boot, vendor_boot, init_boot and slot layout;
- kernel namespace, cgroup, binder, seccomp, net, checkpoint and graphics
  feature decisions;
- HIDL/AIDL composer family and mapper/allocator versions;
- vendor EGL/GLES loadability and gralloc handle structure;
- DRM nodes and connector topology as optional diagnostics;
- display geometry, density, rotation, cutout and refresh modes;
- input nodes, udev properties, Android AIDs and grab behaviour;
- backlight and power-supply candidates with confidence/evidence;
- network and tethering topology;
- ALSA topology, Audio HAL ownership, codec/mixer routes, UCM suitability and
  direct-hardware arbitration constraints;
- SELinux denials grouped by attempted capability;
- quirk classes keyed by kernel, GPU blob, composer, display driver and ROM.

Generated outputs include a validation report, kernel decision, device config,
LXC device list, guest config, graphics environment, install manifest, and the
exact gates still required. Hand-written profiles override only evidence-backed
exceptions.

The next supported phone must be deliberately hostile: AIDL composer or GKI,
another GPU family, or a different boot layout. It goes through recon, kernel,
packaging, guest, graphics, input, transition, recovery, upgrade, and restore.

## 13. Security hardening

Threat models cover malicious Android apps, guest apps, compromised desktop
processes, network peers, malformed native handles, and partial updates.

Required controls:

- enumerate every exposed device node and why it is required;
- replace broad world-rw changes where a stable uid/gid or fd handoff works;
- peer credentials and operation policy on every Unix socket;
- quotas before receiving or importing resources;
- fd type validation where practical (`sync_file`, dma-buf, regular file);
- path-free file transfer using opened fds;
- fixed argv and environment for privileged child processes;
- no shell command crossing a trust boundary;
- privilege separation for presenter, audio, recon and transition work;
- signed component manifest and atomic update switch;
- security audit log with bounded retention;
- documented trusted-guest assumption until containment proves otherwise.

## 14. Testing and qualification

### 14.1 Host tests

- protocol encode/decode and version negotiation;
- malformed/truncated/oversized packets and ancillary fd cases;
- state transition, coalescing, conflict and reconciliation tests;
- journal crash points between every write/rename/fsync;
- reverse-order rollback and recovery escalation;
- configuration parse/validation and generated fixtures;
- fake process adapter timeouts, signals and output caps;
- presenter quotas, lifecycle and fence ownership;
- ALSA/PipeWire quantum, ring-buffer, xrun, route-journal and drift control;
- shell syntax and packaging manifest checks;
- reproducible archives and clean-checkout builds.

### 14.2 Device tests

- read-only daemon dark launch and restart;
- 50 internal enter/exit cycles;
- kill daemon, adapter, evgrab, phoc, phosh, host/guest agent and LXC init at
  selected journal steps;
- reboot at every authoritative state;
- DP unplug during connect, registration, present and callback;
- presenter/app update while guest producer is connected;
- audio-owner handoff failure, direct-device loss, route change, xruns and
  hardware clock drift;
- low disk, memory pressure, Wi-Fi loss, DNS failure and thermal throttling;
- install, in-place upgrade, downgrade refusal, rollback and boot restore;
- 8-hour mixed workload soak with evidence snapshots;
- full desktop-off and interactive phone verification after every risky run.

Every hardware run records commit, manifests, profile digest, command, result,
state journal, timings, hashes, and bounded relevant logs under `artifacts/`.

## 15. Release engineering

- pin every moving external source to a reviewed commit in release mode;
- produce a build manifest containing toolchain, source and artifact hashes;
- build module, binaries, guest additions and app from a clean checkout;
- sign release APK/module artifacts with durable keys and document custody;
- separate large lab evidence from normal source history without deleting its
  manifest or provenance;
- verify both Zygisk ABIs and every shipped native binary;
- add install-time compatibility checks which fail before replacing a working
  version;
- stage update, self-test, atomically activate, retain previous version;
- make rollback available from Android, `det`, Magisk action, and USB recovery;
- publish supported device/ROM/kernel combinations from evidence.

## 16. Android-native features

High-value integrations after the API foundation:

- live Quick Settings tile with PHONE/transition/DESKTOP/recovery states;
- dynamic launcher shortcuts for enter, external summon, files, terminal and
  recovery;
- bidirectional share sheet with progress and destination choice;
- Storage Access Framework provider exposing a deliberately narrow guest
  exchange directory;
- external-display attach affordance and remembered per-display preference;
- keyboard, mouse and controller presence as summon suggestions;
- media-session bridge for desktop players;
- clipboard bridge with explicit enablement, MIME limits and sensitive-content
  timeout;
- URL/open-with handoff in both directions;
- battery, thermal, connectivity and route information in the desktop shell;
- Android app intents for safe automation, with confirmations for destructive
  operations;
- optional Tasker/automation integration over the same permissioned API;
- recovery shortcut which works even when the main activity is unhealthy.

## 17. Desktop polish and useful cool things

- feedbackd haptics through a capability-scoped host call;
- dynamic wallpaper handoff from Android without copying private wallpaper
  data unless enabled;
- resolution/DPI profiles per internal and external display;
- desktop-mode power profiles with visible thermal/battery trade-offs;
- session snapshots and restore after compositor restart;
- a convergence shelf for recently shared Android files and apps;
- phone-as-touchpad/keyboard mode while presenting externally;
- presenter latency HUD and developer overlay;
- one-command bug capsule containing sanitised status, journal and logs;
- guest package/update health surfaced without pretending apt is an Android
  package manager;
- optional remote desktop path for debugging when HWC is unavailable;
- fast user switching between Phosh and proven compositor sessions only.

## 18. Easter eggs, with restraint

Easter eggs are opt-in, deterministic, cheap, and incapable of affecting
recovery:

- a rare Deltarune-flavoured transition variant selected locally, never on the
  first transition after an update;
- `det soul` prints a tiny animated health/status heart whose behaviour reflects
  PHONE, DESKTOP, DEGRADED, and RECOVERY;
- a Konami-style key sequence in the companion opens the graphics benchmark
  dashboard, not a destructive command;
- release codenames unlock wallpaper/accent packs stored in the guest;
- a terminal fortune assembled from real system facts and project lore;
- an “absolute determination” achievement after 50 clean cycles, backed by the
  actual qualification journal rather than a counter in the UI;
- presenter colour bars hide a small build ID so first-frame photos retain
  provenance.

No easter egg runs as root, changes display colour calibration, touches update
state, wakes the device repeatedly, or surprises the user during recovery.

## 19. Execution sequence

The order below is risk-driven. Work may overlap only where lifetimes are truly
independent.

### Wave 0 — stop making new debt

- freeze the current hardware truth and collect clean phone-mode status;
- remove unintended forced display-colour writes;
- preserve the uncommitted presenter work; retain the app audio experiment only
  as comparison evidence while replacing it with direct hardware access;
- write this plan and identify ownership boundaries;
- define module/app/guest/kernel manifest identities.

**Gate:** current scripts still enter/exit and an emergency phone restore exists.

### Wave 1 — native control skeleton

- create host-buildable control protocol and state core;
- implement `detd` dark launch, lock, atomic state and read-only status;
- implement `detctl hello/status/doctor`;
- add host unit tests and Android NDK builds;
- package binaries without making boot depend on them.

**Gate:** daemon can be killed/restarted 100 times without changing mode.

### Wave 2 — authoritative transition wrapper

- add mode requests, request IDs, deadlines and journal;
- execute proven scripts as fixed adapters;
- reconcile boot and daemon death;
- expose compatibility marker files;
- keep emergency `desktop-off` independent.

**Gate:** ten cycles through daemon plus kill/restart injection end in known state.

### Wave 3 — app/CLI migration

- route host `det` through `detctl`;
- update Zygisk root companion to forward structured RPC;
- migrate companion status, enter, exit and recover;
- preserve old-module fallback;
- add event subscription UI.

**Gate:** no periodic app root shell, QS/shortcut/app agree on one state.

### Wave 4 — guest-agent replacement

- ship `det-guest-agent` and guest endpoint policy;
- map all old control commands;
- move session manager/power/health integration;
- run old and new agents in compare-only mode, then switch authority.

**Gate:** guest logout/reboot/poweroff and recovery work after agent restart.

### Wave 5 — observability and qualification harness

- finish structured doctor/metrics/events;
- add failure injection and hardware-run manifests;
- establish memory, timing, wakeup and battery baselines;
- run 50-cycle and initial soak.

**Gate:** zero ambiguous states; every failure explains its recovery.

### Wave 6 — external presenter gate

- decouple lifecycle from audio;
- harden protocol, quotas, resize and asynchronous ownership;
- build colour-bar producer;
- show and pace the first DP frame; survive hotplug.

**Gate:** internal Android remains interactive throughout and every fd is released.

### Wave 7 — audio product path

- inventory and gate direct ALSA/tinyalsa access;
- implement transactional Android-audio quiesce/direct-hardware/restore;
- generate UCM2/device routing and connect PipeWire directly;
- measure latency/drift/xruns and wire volume keys without AudioFlinger;
- qualify death/suspend/hotplug and failed-restore behaviour;
- remove the app/AAudio bridge from product packaging.

**Gate:** normal apps play directly through hardware, Android audio restores
exactly on exit, and disabling audio affects nothing else.

### Wave 8 — compositor external output and input

- integrate presenter backend;
- implement constrained input return;
- add display selection, scaling and summon/hide;
- measure end-to-end frame latency.

**Gate:** two-hour external desktop with Android live, cable cycles, audio and input.

### Wave 9 — extract transition machinery

- replace shell supervision, markers and polling in risk order;
- keep device-specific leaf adapters;
- compare old/new observations during rollout;
- remove old paths only after device gates.

**Gate:** 50-cycle and recovery suite equal or better than the proven scripts.

### Wave 10 — portability proof

- complete recon compiler and generated outputs;
- bring up a hostile second device end to end;
- revise schemas only from evidence;
- publish accurate capability/support matrix.

**Gate:** clean install, recovery and upgrade work on two materially different devices.

### Wave 11 — release and delight

- cut an honest stable point;
- permanent signing, reproducible builds, rollback and docs;
- add native integrations, polish, performance profiles and safe easter eggs;
- keep experimental graphics/features behind explicit capability gates.

**Gate:** a new installation follows the docs without archaeology or private shell history.

## 20. Immediate implementation batch

The first batch starts now and is intentionally narrower than the whole plan:

1. build the protocol/state library with host tests;
2. build Android `detd` and `detctl` for arm64;
3. add read-only `hello`, `status`, `doctor`, and `capabilities`;
4. package and dark-launch the daemon after boot;
5. add authoritative mode requests which call existing transition adapters;
6. add journal/reconciliation and emergency fallback;
7. update Zygisk and companion control calls;
8. build the native guest agent in compare-only mode;
9. validate source, host tests, NDK artifacts and module packaging;
10. deploy read-only pieces first, then perform device cycles with full phone
    recovery after each risky change.

The presenter changes already in the worktree are preserved. The app audio
changes remain only long enough to measure against and replace; they are not a
product dependency. Both workstreams are picked up once the state/API spine can
observe and control their independent lifetimes.

### 20.1 Implementation checkpoint — 2026-07-20

The first batch is now implemented through source/build gates:

- `detd`, `detctl`, durable transitions, Zygisk forwarding and the native guest
  endpoint are built and packaged; boot is intentionally still observe-only;
- explicit app intents and signature AIDL expose fixed native operations;
- doctor/metrics understand guest, presenter and audio-owner contradictions;
- the presenter is independent of audio and enforces peer, buffer, pixel,
  in-flight, metadata, serial and fence bounds;
- the AudioTrack/AAudio app path is retired and absent from the APK permissions;
- direct audio has cross-namespace inventory, a journalled exact-profile owner,
  claim marker, guest PipeWire lifetime, zero-holder restore gate and rollback
  tests;
- host, Android arm64, guest arm64, both companion ABIs and Magisk packaging
  pass locally.

Hardware claims remain deliberately incomplete: the approval/usage layer
blocked further phone writes after the earlier observe-only deployment. The
phone therefore still runs that verified observe-only daemon, while newer
transition, presenter and audio builds await deployment and recovery testing.

## 21. Things this plan refuses to fake

- One device with many config keys is not universal support.
- A compiling presenter is not external convergence.
- Running PipeWire processes or an AAudio bridge are not working product audio.
- A daemon which merely shells out without state ownership is not a control
  plane.
- A permanent notification is not deep Android integration.
- A benchmark without presentation/vsync is not desktop frame latency.
- A dma-buf fd without the private native-handle data is not a portable Android
  buffer.
- A recovery path which means “Melissa remembers the magic adb command” is not
  recovery.
- A colour-temperature preference silently written during a transition is not
  display restoration.

That honesty is part of the architecture. Determination has already done the
hard, strange work. The overhaul is how that work stops depending on heroics.
