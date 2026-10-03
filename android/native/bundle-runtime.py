#!/usr/bin/env python3
"""Package staged Termux executables and their library closure as jniLibs.

Why this exists:

* Android 10+ will not exec code out of an app's data directory, so every
  binary has to ship as a jniLib and be launched from `nativeLibraryDir`.
* AGP only packages jniLibs whose file name ends in `.so`, which rules out
  the versioned names Linux distros use (libcrypto.so.3, libicuuc.so.78).

So each binary gets a `libjx*.so` name, and the DT_NEEDED / DT_SONAME
entries of the whole closure are rewritten to match. Everything is patched in
a single patchelf invocation per file: patchelf rebuilds the segment table on
every run, so calling it once per edit compounds and inflates a 49 MB node
binary past 66 MB.

Usage: bundle-runtime.py <staged-prefix> <out-lib-dir> <entry> [entry...]
"""
import os
import re
import shutil
import subprocess
import sys

NDK = os.environ.get(
    "ANDROID_NDK_HOME",
    os.path.expanduser("~/Library/Android/sdk/ndk/28.2.13676358"),
)
READELF = os.path.join(
    NDK, "toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-readelf"
)
STRIP = os.path.join(NDK, "toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-strip")

# Supplied by the platform, never packaged.
SYSTEM = {
    "libc.so",
    "libm.so",
    "libdl.so",
    "liblog.so",
    "libz.so",
    "libstdc++.so",
    "libandroid.so",
    "libc++_shared.so",
}


def dynamic(path):
    out = subprocess.run(
        [READELF, "-d", path], capture_output=True, text=True
    ).stdout
    needed = re.findall(r"\(NEEDED\).*\[(.*?)\]", out)
    names = re.findall(r"\(SONAME\).*\[(.*?)\]", out)
    return needed, names[0] if names else None


def packaged_name(requested, is_executable):
    """Map a DT_NEEDED name (or an entry binary) onto an APK-safe file name.

    Executables get their own `bin_` namespace: `bin/curl` and `libcurl.so`
    would otherwise both collapse onto libjxcurl.so.
    """
    if is_executable:
        stem = os.path.basename(requested)
        prefix = "libjxbin_"
    else:
        stem = requested[3:] if requested.startswith("lib") else requested
        stem = stem.split(".so")[0]
        prefix = "libjx"
    stem = re.sub(r"[^A-Za-z0-9_.-]", "_", stem) or "unnamed"
    return f"{prefix}{stem}.so"


def main():
    prefix, out_dir = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    entries = sys.argv[3:]
    lib_dir = os.path.join(prefix, "lib")
    os.makedirs(out_dir, exist_ok=True)

    # requested name -> (source path, packaged name)
    plan = {}
    queue = [(name, True) for name in entries]
    while queue:
        requested, is_executable = queue.pop(0)
        if requested in plan or requested in SYSTEM:
            continue
        if is_executable:
            source = os.path.join(prefix, requested)
        else:
            source = os.path.join(lib_dir, requested)
            if not os.path.exists(source):
                sys.exit(f"unresolved dependency: {requested} (looked in {lib_dir})")
        plan[requested] = (source, packaged_name(requested, is_executable))
        for dep in dynamic(source)[0]:
            if dep not in plan and dep not in SYSTEM:
                queue.append((dep, False))

    claimed = {}
    for requested, (_, name) in plan.items():
        if name in claimed:
            sys.exit(f"name collision: {requested} and {claimed[name]} both -> {name}")
        claimed[name] = requested

    # Files whose SONAME does not end in .so (libsqlite3.so.3.53.4 has none at
    # all) still resolve by file name, which is what the loader searches for.
    staged = {}
    for requested, (source, name) in plan.items():
        target = os.path.join(out_dir, name)
        shutil.copyfile(source, target)
        os.chmod(target, 0o755)
        staged[requested] = target

    for requested, target in staged.items():
        args = ["patchelf", "--page-size", "4096"]
        needed, soname = dynamic(target)
        final = plan[requested][1]
        if soname and soname != final:
            args += ["--set-soname", final]
        for dep in needed:
            if dep in plan and plan[dep][1] != dep:
                args += ["--replace-needed", dep, plan[dep][1]]
        if len(args) > 3:
            subprocess.run(args + [target], check=True)
        subprocess.run([STRIP, "--strip-unneeded", target], check=False)

    for requested, (_, name) in sorted(plan.items()):
        size = os.path.getsize(os.path.join(out_dir, name))
        print(f"  {requested:28} -> {name:32} {size/1e6:8.1f} MB")


if __name__ == "__main__":
    main()
