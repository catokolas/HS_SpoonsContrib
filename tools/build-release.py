#!/usr/bin/env python3
"""tools/build-release.py

Produce the SpoonInstall-compatible artifacts in the repo:

  Spoons/<Name>.spoon.zip     # one per <Name>.spoon dir, deterministic
  docs/docs.json              # aggregated array of per-Spoon docs.json blobs

SpoonInstall fetches both of these via raw.githubusercontent.com when a
user calls `spoon.SpoonInstall:asyncInstallSpoonFromRepo(name, "catokolas")`.

Run from the repo root:

  python3 tools/build-release.py            # rebuild
  python3 tools/build-release.py --check    # exit 1 if artifacts are stale
"""

import json
import os
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

REPO  = Path(".").resolve()
SPOONS_OUT = REPO / "Spoons"
DOCS_OUT   = REPO / "docs" / "docs.json"

# Path components inside <Name>.spoon/ that mark something we should NOT
# ship in the installable zip. Matched against any component of the file's
# path (so excluding `.claude` skips the whole directory).
# spoon-manifest.json is our authoring metadata for the Mac app — users
# installing via SpoonInstall don't need it. PRIVATE_NOTES.md / TODO.md
# are workspace notes, never meant to publish. .claude/ is per-user
# Claude Code state.
EXCLUDE_COMPONENTS = {
    "spoon-manifest.json",
    "PRIVATE_NOTES.md",
    "TODO.md",
    "INTERNALS.md",
    ".DS_Store",
    ".claude",
    ".git",
    ".gitignore",
}


def _excluded(rel_path: Path) -> bool:
    return any(part in EXCLUDE_COMPONENTS for part in rel_path.parts)


def find_spoons():
    # Only ship spoons that have a spoon-manifest.json. Same gate as
    # tools/build-manifest.lua and tools/validate-manifest.lua, so
    # "no manifest = not a shipping spoon" is a uniform repo-wide
    # convention. WIP / private spoon dirs without a manifest stay
    # out of Spoons/*.zip and docs/docs.json automatically.
    return sorted(p for p in REPO.iterdir()
                  if p.is_dir()
                  and p.name.endswith(".spoon")
                  and (p / "spoon-manifest.json").exists())


def deterministic_zip(spoon_dir: Path, out_path: Path):
    """Build a stable zip: sorted entries, fixed timestamp, fixed perms,
    fixed compression. Identical inputs produce byte-identical output."""
    fixed_dt = (2000, 1, 1, 0, 0, 0)
    spoon_name = spoon_dir.name  # "FocusFollowsMouse.spoon"

    files = []
    for root, dirs, names in os.walk(spoon_dir):
        # Prune excluded subdirs in place so os.walk doesn't recurse into them.
        dirs[:] = sorted(d for d in dirs if d not in EXCLUDE_COMPONENTS)
        for name in sorted(names):
            p = Path(root) / name
            rel = p.relative_to(spoon_dir)
            if _excluded(rel):
                continue
            arcname = f"{spoon_name}/" + str(rel)
            files.append((arcname, p))

    files.sort(key=lambda t: t[0])

    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = out_path.with_suffix(out_path.suffix + ".tmp")
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        # Top-level `<Name>.spoon/` directory entry. SpoonInstall's
        # post-download validation runs `unzip -l <zip> '*.spoon/'` and
        # rejects the archive if no directory entries match — file-only
        # zips fail with "should contain exactly one spoon".
        dir_zi = zipfile.ZipInfo(f"{spoon_name}/", date_time=fixed_dt)
        dir_zi.external_attr = (0o040755 << 16) | 0x10  # S_IFDIR + MS-DOS dir bit
        dir_zi.compress_type = zipfile.ZIP_STORED
        zf.writestr(dir_zi, b"")
        for arcname, src in files:
            zi = zipfile.ZipInfo(arcname, date_time=fixed_dt)
            zi.external_attr = 0o644 << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            with open(src, "rb") as f:
                zf.writestr(zi, f.read())
    tmp.replace(out_path)


def build_docs_index(spoon_dirs):
    """Hammerspoon's docs/docs.json is a flat array of module-docs blobs,
    one per Spoon. Each per-Spoon docs.json is itself `[<module-obj>]`
    (an array of length 1). We unwrap and concatenate, sorted by name."""
    modules = []
    for spoon_dir in spoon_dirs:
        per_spoon = spoon_dir / "docs.json"
        if not per_spoon.is_file():
            print(f"warn: {per_spoon} missing — skipping in docs index",
                  file=sys.stderr)
            continue
        with open(per_spoon, "rb") as f:
            data = json.load(f)
        if isinstance(data, list):
            modules.extend(data)
        elif isinstance(data, dict):
            modules.append(data)
        else:
            raise SystemExit(f"{per_spoon}: unexpected top-level type "
                             f"{type(data).__name__}")
    modules.sort(key=lambda m: m.get("name", ""))
    return modules


def write_json(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(value, indent=2, sort_keys=True,
                      ensure_ascii=False) + "\n"
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)


def files_identical(a: Path, b: Path) -> bool:
    if not a.is_file() or not b.is_file():
        return False
    return a.read_bytes() == b.read_bytes()


def main():
    check_mode = "--check" in sys.argv[1:]
    spoons = find_spoons()
    if not spoons:
        raise SystemExit("no *.spoon directories found in cwd")

    if check_mode:
        with tempfile.TemporaryDirectory() as tmpd:
            tmp = Path(tmpd)
            (tmp / "Spoons").mkdir()
            stale = []
            for s in spoons:
                tmp_zip = tmp / "Spoons" / f"{s.name}.zip"
                deterministic_zip(s, tmp_zip)
                ref_zip = SPOONS_OUT / f"{s.name}.zip"
                if not files_identical(tmp_zip, ref_zip):
                    stale.append(str(ref_zip.relative_to(REPO)))
            tmp_docs = tmp / "docs.json"
            write_json(tmp_docs, build_docs_index(spoons))
            if not files_identical(tmp_docs, DOCS_OUT):
                stale.append(str(DOCS_OUT.relative_to(REPO)))
        if stale:
            print("Release artifacts are out of date:", file=sys.stderr)
            for s in stale:
                print(f"  {s}", file=sys.stderr)
            print("Run: python3 tools/build-release.py", file=sys.stderr)
            sys.exit(1)
        print(f"Release artifacts up to date ({len(spoons)} Spoons).",
              file=sys.stderr)
        return

    SPOONS_OUT.mkdir(parents=True, exist_ok=True)
    for s in spoons:
        out = SPOONS_OUT / f"{s.name}.zip"
        deterministic_zip(s, out)
        print(f"  wrote {out.relative_to(REPO)} "
              f"({out.stat().st_size:,} bytes)", file=sys.stderr)
    write_json(DOCS_OUT, build_docs_index(spoons))
    print(f"  wrote {DOCS_OUT.relative_to(REPO)}", file=sys.stderr)
    print(f"done ({len(spoons)} Spoons).", file=sys.stderr)


if __name__ == "__main__":
    main()
