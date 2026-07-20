# Determination project review

**Date:** 2026-07-20

**Reviewed state:** `main` at `4811f05`, plus the current uncommitted external-presenter/audio work

**Bottom line:** Determination is a successful, unusually complete device-specific alpha. It is no longer a feasibility experiment. It is also not yet a dependable release or a portable convergence platform. The hard problem has changed from “can this work?” to “can this recover, reproduce, survive, and work somewhere other than Melissa's exact phone?”

## The honest answer

“Almost everything works” is fair if “everything” means the internal-panel desktop experience on this OnePlus 7:

- The custom kernel boots and has the required namespace, binder, checkpoint, and diagnostics support.
- Android remains PID 1.
- The Debian guest starts as an unprivileged user.
- phoc/phosh render through the Android vendor graphics stack.
- Touch, keyboard, wake, battery reporting, session actions, networking, SSH, and transition back to Android all work.
- The system can be entered and exited repeatedly without the old SurfaceFlinger/watchdog crash loop.
- There is now a credible recovery and restore story rather than a one-way demo.

That is a hell of an achievement. Most projects in this area stop at a compositor drawing one frame, require a Frankenstein mainline kernel, or quietly replace Android. Determination has a real daily-usable environment on the downstream Android kernel and keeps the original device stack intact.

“Almost everything works” is not yet fair against the whole project promise:

- Android's application framework is deliberately frozen during internal desktop mode. Android is still the host, but it is not fully live.
- Concurrent external convergence is not working end to end. The presenter is currently a compiling prototype, not a displayed desktop.
- Audio is not a proven product path.
- Portability has a good configuration foundation but exactly one proven device.
- Release reproduction, automated recovery testing, security hardening, and long-duration stability remain substantially unfinished.

My label for the project is **late hardware prototype / serious pre-release alpha**. For Melissa's phone, it is closer to a beta-quality personal tool. For another person's phone, or even a clean rebuild of this one six months from now, it is still an alpha.

## Three finish lines, not one

The apparent disagreement between “it works” and “it isn't ready” disappears once the finish lines are separated.

| Finish line | Current position | Honest status |
| --- | --- | --- |
| Internal desktop on this OnePlus 7 | Boots, renders, accepts input, networks, wakes, exits, and is remotely usable | **Mostly achieved; hardening remains** |
| Aqua release as currently scoped | Core experience exists, but ship gates, signing, cycle tests, soak, and reproducible artifacts are open | **Feature-complete-ish, release-incomplete** |
| Determination north star | Live Android plus concurrent external desktop, portable across device families | **Architecture proven in pieces; product not yet assembled** |

That distinction should stay explicit in the README, release notes, and milestone language. It prevents a technically honest internal-display release from being judged as a failed universal-convergence release, and it prevents a good demo from being advertised as a finished platform.

## Where the project is genuinely strong

### 1. The central technical thesis is proven

The largest uncertainty is gone. A downstream Android phone can host a useful Debian desktop without becoming a conventional ROM or abandoning its vendor kernel and graphics stack.

The proof is broad rather than cosmetic:

- private PID and binder namespaces work on the 4.14 downstream kernel;
- libhybris can talk to the Android 16 vendor EGL/GLES implementation;
- the Droidian wlroots/phoc stack can drive the internal display through HWC;
- real Wayland clients use GPU buffers rather than a screenshot or software-only path;
- the session runs as `melissa`, not as an ornamental root shell;
- input ownership, PTYs, `nosuid`, pidfd incompatibility, battery lies, wake behavior, and session-manager behavior have all been chased down at their actual layer.

That last point matters. The project repeatedly encountered bugs that look tiny in a screenshot but are the difference between a demo and a system: `/dev/ptmx`, input GIDs, `/etc/phoc.ini` permissions, a charger re-enumerating its power-supply node, and a half-backported pidfd API. The fixes are now encoded rather than living only in terminal history.

The recent unprivileged-ping fix is a small example of the same good instinct: change `ping_group_range` in the guest network namespace through the host's writable procfs, instead of making `ping` setuid or granting the whole session `CAP_NET_RAW`.

### 2. Graphics work has moved from folklore to evidence

The project now has a coherent compatibility-first graphics policy:

- vendor EGL/GLES goes through libhybris;
- Android gralloc remains the owner of Android buffers;
- minigbm provides the compositor-facing GBM layer;
- Turnip/KGSL and raw KMS remain valuable diagnostics and optional paths, not a falsely universal default.

The full QTI native handle has been round-tripped, including its two file descriptors and 22 private integers. Vendor EGL renders through the reconstructed object, minigbm imports and re-exports the dma-buf, and native fences have been transported and waited. That directly answers the most important compatibility question: reducing the buffer to “one dma-buf fd” would be wrong, and the project has measured why.

The compatibility benchmark is also encouraging: four fullscreen textured/blended layers at 1080x2340 averaged 4.263 ms with 4.625 ms p99; handle reconstruction averaged 8 microseconds and minigbm import/export 92 microseconds. Those numbers leave useful budget.

They are not an end-to-end compositor benchmark. They exclude KWin, presentation, vsync, scheduling, and the external presenter. The report already says so, which is exactly the right scientific posture.

### 3. The system now has a real escape path

Recovery engineering is one of the strongest parts of Determination:

- known-good boot images are backed up;
- check/flash/restore/verify flows exist;
- dry-run behavior exists;
- pstore/ramoops provides post-crash evidence;
- desktop-off restores Android rather than hoping a reboot hides state;
- `det guest-root` remains an explicit escape hatch while normal use stays unprivileged.

That is more important than another settings screen. A convergence layer which can take over display, input, and Android services must make failure boring.

### 4. The project has become pleasant enough to inhabit

Direct key-only SSH to `melissa@192.168.117.2`, a useful MOTD, correct terminal capabilities, a global `det` command, Fish, and a non-root desktop do not solve the core architecture. They do change the project from something only its author can nurse through ADB into something that can be used normally.

The recent transition animation and UI polish are in the same category: valuable now that the core works, but not substitutes for correctness. The balance is currently reasonable.

### 5. The documentation is unusually candid

`docs/design-spec.md`, `docs/recon-findings.md`, `docs/graphics-architecture.md`, `docs/north-star.md`, `RELEASES.md`, and the artifact trail contain the reasoning, failed approaches, and measured boundaries. The release notes now explicitly admit that system_server is frozen. The graphics document distinguishes a compatibility product path from a diagnostic native path. The universalisation document calls its first slice what it is.

That is a meaningful improvement over the earlier project review. Two of its biggest criticisms—unclear product truth around “live Android” and lack of a graphics policy—have been addressed honestly.

## The biggest architectural debt

### 1. The control plane is still a collection of brave shell scripts

`desktop-on`, `desktop-off`, `guest-start`, the host agent, pidfiles, marker files, polling loops, and sleeps collectively behave like a service manager, but they do not share a durable state model.

The project needs one owner for this state machine:

```text
PHONE -> ENTERING -> DESKTOP -> EXITING -> PHONE
             |          |          |
             +-------> RECOVERY <---+
```

That owner should provide:

- a single transition lock;
- desired state and observed state;
- bounded operations with explicit deadlines;
- idempotent steps;
- a journal of completed steps;
- reverse-order rollback;
- reconciliation after host-agent death, guest death, or reboot;
- machine-readable health for `det status` and the companion app.

The current scripts have become much better: they validate more prerequisites, poll for real conditions, and handle known failure cases. But adding another loop every time a race appears will eventually make recovery less knowable, not more reliable. This is the highest-leverage engineering task after the first external frame.

The supervisor does not have to be a grand Rust daemon. A small, explicit program or carefully structured shell controller with a locked state directory would be enough. The important change is ownership and transactional semantics, not language fashion.

### 2. Internal desktop mode works by suspending the thing the north star wants alive

Freezing system_server is an excellent solution to the immediate watchdog crash. It preserves Wi-Fi, prevents framework thrash, and made the internal desktop stable. It should be celebrated as a successful product compromise for Aqua.

It is not the final architecture:

- Android apps and framework services are unavailable while frozen;
- framework-based diagnostics such as `dumpsys` can hang during the exact mode where diagnostics are needed;
- Android cannot concurrently own an external display or participate normally in hotplug;
- the exit path must kill and respawn system_server because resuming it would release the accumulated watchdog failure.

The project is now honest about this. Keep treating it as a scoped internal-display mode, not as evidence that the full live-Android convergence goal is complete.

### 3. The external presenter is the right bridge, but only half a bridge exists

The current uncommitted work points in the correct direction:

- Android owns the external `Presentation` and `SurfaceControl`;
- the guest and companion exchange `AHardwareBuffer` objects over a Unix `SOCK_SEQPACKET` channel;
- the protocol accounts for full native handles plus acquire, present, and release fences;
- binder does not have to cross the container boundary.

The Android side and its native library currently compile for arm64-v8a and armeabi-v7a. That is good. It is not yet an external desktop:

- no guest compositor backend is wired to the presenter client;
- no first buffer has been shown on DP-alt through this path;
- input return is absent;
- hotplug, mode change, disconnect, and presenter-death recovery are untested;
- there is no protocol test harness or fuzzable fixture;
- the benchmark does not include this path.

There are also design issues worth fixing before the prototype becomes load-bearing:

1. **Presenter lifetime is coupled to `AudioBridgeService`.** If the audio-at-boot preference is off, the external display presenter may never exist. Display presentation needs an independent lifecycle and should not inherit audio's foreground-service/notification policy.
2. **Same-display resizing is skipped.** `refresh()` returns when the display ID is unchanged even though a native resize entry point exists. Mode or resolution changes on the same connector can therefore leave stale dimensions.
3. **The trust boundary is broad.** The socket is made mode `0666`, and there is no evident peer-credential check, buffer-count quota, or memory budget. A compromised guest process can at minimum attempt resource exhaustion.
4. **Asynchronous lifetime needs an audit.** Transaction completion contexts retain native surface references while presenter teardown can happen independently. Disconnect and hotplug while callbacks are outstanding need deterministic ownership, not optimistic timing.
5. **Backpressure needs to be explicit.** A producer must not outrun Android presentation and grow an unbounded queue of gralloc buffers or fences.

None of these invalidate the approach. They are exactly the work expected when turning a successful transport experiment into a compositor winsys.

### 4. Audio is still product debt, not a checked box

PipeWire, WirePlumber, and `pipewire-pulse` are running in the guest. That proves the guest audio session starts. It does not prove sound reaches the phone correctly or that volume keys and routing behave like a product.

The companion audio bridge has previously been non-working, and its foreground-service notification conflicts with the established product preference not to build the experience around notifications. The new presenter should not be made dependent on that service just because it is a convenient long-running Android component.

Treat audio as its own system boundary: define the transport, route ownership, latency target, wake behavior, and failure recovery. If it will not make Aqua, say so and ship without pretending a running PipeWire process means it is done.

## Reliability and performance

### What today's live state says

At review time:

- Aqua reported `0.5.0-alpha.1` / versionCode 12;
- the determination kernel and module were active;
- the guest was running at `192.168.117.2`;
- phoc, phosh, seatd, SSH, portals, PipeWire, and WirePlumber were present;
- system_server was stopped in state `T`, as designed for internal desktop mode;
- Wi-Fi and the guest bridge remained up;
- the toggle log showed several successful enter/exit cycles in the preceding hour.

That is legitimate recent-use evidence. It is not a qualification run.

The concerning snapshot was memory: about 4.2 GiB of 5.3 GiB used, only about 1.2 GiB available, and roughly 1.0 GiB of 1.1 GiB swap occupied. One snapshot cannot distinguish normal Android cache/zram behavior from a leak, and free memory alone is a bad diagnosis. It is enough to justify a proper investigation before calling multi-hour use stable.

Measure at minimum:

- phone-mode baseline after boot;
- immediately after entering desktop;
- 30 minutes, 2 hours, and 8 hours later;
- per-process RSS/PSS for phosh, phoc, WebKit clients, PipeWire, companion, and LXC helpers;
- zram in/out, major faults, PSI memory stalls, and low-memory kills;
- the same measurements after exit back to Android.

The next stability gate should be failure-oriented, not another happy-path demo:

- 50 automated enter/exit cycles;
- kill phoc, phosh, host agent, presenter, and guest init at chosen transition steps;
- unplug/replug DP during registration and during a submitted frame;
- lose Wi-Fi, exhaust disk space, and start under memory pressure;
- reboot from PHONE, ENTERING, DESKTOP, and EXITING states;
- update the companion and module across an existing install;
- soak for multiple hours with video, browser, suspend/wake, and repeated cable events.

The system should finish every case in PHONE, DESKTOP, or an explicit RECOVERY state. “A reboot fixed it” is allowed as a final recovery mechanism, but it must be detected and requested deliberately.

## Portability: good skeleton, one body

Project Universalisation made the right first move. Runtime discovery, exact-match device profiles, generated LXC/guest configuration, canonical aliases, and capability-oriented recon are much better than scattering OnePlus constants through every script.

The limitation is evidence. Every complete path is still proven only on:

- OnePlus 7 / `guacamoleb`;
- SM8150 / Adreno 640;
- crDroid Android 16;
- a downstream 4.14 kernel;
- HIDL composer 2.x;
- QTI mapper/gralloc 4 behavior;
- this boot partition and vendor layout.

AIDL composer, Mali, different Qualcomm generations, GKI, `vendor_boot`/`init_boot`, different touch/display topology, and devices without the same HWC handoff behavior are not implementation details. They are different product branches.

Do not add more profile fields merely to make the configuration look universal. The next portability milestone should be a hostile second device brought through the entire flow: recon, kernel feature decision, image packaging, guest generation, graphics probe, input, transition, recovery, and upgrade. Anything discovered must be wired through every consumer before it becomes a public configuration option.

Until then the honest description is **portable architecture work with one supported device**, not “supports dozens of phones.”

## Reproducibility and release engineering

`release/check.sh` passes its development checks, which is useful. Its warnings describe the remaining release problem accurately:

- the tree is dirty;
- libhybris is cloned from moving `master`;
- wlroots and phoc use moving branch names;
- the release APK is not permanently signed;
- the full ship checklist is still open.

The source build depends on local toolchains, vendor inputs, branch tips, scripted source rewrites, and manually accumulated device state. Today, a knowledgeable Melissa can reproduce it. That is not the same as the repository reproducing it.

Before a public Aqua build:

1. Pin every upstream repository to a commit and record source URLs and hashes.
2. Convert source rewrites into reviewable patch files with applicability checks.
3. Record toolchain/NDK/Gradle versions and hashes in one manifest.
4. Build kernel, guest libraries, Zygisk, companion, module, and boot artifact from a clean checkout using a documented command sequence.
5. Generate an artifact manifest containing git commit, input commits, config, hashes, device profile, and signing identity.
6. Establish a permanent Android signing key and a documented protected-key process.
7. Run clean-install, upgrade, and restore qualification against the exact produced artifacts.

The repo is also carrying three roughly 100 MB boot images, large logs, old module zips, and screenshots alongside source. The evidence is valuable; deleting it would be silly. Separate immutable release artifacts and bulky lab evidence from normal Git history using releases, an artifact store, or LFS plus a small checked-in manifest. The current pack is already around 119 MB and will only grow.

There are 110 commits, 13 commits ahead of `origin/main`, and a dirty working tree containing serious external-display work. Push or otherwise back up the existing history soon, but do not mix the presenter experiment into the Aqua release accidentally. The 18 early commits under the legacy `melissa@example.com` identity are not worth rewriting public history for; standardize new commits and move on.

## Testing and observability

Determination has many valuable on-device probes and smoke gates. It has almost no conventional automated test suite and no CI. Those are different facts, and both matter.

The highest-value tests are not generic coverage metrics. They are tests for the boundaries that have already failed:

- parse and validate generated device/LXC/guest configurations;
- shell-script syntax and static checks;
- pure tests for control-state reconciliation and rollback ordering;
- protocol tests for presenter registration, fd ownership, malformed messages, quota enforcement, reconnect, and mode change;
- native-handle fixtures with multiple fd/int layouts;
- build checks for both Android ABIs;
- reproducibility checks which reject moving refs in release mode;
- a hardware test runner which records cycle outcomes and artifact hashes.

Observability also needs consolidation. In desktop mode, system_server is frozen, some Android diagnostics hang, guest log access is fragmented, and routine `lxc-attach` output still carries noisy unsupported-seccomp warnings. A `det doctor --json` command should report, without needing framework services:

- desired and observed mode;
- transition owner and age;
- host/guest PIDs and namespace identity;
- SurfaceFlinger/system_server/zygote states;
- bridge, Wi-Fi, route, DNS, and SSH health;
- compositor/session/audio/presenter health;
- current display IDs and modes;
- memory/swap/PSI summary;
- last failed transition step and relevant log paths.

That becomes the input to both human debugging and eventual automated recovery.

## Security model

The project currently assumes the Debian guest and Melissa are trusted. That is understandable for a one-owner research device, but it must be written down because the implementation grants broad access:

- several GPU, binder, ashmem, input, and vendor device nodes are exposed or relaxed;
- guest uid/gid choices deliberately overlap Android AIDs;
- root-controlled host actions are reachable through fixed command channels;
- the developing presenter socket accepts powerful buffer/fence traffic;
- SSH is reachable on the device-side network.

There are good decisions already: SSH is public-key-only with root login disabled, the Zygisk bridge accepts a narrow fixed command set, the desktop runs unprivileged, and the ping fix avoids a broad capability.

Before claiming safety beyond a personal device:

- write a threat model covering malicious guest apps, malicious Android apps, and compromised desktop processes;
- expose only the device nodes each graphics/input path actually needs;
- authenticate IPC peers with filesystem ownership plus `SO_PEERCRED` or an equivalent credential check;
- add message-size, fd-count, buffer-count, and memory quotas;
- make every privileged command explicit and auditable;
- decide whether the guest is a trusted appliance or a general package-installing Debian environment, because those imply different containment promises.

Security is currently a prototype boundary, not a release boundary. That is acceptable if stated plainly.

## Product and scope decisions

The project can now hurt itself more through scope confusion than technical inability.

### Aqua should remain a small, honest release

`RELEASES.md` scopes Aqua around the working internal-display experience and explicitly leaves external convergence out. Keep that contract unless there is a deliberate re-scope.

The external presenter is important north-star work, but it should not indefinitely delay hardening the already useful internal mode. There are two defensible choices:

- **Cut Aqua:** freeze features, finish its ship gates, qualify internal mode, sign it, and release it as a OnePlus 7 alpha.
- **Re-scope Aqua:** explicitly make first external presentation a gate, change the release plan, and accept the added protocol/compositor/hotplug work.

The bad choice is leaving Aqua's written scope unchanged while quietly allowing unfinished presenter and audio coupling to become release dependencies.

### Hide choices that do not exist yet

If the companion UI exposes compositor/session alternatives that are only stored preferences and not real runtime choices, hide or disable them. A focused interface with one working path is more honest than a configurable-looking one whose secondary paths do nothing.

### Keep Android integration native, but not notification-dependent

Launcher shortcuts, share-sheet import/export, and a narrow system bridge fit the project. A permanent foreground notification as the lifetime owner for unrelated audio and display systems does not. Android may require a foreground execution mechanism for some work, but the product architecture should not make a notification the user's primary control surface or couple unrelated features merely to reuse one service.

## Grades, with context

These grades are deliberately harsh about product readiness and generous about proven engineering. Averaging them into one score would be meaningless.

| Area | Grade | Reason |
| --- | --- | --- |
| Core technical feasibility | **A** | The central Android-hosted Debian convergence thesis is proven on real hardware. |
| OnePlus 7 internal desktop | **B+** | Broadly usable and recoverable; framework freeze, audio, soak, and memory questions remain. |
| Graphics investigation | **A-** | Excellent evidence and policy; final compositor/presenter integration is still absent. |
| Recovery engineering | **B** | Strong tools and escape hatches; no unified reconciliation state machine yet. |
| User experience | **B** | Daily interaction is credible; some settings and service behavior still expose prototype seams. |
| External convergence | **C-** | Correct design and compiling Android half; no end-to-end external frame or input path. |
| Portability | **C** | Good discovery/profile architecture; one proven device and many unimplemented hardware families. |
| Reproducibility | **D+** | Build knowledge exists, but moving inputs and local state prevent clean independent reproduction. |
| Automated testing | **D** | Many manual/hardware gates, almost no conventional suite or CI, ship cycle gates open. |
| Security hardening | **D** | Reasonable personal-device choices, broad trusted-guest boundary, no complete threat model. |
| Public release readiness | **D+** | A real alpha is close, but signing, pinning, qualification, clean artifacts, and support boundaries are open. |

## What I would do next

In order:

### P0: Get one external frame through the real intended path

Separate presenter lifetime from audio. Fix same-display resize. Add peer/resource limits and explicit buffer ownership. Build the smallest guest producer possible—not KWin yet—which registers two or three buffers, draws unmistakable colors, submits with acquire fences, receives release fences, survives disconnect, and shows on DP-alt.

That closes the last major architecture uncertainty without burying it under compositor complexity.

### P0: Give transitions one state owner

Implement the PHONE/ENTERING/DESKTOP/EXITING/RECOVERY model, locking, journal, bounded steps, rollback, and reconciliation. Port the current proven shell operations into it instead of rewriting working low-level commands for aesthetic reasons.

### P1: Qualify what already works

Run the 50-cycle test, failure injection, and multi-hour soak. Investigate memory/swap with data. Fix every case which ends in an ambiguous state. Make the report machine-readable and retain it in `artifacts/` with the exact commit and build manifest.

### P1: Decide and cut Aqua

Freeze its scope, pin inputs, create permanent signing, build from clean checkout, run install/upgrade/restore, finish docs, and publish a deliberately narrow OnePlus 7 alpha. Do not call it universal. Do not claim Android is fully live in internal mode.

### P1: Resolve audio independently

Either produce a measured, usable PipeWire-to-Android path with volume-key behavior or explicitly defer it. Remove the presenter's dependency on the audio bridge either way.

### P2: Prove the portability system on a hostile second phone

Choose a device which forces at least one real branch—AIDL composer, a newer boot layout, another GPU family, or GKI. Take it through the whole deployment and recovery path. Use the failures to define actual capability interfaces rather than speculative config fields.

### P2: Tighten the trust boundary

Threat model, minimize nodes and permissions, authenticate IPC, add quotas, and test malformed traffic before the guest is treated as safe for arbitrary desktop software.

## Final judgement

Determination has crossed the most important line: it is real. It boots, renders, accepts input, survives, returns to Android, and is comfortable enough to SSH into and use. The project has solved enough obscure downstream-kernel and vendor-graphics problems that dismissing it as a hack would be ignorant.

It is also standing at the point where clever hacks stop compounding positively. The system_server freezer, shell orchestration, broad device access, moving dependencies, and one-device evidence were all reasonable ways to reach proof quickly. If they remain the permanent architecture, they will cap the project below its stated ambition.

The next phase should be less visually dramatic and more ruthless:

- own state;
- bound failure;
- pin inputs;
- measure longevity;
- separate service lifetimes;
- prove the external buffer path;
- then make a second phone expose every hidden assumption.

If Aqua is scoped honestly, Determination is close to a releasable OnePlus 7 alpha. If the goal is the full “Android remains live while a Linux desktop runs externally across many phones” promise, the project is perhaps halfway through product engineering even though it is much further than halfway through technical discovery.

That is not a demotion. Technical discovery is where projects like this usually die. Determination survived it. Now it has to become boring on purpose.
