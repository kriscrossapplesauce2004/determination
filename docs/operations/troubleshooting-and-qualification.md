# Troubleshooting and qualification

Status: current operations reference
Authority: device qualification maintainers
Last reviewed: 2026-07-30

## Safe host checks

Run `release/check.sh check`, `python3 docs/check-links.py`, and the relevant
component tests before a device run. These checks do not validate display
handoff, flashing, or recovery on hardware.

## Common conditions

| Condition | Safe response |
|---|---|
| Unknown or unsupported device report | Stop and review recon output before installation. |
| Transition reports recovery-required | Use the independent phone restore path and capture bounded logs. |
| Guest fails to start | Check profile, container health, and host diagnostics before retrying. |
| Presenter reports degraded startup | Treat external output as unavailable; do not claim it is ready. |
| Direct audio is unavailable | Keep audio disabled; it is not a fallback to Android PCM transport. |

## Qualification record

Every hardware run records the commit, release manifest, device profile digest,
command, result, timing, bounded logs, and recovery outcome. The internal-mode
release gate includes repeated transitions, failure injection, and an extended
soak. External output and direct audio require their own gates.
