#!/usr/bin/env python3
"""restore_repomix.py — restore files packed by Repomix back onto disk.

Repomix (https://repomix.com) packs a repository into one text file shaped
like XML, with each source file embedded raw between
`<file path="...">` / `</file>` markers. Critically, that content is *not*
escaped — a `<`, `>`, or `&` inside your actual source shows up in the
packed output completely unchanged. That means a real XML parser cannot be
used here (it will choke on the first literal `<` inside a packed file), so
this script deliberately parses the format line-by-line instead: a file's
body is everything between a `<file path="...">` line and the next line
that is *exactly* `</file>`.

Treat a repomix snapshot as a lightweight backup: this script restores
exactly the files present in it, and never touches or deletes anything
that's on disk but absent from the snapshot (repomix snapshots are commonly
partial — filtered by --include, .gitignore, etc. — so this is a restore,
not a sync).

Usage:
    # Preview what would happen (default — this never writes anything)
    ./restore_repomix.py repomix-output.xml

    # Preview with full unified diffs for every file that would change
    ./restore_repomix.py repomix-output.xml --diff

    # Actually write the files (existing files that would change are
    # backed up first, see --no-backup / --backup-dir)
    ./restore_repomix.py repomix-output.xml --apply

    # Restore into a specific repo checkout instead of the current directory
    ./restore_repomix.py repomix-output.xml --apply --target /path/to/repo

    # Only restore a subtree
    ./restore_repomix.py repomix-output.xml --apply --only src/window/

    # Just list the files contained in the snapshot
    ./restore_repomix.py repomix-output.xml --list

Limitations:
  - Because content is embedded unescaped, a packed file whose content
    contains a line that is *exactly* "</file>" would be mis-parsed as
    ending early. This is an inherent property of Repomix's own output
    format, not something this script can fully work around. --list and
    --diff make it easy to sanity-check file boundaries before trusting
    --apply on an unfamiliar snapshot.
  - Binary files are never included by Repomix in the first place, so
    there is nothing for this script to restore for them either.
"""

from __future__ import annotations

import argparse
import datetime
import difflib
import sys
from pathlib import Path

FILE_OPEN_PREFIX = '<file path="'
FILE_OPEN_SUFFIX = '">'
FILE_CLOSE = "</file>"


class PackedFile:
    __slots__ = ("path", "content")

    def __init__(self, path: str, content: str) -> None:
        self.path = path
        self.content = content


def parse_repomix(xml_path: Path) -> list[PackedFile]:
    """Extract (path, content) pairs from a Repomix XML-flavored output file.

    Deliberately line-oriented rather than a real XML parse — see the
    module docstring for why.
    """
    text = xml_path.read_text(encoding="utf-8", errors="surrogateescape")
    lines = text.split("\n")

    files: list[PackedFile] = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        if line.startswith(FILE_OPEN_PREFIX) and line.endswith(FILE_OPEN_SUFFIX):
            path = line[len(FILE_OPEN_PREFIX):-len(FILE_OPEN_SUFFIX)]
            body_lines: list[str] = []
            i += 1
            closed = False
            while i < n:
                if lines[i] == FILE_CLOSE:
                    closed = True
                    break
                body_lines.append(lines[i])
                i += 1
            if not closed:
                raise ValueError(
                    f"Unterminated <file> entry for {path!r} "
                    f"(no matching {FILE_CLOSE!r} line found before EOF)"
                )
            content = "\n".join(body_lines) + "\n"
            files.append(PackedFile(path=path, content=content))
        i += 1

    if not files:
        raise ValueError(
            'No <file path="..."> entries found — is this really a '
            "Repomix XML-style output?"
        )
    return files


def is_safe_relative_path(target_root: Path, rel_path: str) -> bool:
    """Reject paths that would escape target_root (e.g. '../../etc/passwd')."""
    if not rel_path or rel_path.startswith(("/", "\\")):
        return False
    dest = (target_root / rel_path).resolve()
    try:
        dest.relative_to(target_root.resolve())
    except ValueError:
        return False
    return True


def backup_existing(dest: Path, backup_root: Path, rel_path: str) -> None:
    backup_path = backup_root / rel_path
    backup_path.parent.mkdir(parents=True, exist_ok=True)
    backup_path.write_bytes(dest.read_bytes())


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Restore files packed by Repomix back onto disk.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("repomix_file", type=Path, help="Path to the repomix XML output")
    ap.add_argument(
        "--target", "-C", type=Path, default=Path("."),
        help="Directory to restore into (default: current directory)",
    )
    ap.add_argument(
        "--apply", action="store_true",
        help="Actually write files. Without this flag, only a preview is shown.",
    )
    ap.add_argument(
        "--diff", action="store_true",
        help="Show a unified diff for every file that would change.",
    )
    ap.add_argument(
        "--list", action="store_true",
        help="Just list the file paths contained in the snapshot and exit.",
    )
    ap.add_argument(
        "--only", action="append", default=[], metavar="PREFIX",
        help="Restrict to paths starting with PREFIX. Repeatable.",
    )
    ap.add_argument(
        "--no-backup", action="store_true",
        help="Skip backing up existing files before overwriting them (not recommended).",
    )
    ap.add_argument(
        "--backup-dir", type=Path, default=None,
        help="Where to store pre-overwrite backups "
             "(default: <target>/.repomix-restore-backup/<timestamp>/)",
    )
    args = ap.parse_args()

    if not args.repomix_file.is_file():
        ap.error(f"{args.repomix_file}: not a file")

    try:
        packed_files = parse_repomix(args.repomix_file)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    if args.only:
        packed_files = [f for f in packed_files if any(f.path.startswith(p) for p in args.only)]

    if args.list:
        for f in packed_files:
            print(f.path)
        return 0

    target_root = args.target.resolve()
    target_root.mkdir(parents=True, exist_ok=True)

    created: list[PackedFile] = []
    changed: list[PackedFile] = []
    unchanged: list[PackedFile] = []
    unsafe: list[str] = []

    for f in packed_files:
        if not is_safe_relative_path(target_root, f.path):
            unsafe.append(f.path)
            continue
        dest = target_root / f.path
        if not dest.exists():
            created.append(f)
        else:
            existing = dest.read_text(encoding="utf-8", errors="surrogateescape")
            if existing == f.content:
                unchanged.append(f)
            else:
                changed.append(f)

    if unsafe:
        print("refusing to touch paths that escape the target directory:", file=sys.stderr)
        for p in unsafe:
            print(f"  {p}", file=sys.stderr)
        return 1

    print(f"repomix snapshot: {args.repomix_file}")
    print(f"target directory: {target_root}")
    print(f"  {len(created)} file(s) to create")
    print(f"  {len(changed)} file(s) to overwrite (content differs)")
    print(f"  {len(unchanged)} file(s) already match — no action")
    print()

    if args.diff:
        for f in changed:
            dest = target_root / f.path
            existing = dest.read_text(encoding="utf-8", errors="surrogateescape")
            diff = difflib.unified_diff(
                existing.splitlines(keepends=True),
                f.content.splitlines(keepends=True),
                fromfile=f"a/{f.path}",
                tofile=f"b/{f.path}",
            )
            sys.stdout.writelines(diff)
            print()

    if not args.apply:
        if created or changed:
            print("Dry run only — rerun with --apply to write these changes.")
        else:
            print("Nothing to do.")
        return 0

    backup_root = args.backup_dir
    do_backup = not args.no_backup and bool(changed)
    if do_backup and backup_root is None:
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        backup_root = target_root / ".repomix-restore-backup" / stamp

    for f in created:
        dest = target_root / f.path
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(f.content, encoding="utf-8", errors="surrogateescape")
        print(f"created   {f.path}")

    for f in changed:
        dest = target_root / f.path
        if do_backup:
            backup_existing(dest, backup_root, f.path)
        dest.write_text(f.content, encoding="utf-8", errors="surrogateescape")
        print(f"restored  {f.path}")

    if do_backup:
        print()
        print(f"Pre-overwrite backups saved under: {backup_root}")

    print()
    print(f"Done: {len(created)} created, {len(changed)} restored, {len(unchanged)} already up to date.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
