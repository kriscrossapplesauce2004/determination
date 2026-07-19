# Determination: an architectural review by Tinus Lorvalds

> I am not Linus Torvalds. This is easy to verify: my name is Tinus Lorvalds,
> which is completely different and would stand up in court provided the judge
> had recently suffered a head injury. I may be his evil twin. The family does
> not discuss it. Anyway, somebody left a downstream Android kernel unattended,
> so now we have to review it.

## The short version

This project is real engineering. It boots a Debian userspace beside Android on
an old downstream Qualcomm kernel, drives the actual panel, hands input across,
gets accelerated GTK and Plasma pixels onto the screen, and—most importantly—has
artifacts showing that this happened on hardware. That already puts it above a
large fraction of “mobile convergence” projects, which often consist of a block
diagram, three screenshots, and a corpse in `buildroot/`.

The central architectural decision is also correct for the stated requirement:
if Android must remain the real phone, Android remains PID 1. A Debian LXC guest
shares the vendor kernel and borrows Android's hardware ecosystem through either
libhybris/HWC or native DRM/Turnip. That is coherent. It accepts the ugly facts
instead of pretending a 2019 Qualcomm phone is a standards-compliant PC.

But let us not bullshit ourselves. Determination is currently an excellent,
well-recorded **OnePlus 7 bring-up**, not a platform. Its internal-panel mode is
held together by shell supervisors, global device permissions, undocumented
vendor behaviour encoded as patches, and the small matter of freezing
`system_server` for the duration of the desktop session and murdering it on the
way back. That is a successful experiment. It is not a stable systems boundary.

The project should continue, because the difficult parts have genuinely been
proven. It should also stop declaring victory where the mechanism is still a
controlled hostage situation. “It survived 150 seconds” is evidence. It is not
a release model. A housefly can survive 150 seconds in a car and nobody calls
the fly an automotive platform.

## What the architecture actually is

Strip away the milestone numbering and the architecture has four layers:

1. **Android owns boot and the phone lifecycle.** A custom kernel adds the
   namespace, cgroup, binderfs, pstore, and related facilities missing from the
   stock downstream configuration. Magisk provides installation and boot hooks.
2. **A Debian LXC guest supplies the desktop userspace.** It shares the kernel
   and receives selected Android devices, vendor libraries, binder facilities,
   and control paths.
3. **There are two graphics tracks.** The proven compatibility track uses
   libhybris, vendor EGL/gralloc, Droidian wlroots, and HWC. The newer native
   track uses Mesa Turnip on KGSL, minigbm, zink, and downstream MSM DRM.
4. **Mode switching is host policy.** Android-side shell scripts stop
   SurfaceFlinger, arbitrate input, launch or terminate compositors, maintain
   backlight state, freeze framework processes, and attempt recovery.

That fourth layer is the real product. The rest is difficult integration work,
but mode ownership and recovery determine whether this is a machine or a demo.
Right now that layer is a collection of increasingly knowledgeable scripts. The
scripts are impressively documented. They are still scripts, and comments do
not provide mutual exclusion no matter how sternly you write them.

## The good parts—and yes, there are quite a few

### The topology is honest

Keeping Android as PID 1 is the only defensible choice if “still functions as a
phone” is non-negotiable. The design document explains the Maru-versus-Halium
inversion clearly and follows the consequences through display ownership,
vendor blobs, input, and packaging. This is the strongest part of the project:
the main constraint was chosen explicitly instead of discovered six months
later as an unpleasant surprise.

### The work is evidence-driven

The repository contains recon reports, kernel configurations, compositor logs,
KMS probes, screenshots, crash evidence, and dated smoke-test results. The
project repeatedly turns an observation into a reproducible gate. That is
proper engineering. `native-smoke.sh`, the raw-KMS gate, cycle stress, boot
image verification, and the recovery paths are exactly the sort of boring work
that prevents interesting projects from eating their own users.

The flash procedure is particularly sane: RAM-boot first, verify that the phone
is still a phone, then flash, with the original image retained. Whoever wrote
that section understands that a boot image is not a motivational poster. Good.
I was preparing the traditional maintainer response, which consists of asking
why your recovery plan begins after you destroyed the only bootable slot.

### The hardware debugging is excellent

The libhybris work shows unusually good fault isolation. The project tracked a
black display to per-client SDM brightness, GTK failures to a falsely advertised
EGL extension, blank GSK rendering to a vendor shader miscompile, and broken
child watching to a partial pidfd backport. Those are nasty cross-ABI failures,
and the evidence trail is far better than “setting this variable seems to fix
it.”

Likewise, proving Turnip-on-KGSL, minigbm allocation, dmabuf import, raw KMS
scanout, and KWin/Plasma is strategically important. It creates a route away
from the libhybris pile rather than polishing that pile forever.

### The documentation remembers failure

Failed approaches are recorded, including the useless PLT kill hooks and the
`phoc -E` pidfd failure. This matters. A project that only records the final
incantation forces every future contributor to repeat the archaeology.

## Where the design is lying to itself

### 1. Freezing `system_server` is not “full desktop-mode stability”

The current internal handoff stops SurfaceFlinger, repeatedly suppresses its
restart, sends `SIGSTOP` to `system_server`, and later sends `SIGKILL` so Android
can spawn a clean one. The documentation describes this as the completed
stability milestone because Wi-Fi remains alive during a 150-second soak.

No. Absolutely not. It is a clever containment hack for a framework that was never designed to
survive losing SurfaceFlinger this way. While frozen, Android's core Java system
services do not exist in any meaningful operational sense. Telephony policy,
notifications, package events, alarms, power management, Bluetooth policy,
input policy, and a great deal more are stalled behind one stopped process.
Killing it on exit discards whatever state accumulated and bets on Android's
recovery machinery.

That may be acceptable for an experimental **exclusive appliance mode**. Name it
that. Do not call it a fully live phone, and do not build more product promises
on top of it. Either develop a framework/display contract that leaves
`system_server` running, or admit internal desktop mode suspends most of
Android. Words matter because architecture follows them, and because otherwise
some poor bastard will debug a missed alarm for three days before discovering
that the operating system was deliberately placed in a coma.

### 2. The control plane has no real state machine

`desktop-on` is 285 lines of shell with background loops, pidfiles, marker
files, sleeps, process-name matching, and several independent supervisors.
`desktop-off` attempts the reverse sequence. This works until two callers race,
a stale PID is reused, a subprocess half-starts, a compositor ignores `TERM`, or
the device reboots between side effects.

There is no single owner of the transition, no lock, no durable phase record,
and no transactional rollback. “Marker file exists” is not a state machine.
The valid states are at least:

`PHONE -> ACQUIRING -> DESKTOP -> RELEASING -> PHONE`, with `FAILED` and
`RECOVERING` edges from every transition.

One long-lived host daemon should own those states and the child processes. It
should use explicit process identity, timeouts, health checks, and idempotent
rollback. The companion app and guest should submit requests to that daemon;
they should not indirectly trigger overlapping shell choreography. Shell is
fine for installation and probes. It is a poor init system layered on top of
two existing init systems. You already have Android init and systemd. Inventing
a third one out of pidfiles, `sleep 0.3`, and optimism is not convergence. It is
a cry for help.

### 3. The privilege model is bring-up quality

World-writable GPU, DRI, binder, and ashmem nodes are not a security model.
Matching guest UID 1000 to Android's `AID_SYSTEM` is clever in the way using the
same key for your shed and your bank vault is clever: convenient, until the
boundary matters. Or until somebody steals the shed. A guest user with access to Android binder and vendor devices
is not meaningfully isolated merely because phoc no longer runs as root.

The guest-to-host control channel is a writable directory interpreted by a root
Android daemon. Its command vocabulary is small, which helps, but the trust
boundary needs to be written down: who can mount it, who can create entries,
what prevents a compromised guest process from powering off the device, and
which binder contexts are truly required?

For a personal single-user prototype this risk can be accepted. For anything
described as portable or distributable, replace broad permissions with explicit
groups, SELinux domains, minimal device exposure, and authenticated IPC with
peer credential checks. Also produce a threat model. “The guest is Debian” is
not a threat model.

### 4. Builds are not reproducible

Several critical components are shallow-cloned from moving branches or
`master`, then modified by scripts using textual substitutions. Droidian's
staging repository is used directly. The libhybris build script is hundreds of
lines of conditional source surgery, including anchor-based `sed` and Python
rewrites. This is valuable as a lab notebook and terrible as a release process.
If the source changes underneath you and the replacement still happens to match,
congratulations: you have invented a patch system with worse diagnostics than
`patch`, a program old enough to have opinions about magnetic tape.

Pin every external source to a commit and record hashes for toolchains,
packages, boot inputs, and generated artifacts. Move source modifications into
normal patch files with clear provenance and tests. Fail if a patch no longer
applies; do not quietly infer that it may already be present. Produce a build
manifest alongside every installable image.

At present, rebuilding “the same version” next month can produce different code.
Version numbers on the Magisk zip do not repair that. Naming a mystery binary
`v0.4.1` merely gives the mystery a little hat.

### 5. There are two graphics architectures and no declared retirement plan

The libhybris/HWC path is the proven compatibility path. The Turnip/minigbm/DRM
path is the promising future path. Both are reasonable. Maintaining both
indefinitely, with separate compositor assumptions, environment contracts,
buffer models, and recovery behaviour, will double the number of ways pixels
can disappear.

Define the policy now:

- which device capabilities select each backend;
- which backend is preferred for internal and external displays;
- what feature parity is required before the native path becomes default;
- which libhybris patches remain necessary afterward; and
- whether the HWC path is a supported backend or a bring-up fallback.

Without that decision, every quirk will be “temporarily” fixed twice, and both
temporary fixes will become permanent because software archaeology is powered
entirely by bad intentions and forgotten TODOs.

### 6. “Universal” is premature

The project knows this, but the documentation still occasionally gets carried
away. A method demonstrated on one SM8150 phone, one ROM family, one composer
stack, one vendor GPU generation, and one ancient kernel is not universal. The
buffer protocol may be device-neutral; the system is not.

Portability becomes credible after a second device with a meaningfully different
axis—newer kernel, AIDL composer, Mali GPU, or different display stack—is brought
up primarily from generated configuration. Until then, call the device profile
work a portability hypothesis. It is a good hypothesis. It has not been tested.

The recon-to-configuration generator described in `north-star.md` is the right
next architectural step, but only after the current hard-coded facts are
enumerated rather than merely moved into a larger shell file. Moving constants
from six scripts into one enormous script is not abstraction. It is furniture
rearrangement during a fire.

### 7. The documentation has become a second runtime

`AGENTS.md` is useful, but it contains operational truth that code should know:
device nodes, ownership assumptions, backlight behaviour, current milestones,
kernel identity, session requirements, and forbidden launch flags. The README,
design spec, north star, progress report, and script comments sometimes describe
different eras of the project. For example, the original design calls external
HWC convergence cheap, while later work concludes concurrent output requires a
dmabuf-to-Android presenter because of DRM-master and composer constraints.

Historical documents should be labelled historical. The authoritative design
should be updated when the architecture changes, not merely supplemented by a
new dated discovery. Machine-readable device and build manifests should replace
facts copied between prose files. Documentation drift is a bug. It is just a bug
that wears glasses and insists it is “context.”

## What I would do next

### Priority zero: define the product honestly

State clearly that internal mode currently suspends Android framework service
execution. Decide whether that is an accepted product mode or a temporary
blocker. This single decision determines whether effort belongs in framework
integration or in making the suspend/resume boundary robust.

### Priority one: replace shell choreography with a supervisor

Write one small Android-side native daemon with:

- an explicit transition state machine;
- exclusive request serialization;
- child ownership and pidfd use where the kernel supports it, with a reliable
  fallback where it does not;
- monotonic deadlines instead of scattered sleeps;
- structured logs and reason codes;
- health probes for SF, the guest, compositor, input ownership, and display;
- rollback from every failed phase; and
- a boot-time recovery path that derives truth from the system rather than
  trusting stale files.

Do not begin by porting all 285 lines literally. First specify invariants: only
one display owner, only one input owner, Android recovery always reachable, and
failure at any step returns to a known state. If the new daemon is merely the old
shell script rewritten line-for-line in C++, I will know. I am not Linus, but my
evil-twin senses work perfectly well on unnecessary C++.

### Priority two: make the build auditable

Pin commits. Extract patches. Generate a lock manifest. Build installable
artifacts from a clean checkout. Add a command that reports exactly which kernel,
ROM, vendor image, toolchain, dependency commits, and patches produced the
running installation.

Then stop committing a museum of old zips and boot images to the main source
history. Keep release artifacts in releases or an artifact store, with hashes.
The source repository should explain how to reproduce them. Git is a source
control system, not the drawer where you keep every charger cable since 2013.

### Priority three: narrow the trust boundary

Document the threat model, inventory every guest-exposed device and mount, and
remove everything not required. Replace world permissions. Put the host agent in
a dedicated SELinux domain. Authenticate control requests and distinguish
ordinary session actions from destructive power operations.

### Priority four: finish external convergence before adding polish

The dmabuf-to-Android presenter is the actual headline architecture because it
can preserve a functioning Android panel while the guest uses the external
display. Prove buffer allocation, synchronization, hotplug, mode changes,
presenter death, and unplug recovery. Explicit synchronization cannot remain a
footnote if two independent stacks touch shared buffers.

Audio and backgrounds are nice. A correct ownership and fence protocol is the
project. Pixels without synchronization are not graphics; they are rumours.

### Priority five: prove portability with a hostile second device

Do not choose another nearly identical SM8150 phone and declare the abstraction
vindicated. Pick a device that breaks at least one major assumption. Record
which facts the recon generator discovers, which require a profile, which are
backend-class quirks, and which still demand source changes.

## Standards I would impose before calling this releasable

- One-command clean build from pinned inputs.
- No moving branches in release builds.
- No world-writable hardware nodes without a documented, unavoidable reason.
- No unbounded transition waits.
- No stale pidfile trusted without process identity validation.
- No claim that Android remains “fully live” while `system_server` is stopped.
- Fifty or more automated phone/desktop cycles with failure injection at every
  transition phase.
- Multi-hour soak with calls, alarms, charging changes, Wi-Fi roaming, Bluetooth,
  suspend/resume, display unplug, and low-memory pressure.
- Recovery proven when the compositor, guest, host daemon, SurfaceFlinger, or
  presenter dies at the worst possible time.
- A second-device port before “universal” appears anywhere except the roadmap.

## Final verdict

Determination is ambitious in the useful sense: it attacks the ugly integration
layer everyone else avoids, and it has already produced results that deserve to
be taken seriously. The architecture's core—Android PID 1, shared vendor kernel,
containerized GNU userspace, explicit display arbitration—is sound for the
stated goal.

The current implementation is also a magnificent pile of device-specific
knowledge balanced on process signals and shell loops. That is not an insult;
that is what successful hardware bring-up looks like. The mistake would be to
varnish it and ship the bring-up scaffolding as the architecture.

Keep the evidence culture. Keep the ruthless recovery testing. Keep the native
graphics track. Now consolidate ownership, make builds reproducible, stop
pretending a frozen Android framework is alive, and force the second device to
prove which abstractions are real.

If a future patch adds another background loop to `desktop-on` instead of fixing
the control plane, I will not kill anyone. Again, I am Tinus, the legally safe
evil twin. I will merely request that the patch be taken behind the shed and
humanely reverted, then ask why its author believed process supervision was best
implemented as a shell-themed advent calendar.

— **Tinus Lorvalds**

*Not Linus. Probably evil. Definitely unconvinced by your pidfiles.*
