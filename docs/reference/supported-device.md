# Supported device and ROM

Status: current support statement
Authority: device qualification maintainers
Last reviewed: 2026-07-30

## Supported configuration

| Field | Value |
|---|---|
| Device | OnePlus 7 `guacamoleb` |
| SoC and GPU | SM8150 / Adreno 640 |
| ROM line | crDroid 12.11 / Android 16 |
| Composer | HIDL graphics composer 2.x |
| Mapper | QTI mapper and gralloc 4 |
| Kernel family | downstream 4.14.357 OpenELA-based build |

Internal Phosh desktop mode is proven on this configuration. It is an exclusive
panel mode and pauses Android framework services. Direct audio and concurrent
external convergence remain hardware qualification work.

## Not supported yet

AIDL composer, Mali, different Qualcomm generations, GKI kernels, alternate
boot layouts, and other ROM/device combinations are porting work. A generated
profile is not a support claim. Read [universalisation](../universalisation.md)
for the current portability limits.
