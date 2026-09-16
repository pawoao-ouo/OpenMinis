#!/usr/bin/env python3
"""Remove localization keys that no longer have any source reference.

[round24 / T-roles-identity-09-16] The catalog is otherwise append-only —
`add_localization.py` only adds. Deleting a key is only safe when NO .swift
file mentions it, so this checks the whole tree first and refuses otherwise.

IMPORTANT: this edits the file as TEXT, removing only the key's own line
block. Re-serialising via json.dumps would rewrite the whole catalog
(Xcode writes `" : "` with a space before the colon, json.dumps does not),
turning a two-key deletion into a 69k-line diff.

Usage: python3 scripts/remove_localization.py "Key one" "Key two" [--dry-run]
"""
import argparse
import json
import sys
from pathlib import Path

CATALOG = Path(__file__).resolve().parent.parent / "src/ios/Localizable.xcstrings"
SRC = Path(__file__).resolve().parent.parent / "src/ios"


def referenced(key: str) -> list[str]:
    """Files that still contain this key as a literal."""
    hits = []
    for f in SRC.rglob("*.swift"):
        try:
            if key in f.read_text(encoding="utf-8"):
                hits.append(str(f.relative_to(SRC.parent.parent)))
        except (UnicodeDecodeError, OSError):
            continue
    return hits


def remove_key_block(lines: list[str], key: str) -> int:
    """Delete the key's block; return its first line index, or -1."""
    # Xcode writes the key at 4-space indent: `    "KEY" : {`
    header = f'    {json.dumps(key, ensure_ascii=False)} : {{'
    start = next((i for i, l in enumerate(lines) if l.rstrip("\n") == header), -1)
    if start < 0:
        return -1
    # Walk forward to the matching close: the line `    },` at the same indent.
    depth = 0
    for i in range(start, len(lines)):
        depth += lines[i].count("{") - lines[i].count("}")
        if depth == 0 and i > start:
            end = i  # inclusive
            del lines[start:end + 1]
            return start
    return -1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("keys", nargs="+")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    text = CATALOG.read_text(encoding="utf-8")
    catalog = json.loads(text)
    strings = catalog["strings"]

    to_remove, refused, absent = [], [], []
    for k in args.keys:
        if k not in strings:
            absent.append(k)
            continue
        hits = referenced(k)
        if hits:
            refused.append((k, hits))
        else:
            to_remove.append(k)

    for k in to_remove:
        print(f"  - remove {k!r}")
    for k in absent:
        print(f"  ~ absent {k!r}")
    for k, hits in refused:
        print(f"  ! REFUSED {k!r} — still referenced in {len(hits)} file(s):")
        for h in hits[:5]:
            print(f"      {h}")

    if refused:
        print("\nrefusing to touch referenced keys; remove the references first",
              file=sys.stderr)
        return 1

    if args.dry_run:
        print("\n--dry-run: no changes written.")
        return 0

    lines = text.splitlines(keepends=True)
    for k in to_remove:
        if remove_key_block(lines, k) < 0:
            print(f"  ! could not locate block for {k!r} — aborting, nothing written",
                  file=sys.stderr)
            return 1

    out = "".join(lines)
    # Verify the result is still valid JSON and that exactly the intended keys
    # are gone before writing.
    after = json.loads(out)
    if len(after["strings"]) != len(strings) - len(to_remove):
        print("  ! key count mismatch — aborting, nothing written", file=sys.stderr)
        return 1

    CATALOG.write_text(out, encoding="utf-8")
    print(f"\nremoved {len(to_remove)} key(s); catalog now {len(after['strings'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
