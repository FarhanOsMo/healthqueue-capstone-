"""Check that every relative link in the repository's Markdown files points to an existing file/anchor-free path."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKIP = {".venv", ".local", ".git", ".terraform", "node_modules"}
LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")


def main() -> int:
    bad = []
    files = [p for p in ROOT.rglob("*.md") if not SKIP.intersection(p.relative_to(ROOT).parts)]
    for md in files:
        for target in LINK.findall(md.read_text(encoding="utf-8")):
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            path = target.split("#")[0]
            if path and not (md.parent / path).resolve().exists():
                bad.append(f"{md.relative_to(ROOT)} -> {target}")
    print(f"checked {len(files)} Markdown files")
    for b in bad:
        print("BROKEN", b)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
