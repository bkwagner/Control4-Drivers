#!/usr/bin/env python3
"""Package a driver directory into an unencrypted .c4z.

A .c4z is a zip archive. Composer Pro will install an unencrypted one for local
development, which is all we need during bring-up.

Usage:
    python tools/build_c4z.py driver/atv_spike
    python tools/build_c4z.py driver/atv_spike --out dist/
"""

import argparse
import sys
import zipfile
from pathlib import Path

# Files that live next to the driver source but should not ship inside it.
EXCLUDE_SUFFIXES = {".c4zproj", ".md"}
EXCLUDE_NAMES = {".DS_Store", "Thumbs.db"}


def _includable(path: Path) -> bool:
    return (
        path.is_file()
        and path.suffix not in EXCLUDE_SUFFIXES
        and path.name not in EXCLUDE_NAMES
    )


def build(src: Path, out_dir: Path, lib: Path | None) -> Path:
    if not src.is_dir():
        sys.exit(f"error: {src} is not a directory")

    manifest = src / "driver.xml"
    if not manifest.is_file():
        sys.exit(f"error: {manifest} not found - a driver needs a driver.xml")

    out_dir.mkdir(parents=True, exist_ok=True)
    target = out_dir / f"{src.name}.c4z"

    written = []
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as z:
        for path in sorted(src.rglob("*")):
            if not _includable(path):
                continue
            arcname = path.relative_to(src).as_posix()
            z.write(path, arcname)
            written.append(arcname)

        # Shared Lua modules live outside the driver dir so several drivers can use
        # them. They must land under lib/ in the archive, because driver code does
        # require('lib.protobuf') and DriverWorks maps dots to directories from the
        # c4z root.
        if lib is not None and lib.is_dir():
            for path in sorted(lib.rglob("*")):
                if not _includable(path):
                    continue
                arcname = f"lib/{path.relative_to(lib).as_posix()}"
                if arcname in written:
                    continue  # a driver-local file of the same name wins
                z.write(path, arcname)
                written.append(arcname)

    print(f"built {target}  ({target.stat().st_size:,} bytes)")
    for name in written:
        print(f"  + {name}")
    return target


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="driver source directory")
    parser.add_argument(
        "--out", type=Path, default=Path("dist"), help="output directory (default: dist/)"
    )
    parser.add_argument(
        "--lib", type=Path, default=Path("driver/lib"),
        help="shared Lua modules to bundle under lib/ (default: driver/lib)",
    )
    parser.add_argument(
        "--no-lib", action="store_true", help="do not bundle shared modules"
    )
    args = parser.parse_args()
    build(args.source, args.out, None if args.no_lib else args.lib)


if __name__ == "__main__":
    main()
