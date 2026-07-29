#!/usr/bin/env python3
"""Link checker for the Markdown docs — every relative link and anchor resolves.

Run from the repo root:  uv run --no-project test/docs_links.py

Catches the two failure modes that silently rot a docs tree: a file that moved
without its inbound links being updated, and an anchor that no longer matches a
heading after a rename. Both render fine and 404 only when a reader clicks.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = sorted([*ROOT.glob("*.md"), *ROOT.glob("docs/*.md")])

MD_LINK = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
HTML_HREF = re.compile(r'href="([^"]+)"')
HEADING = re.compile(r"^(#{1,6})\s+(.+?)\s*$", re.MULTILINE)
# fenced code blocks: a "# comment" inside one is not a heading
FENCE = re.compile(r"^```.*?^```", re.MULTILINE | re.DOTALL)


def slug(text: str) -> str:
    """GitHub's heading -> anchor rule.

    GitHub slugs the *rendered text* of the heading. Inline HTML is stripped as
    markup, but a code span's contents are escaped and survive as literal text —
    so `<Tab>` contributes "tab", while a real <b> contributes nothing. Splitting
    on code spans first is what keeps those two cases apart.
    """
    parts = re.split(r"(`[^`]*`)", text)
    rendered = "".join(
        p[1:-1] if p.startswith("`") and p.endswith("`") and len(p) > 1
        else re.sub(r"<[^>]+>", "", p)
        for p in parts
    )
    rendered = rendered.lower()
    rendered = re.sub(r"[^\w\s-]", "", rendered)  # keep word chars, spaces, hyphens
    # each space becomes its own hyphen — GitHub does NOT collapse runs, so
    # "blink.cmp / own" (two spaces once "/" is dropped) yields a double hyphen
    return re.sub(r"\s", "-", rendered.strip())


def anchors_of(path: Path) -> set[str]:
    body = FENCE.sub("", path.read_text(encoding="utf-8"))
    return {slug(m.group(2)) for m in HEADING.finditer(body)}


def links_of(path: Path) -> list[str]:
    body = FENCE.sub("", path.read_text(encoding="utf-8"))
    return [*(m.group(1) for m in MD_LINK.finditer(body)),
            *(m.group(1) for m in HTML_HREF.finditer(body))]


def main() -> int:
    anchor_cache: dict[Path, set[str]] = {}
    failures: list[str] = []
    checked = 0

    for doc in DOCS:
        rel = doc.relative_to(ROOT)
        for link in links_of(doc):
            if link.startswith(("http://", "https://", "mailto:")):
                continue
            checked += 1
            path_part, _, anchor = link.partition("#")

            target = doc if not path_part else (doc.parent / path_part).resolve()
            if path_part and not target.exists():
                failures.append(f"{rel}: missing file  -> {link}")
                continue

            if anchor:
                if target.suffix != ".md":
                    failures.append(f"{rel}: anchor into non-markdown -> {link}")
                    continue
                if target not in anchor_cache:
                    anchor_cache[target] = anchors_of(target)
                if anchor not in anchor_cache[target]:
                    failures.append(f"{rel}: no such anchor -> {link}")

    for f in failures:
        print(f"FAIL {f}")
    print(f"\n{checked} internal links checked across {len(DOCS)} documents")
    if failures:
        print(f"{len(failures)} broken")
        return 1
    print("all resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main())
