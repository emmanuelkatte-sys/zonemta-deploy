#!/usr/bin/env python3
"""Pack zonemta-bundle -> gui/assets/zonemta-bundle-v1.0.tar.gz + update bundle_zonemta.txt"""
from __future__ import annotations

import sys
from pathlib import Path

ASSETS = Path(__file__).resolve().parent
sys.path.insert(0, str(ASSETS))

from _repack_common import pack_tree, sha256_file, write_bundle_meta

SRC = ASSETS / "zonemta-bundle"
OUT = ASSETS / "zonemta-bundle-v1.4.tar.gz"
META = ASSETS / "bundle_zonemta.txt"
ARC_TOP = "zonemta-bundle"


def main() -> None:
    if not (SRC / "package.json").is_file() or not (SRC / "index.js").is_file():
        raise SystemExit(f"missing source: {SRC}")
    if not (SRC / "node_modules").is_dir():
        raise SystemExit(f"missing node_modules in {SRC} (extract zonemta-bundle.tar.gz first)")
    print(f"Packing {SRC} -> {OUT}")
    added, skipped = pack_tree(SRC, OUT, arc_prefix=ARC_TOP)
    digest = sha256_file(OUT)
    size_mb = OUT.stat().st_size / (1024 * 1024)
    write_bundle_meta(
        META,
        title="ZonePMTA bundle. SHA256 is the local tar; frozen EXE uses BUNDLE_URL.",
        bundled=OUT.name,
        sha256=digest,
    )
    print(f"Done: {size_mb:.1f} MB  files={added} skipped={skipped}")
    print(f"SHA256: {digest}")
    print(f"Updated: {META}")


if __name__ == "__main__":
    main()
