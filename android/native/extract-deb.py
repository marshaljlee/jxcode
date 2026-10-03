#!/usr/bin/env python3
"""Extract a .deb's data payload into a prefix directory.

macOS `ar` chokes on the trailing "/" that aptly puts in member names, and
`dpkg-deb` is not installed, so the archive is walked by hand. Payload
compression varies by mirror (.xz and .zstd are both in the wild).
"""
import io
import lzma
import os
import struct
import sys
import tarfile


def members(path):
    with open(path, "rb") as f:
        if f.read(8) != b"!<arch>\n":
            raise SystemExit(f"{path}: not an ar archive")
        while True:
            header = f.read(60)
            if len(header) < 60:
                return
            name = header[:16].rstrip(b" ").rstrip(b"/").rstrip(b"\x00").decode()
            size = int(header[48:58].decode().strip())
            if name and not name.startswith("/"):
                yield name, f.read(size)
            else:
                f.read(size)
            if size % 2:
                f.read(1)


def payload(path, want):
    for name, blob in members(path):
        if name == want:
            return blob
    raise SystemExit(f"{path}: no {want}")


def open_tar(blob):
    if blob[:6] == b"\xfd7zXZ\x00":
        return tarfile.open(fileobj=io.BytesIO(blob), mode="r:xz")
    if blob[:4] == b"\x28\xb5\x2f\xfd":
        import zstandard

        return tarfile.open(
            fileobj=io.BytesIO(zstandard.ZstdDecompressor().decompress(blob)), mode="r:"
        )
    if blob[:2] == b"\x1f\x8b":
        import gzip

        return tarfile.open(fileobj=io.BytesIO(gzip.decompress(blob)), mode="r:")
    return tarfile.open(fileobj=io.BytesIO(blob), mode="r:")


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: extract-deb.py <deb> <dest-prefix> [control]")
    deb, dest = sys.argv[1], sys.argv[2]
    want = "control.tar.xz" if len(sys.argv) > 3 and sys.argv[3] == "control" else None
    if want is None:
        blob = None
        for name, b in members(deb):
            if name.startswith("data.tar"):
                blob, want = b, name
                break
        if blob is None:
            raise SystemExit(f"{deb}: no data.tar.* member")
    else:
        blob = payload(deb, want)
    os.makedirs(dest, exist_ok=True)
    with open_tar(blob) as tar:
        for member in tar.getmembers():
            if not (member.isfile() or member.isdir() or member.issym()):
                continue
            target = os.path.join(dest, member.name.lstrip("./"))
            if os.path.commonpath([os.path.abspath(target), os.path.abspath(dest)]) != os.path.abspath(dest):
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            if member.isdir():
                os.makedirs(target, exist_ok=True)
            elif member.issym():
                if os.path.lexists(target):
                    os.remove(target)
                os.symlink(member.linkname, target)
            else:
                src = tar.extractfile(member)
                if src is None:
                    continue
                with open(target, "wb") as out:
                    out.write(src.read())
                os.chmod(target, member.mode & 0o777 or 0o644)
    print(f"extracted {deb} -> {dest} ({want})")


if __name__ == "__main__":
    main()
