#!/usr/bin/env python3
"""Classify a Determination recon report into capabilities and hard gates."""

from __future__ import annotations

import re
import sys
from pathlib import Path


def read(report: Path, name: str) -> str:
    path = report / f"{name}.txt"
    return path.read_text(errors="replace") if path.exists() else ""


def highest_version(text: str, pattern: str) -> str:
    versions = re.findall(pattern, text, flags=re.IGNORECASE)
    return max(versions, key=lambda v: tuple(map(int, v.split(".")))) if versions else "unknown"


def enabled(config: str, option: str) -> bool:
    return re.search(rf"^CONFIG_{re.escape(option)}=(?:y|m)$", config, re.MULTILINE) is not None


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print("usage: classify.py REPORT_DIR [OUTPUT_DIR]", file=sys.stderr)
        return 2

    report = Path(sys.argv[1])
    output = Path(sys.argv[2]) if len(sys.argv) == 3 else report
    if not report.is_dir():
        print(f"error: report directory not found: {report}", file=sys.stderr)
        return 2
    output.mkdir(parents=True, exist_ok=True)

    graphics = "\n".join(
        read(report, name)
        for name in ("lshal-graphics", "aidl-composer", "vendor-hw-libs", "props-graphics")
    )
    devices = "\n".join(read(report, name) for name in ("dev-gpu", "dev-binder", "dev-drm"))
    kernel_config = read(report, "kernel-config")
    kernel_version_text = read(report, "kernel-version")
    boot = read(report, "boot-layout")

    if re.search(r"graphics\.composer3|composer3[^\n]*IComposer/default", graphics, re.IGNORECASE):
        composer = "aidl3"
    else:
        composer_version = highest_version(graphics, r"graphics\.composer@(2\.[0-9]+)")
        composer = f"hidl{composer_version}" if composer_version != "unknown" else "unknown"

    mapper = highest_version(graphics, r"(?:graphics\.)?mapper@(\d+\.\d+)")
    allocator = highest_version(graphics, r"(?:graphics\.)?allocator@(\d+\.\d+)")

    if "/dev/kgsl-3d0" in devices or re.search(r"\bkgsl\b", graphics, re.IGNORECASE):
        gpu = "adreno"
    elif "/dev/mali" in devices or re.search(r"\bmali\b", graphics, re.IGNORECASE):
        gpu = "mali"
    elif "/dev/pvr" in devices or re.search(r"powervr|\bpvr\b", graphics, re.IGNORECASE):
        gpu = "powervr"
    elif "/dev/galcore" in devices or re.search(r"vivante|galcore", graphics, re.IGNORECASE):
        gpu = "vivante"
    else:
        gpu = "unknown"

    binder = "binderfs" if "/dev/binderfs" in devices else (
        "direct" if re.search(r"/dev/(?:hw|vnd)?binder\b", devices) else "unknown"
    )
    drm = "yes" if re.search(r"(?:/dev/dri/|\b)card\d+\b", devices) else "no"

    kernel_match = re.search(r"Linux version\s+(\d+)\.(\d+)", kernel_version_text)
    kernel = ".".join(kernel_match.groups()) if kernel_match else "unknown"
    required_kernel = ("NAMESPACES", "PID_NS", "IPC_NS", "USER_NS", "NET_NS", "VETH")
    missing_kernel = [option for option in required_kernel if not enabled(kernel_config, option)]

    partitions = set(re.findall(r"^partition=([a-zA-Z0-9_-]+)$", boot, re.MULTILINE))
    if "init_boot" in partitions:
        boot_layout = "init_boot"
    elif "vendor_boot" in partitions:
        boot_layout = "vendor_boot"
    elif "boot" in partitions:
        boot_layout = "boot"
    else:
        boot_layout = "unknown"

    blockers: list[str] = []
    work: list[str] = []
    if composer == "aidl3":
        blockers.append("AIDL composer3 is detected; the current libhybris HWC backend supports HIDL composer2 only")
    elif composer == "unknown":
        blockers.append("no supported composer HAL was identified")
    if mapper == "unknown":
        blockers.append("no graphics mapper version was identified")
    if gpu == "unknown":
        blockers.append("GPU family and device node are unknown")
    elif gpu != "adreno":
        work.append(f"{gpu} device nodes are mountable, but rendering is unproven")
    if missing_kernel:
        work.append("kernel rebuild/configuration required: " + ", ".join(f"CONFIG_{x}" for x in missing_kernel))
    if binder == "unknown":
        blockers.append("no host binder device layout was identified")
    if boot_layout in ("vendor_boot", "init_boot"):
        work.append(f"{boot_layout} packaging is detected but not implemented")
    elif boot_layout == "unknown":
        work.append("boot image layout was not identified")

    if blockers:
        status = "blocked"
    elif work:
        status = "porting-required"
    else:
        status = "bringup-ready"

    capabilities = {
        "DET_CAP_STATUS": status,
        "DET_CAP_COMPOSER": composer,
        "DET_CAP_MAPPER": mapper,
        "DET_CAP_ALLOCATOR": allocator,
        "DET_CAP_GPU": gpu,
        "DET_CAP_BINDER": binder,
        "DET_CAP_DRM": drm,
        "DET_CAP_KERNEL": kernel,
        "DET_CAP_BOOT_LAYOUT": boot_layout,
        "DET_CAP_KERNEL_MISSING": ",".join(missing_kernel),
    }
    with (output / "capabilities.conf").open("w") as f:
        f.write("# Generated by recon/classify.py; do not hand-edit.\n")
        for key, value in capabilities.items():
            f.write(f"{key}={value}\n")

    with (output / "compatibility.txt").open("w") as f:
        f.write(f"Determination compatibility: {status}\n\n")
        f.write("Detected\n")
        for key, value in capabilities.items():
            if key != "DET_CAP_STATUS" and value:
                f.write(f"- {key.removeprefix('DET_CAP_').lower()}: {value}\n")
        if blockers:
            f.write("\nBlockers\n")
            for item in blockers:
                f.write(f"- {item}\n")
        if work:
            f.write("\nRequired porting work\n")
            for item in work:
                f.write(f"- {item}\n")

    print(f"Compatibility: {status}")
    for item in blockers:
        print(f"BLOCKER: {item}")
    for item in work:
        print(f"PORTING: {item}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
