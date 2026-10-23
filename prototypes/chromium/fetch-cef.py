#!/usr/bin/env python3
"""Fetch the pinned Apple Silicon CEF SDK outside the repository."""
import hashlib
import os
from pathlib import Path
import platform
import sys
import tarfile
import urllib.request

VERSION = "156.0.7+g47dbc1d+chromium-156.0.8078.17"
NAME = f"cef_binary_{VERSION}_macosarm64_minimal"
SHA256 = "d9a4e98dfde499bfecc49ec2290395fbfffc3923fed5f967bb95c6e05e03e903"


def main():
    if sys.version_info < (3, 12):
        raise SystemExit("Python 3.12 or newer is required to extract the CEF SDK safely.")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("This prototype currently requires an Apple Silicon Mac.")
    cache = Path.home() / "Library/Caches/VaneChromiumPrototype"
    cache.mkdir(parents=True, exist_ok=True)
    sdk = cache / NAME
    if not (sdk / "include/cef_app.h").exists():
        archive = cache / f"{NAME}.tar.bz2"
        partial = archive.with_suffix(".download")
        print("Downloading pinned CEF SDK (135 MB)…", file=sys.stderr)
        urllib.request.urlretrieve(f"https://cef-builds.spotifycdn.com/{archive.name}", partial)
        if hashlib.sha256(partial.read_bytes()).hexdigest() != SHA256:
            partial.unlink()
            raise SystemExit("CEF archive checksum mismatch; refusing to extract.")
        os.replace(partial, archive)
        # Only the checksum-verified, pinned upstream archive is extracted.
        with tarfile.open(archive) as bundle:
            bundle.extractall(cache, filter="data")
        archive.unlink()
    print(sdk)


if __name__ == "__main__":
    main()
