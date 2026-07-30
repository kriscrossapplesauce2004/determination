#!/usr/bin/env python3
"""Generate or verify the complete tracked-artifact index."""
from __future__ import annotations
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "artifacts" / "index.json"

def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

def data() -> dict[str, object]:
    tracked = subprocess.check_output(["git", "ls-files", "artifacts"], cwd=ROOT, text=True).splitlines()
    entries = []
    for raw in sorted(tracked):
        path = ROOT / raw
        if path.name in {"manifest.json", "index.json", "build-index.py"} or not path.is_file():
            continue
        entries.append({"path": raw, "sha256": digest(path), "size": path.stat().st_size,
                        "retention": "tracked-evidence"})
    return {"schema": 1, "generated_by": "artifacts/build-index.py", "entries": entries}

def main() -> int:
    rendered = json.dumps(data(), indent=2, sort_keys=True) + "\n"
    if len(sys.argv) == 2 and sys.argv[1] == "--write":
        OUT.write_text(rendered, encoding="utf-8")
        return 0
    if len(sys.argv) == 2 and sys.argv[1] == "--check":
        if not OUT.exists() or OUT.read_text(encoding="utf-8") != rendered:
            print("artifact index is stale; run python3 artifacts/build-index.py --write", file=sys.stderr)
            return 1
        print("artifact index is current")
        return 0
    print("usage: artifacts/build-index.py [--write|--check]", file=sys.stderr)
    return 2

if __name__ == "__main__":
    raise SystemExit(main())
