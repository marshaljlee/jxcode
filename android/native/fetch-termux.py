#!/usr/bin/env python3
"""Fetch Termux aarch64 packages and their transitive dependencies.

The .deb pool is the only source for arm64 builds of things like git; the
Packages index gives us `Depends:` so the closure can be resolved instead of
guessed one download at a time.
"""
import os
import sys
import urllib.request

REPO = "https://packages.termux.dev/apt/termux-main"
INDEX = f"{REPO}/dists/stable/main/binary-aarch64/Packages"
HERE = os.path.dirname(os.path.abspath(__file__))
DEST = os.path.join(HERE, "node-deb", "debs")
MANIFEST = os.path.join(HERE, "runtime", "deb-manifest.txt")

# Provided by the NDK; Termux's copy would collide with the one llama.cpp uses.
SKIP = {"libc++", "libc++-static"}


def load_index():
    raw = urllib.request.urlopen(INDEX, timeout=60).read().decode()
    packages = {}
    for block in raw.split("\n\n"):
        fields = {}
        key = None
        for line in block.splitlines():
            if line.startswith((" ", "\t")) and key:
                fields[key] += " " + line.strip()
            elif ":" in line:
                key, _, value = line.partition(":")
                fields[key.strip()] = value.strip()
        if "Package" in fields and "Filename" in fields:
            packages[fields["Package"]] = fields
    return packages


def resolve(index, roots):
    seen, queue, order = set(), list(roots), []
    while queue:
        name = queue.pop(0)
        if name in seen or name in SKIP:
            continue
        seen.add(name)
        pkg = index.get(name)
        if pkg is None:
            print(f"  ! {name}: not in index", file=sys.stderr)
            continue
        order.append(pkg)
        for dep in (pkg.get("Depends") or "").split(","):
            dep = dep.strip().split("(")[0].split("|")[0].strip()
            if dep and dep not in seen:
                queue.append(dep)
    return order


def main():
    roots = sys.argv[1:]
    if not roots:
        raise SystemExit("usage: fetch-termux.py <package> [package...]")
    index = load_index()
    os.makedirs(DEST, exist_ok=True)
    manifest = []
    for pkg in resolve(index, roots):
        url = f"{REPO}/{pkg['Filename']}"
        # Epochs put a colon in the filename (openssl_1:3.6.3); keep it
        # URL-encoded so shell loops over the directory stay simple.
        target = os.path.join(DEST, os.path.basename(pkg["Filename"]).replace(":", "%3A"))
        if os.path.exists(target) and os.path.getsize(target) > 0:
            print(f"  = {os.path.basename(target)} (cached)")
        else:
            print(f"  v {url}")
            urllib.request.urlretrieve(url, target)
        manifest.append(target)
    # build-runtime.sh stages exactly these, so an unrelated .deb left in the
    # cache directory cannot quietly change what ends up in the APK.
    os.makedirs(os.path.dirname(MANIFEST), exist_ok=True)
    with open(MANIFEST, "w") as handle:
        handle.write("\n".join(manifest) + "\n")
    print(f"  -> {len(manifest)} packages written to {MANIFEST}")


if __name__ == "__main__":
    main()
