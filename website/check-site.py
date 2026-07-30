#!/usr/bin/env python3
"""Small dependency-free structural and accessibility check for static pages."""
from __future__ import annotations
from html.parser import HTMLParser
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent

class Page(HTMLParser):
    def __init__(self) -> None:
        super().__init__(); self.tags = []; self.images = []; self.h1 = 0
    def handle_starttag(self, tag, attrs):
        self.tags.append(tag); attrs = dict(attrs)
        if tag == "img": self.images.append(attrs)
        if tag == "h1": self.h1 += 1

def main() -> int:
    errors = []
    for path in sorted(ROOT.glob("*.html")):
        page = Page(); page.feed(path.read_text(encoding="utf-8"))
        for required in ("html", "head", "body", "main", "nav", "footer"):
            if required not in page.tags: errors.append(f"{path.name}: missing <{required}>")
        if page.h1 != 1: errors.append(f"{path.name}: expected one h1, found {page.h1}")
        for image in page.images:
            if "alt" not in image or not image["alt"].strip(): errors.append(f"{path.name}: image missing useful alt")
    if errors:
        print("\n".join(errors), file=sys.stderr); return 1
    print("static site structure and image-alt checks passed")
    return 0
if __name__ == "__main__": raise SystemExit(main())
