# Device and boot profiles

Status: current reference
Authority: lifecycle and profile maintainers
Last reviewed: 2026-07-30

Runtime discovery produces a reviewed device configuration. Exact-match files
in `device-profiles/` hold evidence-backed overrides. Unknown devices must not
inherit OnePlus-specific values.

Current profile keys cover backlight, Wi-Fi interface, HWC output, panel size,
battery gauge, input quirk, DRM nodes, graphics renderer, and GBM provider.
See [universalisation](../universalisation.md) for key consumers and defaults.

Linux-first boot behavior is experimental and device-profile gated. On the
verified OnePlus 7 profile, enable it from the host with:

```sh
det linux-first enable
```

The next boot starts Android's required kernel, init, vendor HAL, radio, power,
thermal, binder, and networking layers, then hands the primary session to the
Linux guest. The phone profile is restored automatically after one failed
attempt. Disable the behavior with `det linux-first disable`; use
`det linux-first apply` to test the saved profile without rebooting.

Linux-first uses the structured control operation when transition ownership is
enabled. While the daemon remains observe-only, it falls back to the fixed,
bounded `guest-start` and `desktop-on` adapters that already implement the
qualified internal-panel handoff. Actual boot and recovery behavior still
requires device qualification before release.
