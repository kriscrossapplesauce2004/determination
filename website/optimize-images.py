#!/usr/bin/env python3
"""Losslessly recompress site PNGs, replacing only smaller verified files."""
from __future__ import annotations
from pathlib import Path
from tempfile import NamedTemporaryFile
from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parent
for path in [ROOT / "phosh-on-device.png", *sorted((ROOT / "device-shots").glob("*.png"))]:
    with Image.open(path) as before:
        before.load()
        with NamedTemporaryFile(suffix=".png", delete=False, dir=path.parent) as handle:
            candidate = Path(handle.name)
        before.save(candidate, format="PNG", optimize=True, compress_level=9)
    with Image.open(candidate) as after:
        after.load()
        if before.mode != after.mode or before.size != after.size or ImageChops.difference(before.convert("RGBA"), after.convert("RGBA")).getbbox():
            candidate.unlink(); raise SystemExit(f"pixel verification failed: {path}")
    if candidate.stat().st_size < path.stat().st_size:
        candidate.replace(path)
    else:
        candidate.unlink()
