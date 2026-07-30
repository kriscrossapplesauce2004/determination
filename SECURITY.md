# Security policy

## Supported security boundary

Determination is currently a personal-device alpha. The guest and host control
boundary is prototype-grade. Do not rely on it to isolate untrusted desktop
software or Android applications.

## Reporting a vulnerability

Do not file public issues containing exploit details, credentials, private
device data, or boot images. Report privately to the repository maintainer
through the contact method listed in the repository profile. Include a minimal
reproduction, affected commit, impact, and whether a device mutation is needed
to reproduce it.

## Security expectations for changes

- Privileged operations must be named, bounded, authenticated, and logged.
- Do not add arbitrary shell execution, arbitrary path writes, or broad device
  permissions across a trust boundary.
- Validate sizes, descriptor counts, and peer identity before allocating or
  importing resources.
- Keep recovery actions available when a privileged component fails.
