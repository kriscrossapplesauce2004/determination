# Determination documentation

Status: current navigation
Authority: repository documentation maintainers
Last reviewed: 2026-07-30

Determination keeps Android as PID 1 while a Debian guest shares the downstream
kernel. The project has one supported target: OnePlus 7 `guacamoleb` on the
tested crDroid 12.11 / Android 16 line.

Internal desktop mode is time-sliced. It stops SurfaceFlinger and freezes
`system_server` while the guest owns the panel. Android is not fully live in
that mode. External convergence is designed to keep Android live, but is not
yet hardware-qualified end to end.

## Start here

| Need | Read |
|---|---|
| Understand scope and supported state | [supported device reference](reference/supported-device.md) |
| Build or package on a host | [build and package guide](guides/build-and-package.md) |
| Install, upgrade, or return to phone mode | [install and recovery guide](guides/install-and-recovery.md) |
| Use the companion and guest day to day | [daily use guide](guides/daily-use.md) |
| Diagnose a failure or collect qualification evidence | [troubleshooting and qualification](operations/troubleshooting-and-qualification.md) |

## Browse by subject

- [Architecture](architecture/README.md): design, graphics, audio, and app API.
- [Reference](reference/README.md): device profile, boot profile, support, and releases.
- [Operations](operations/README.md): recovery, diagnostics, and qualification.
- [History](history/README.md): dated evidence and commentary that is not current instruction.

Use `python3 docs/check-links.py` before changing Markdown navigation.
