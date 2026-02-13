#!/usr/bin/env python3
"""Build a platform-specific wheel containing the aipipe binary.

This script:
1. Builds the Zig binary for the specified target (or native)
2. Packages it into a wheel with the Python wrapper module
3. Places the binary in .data/scripts/ so pip/uv puts it on PATH

Usage:
    python scripts/build_wheel.py [--target TARGET] [--out DIR] [--zig-binary PATH]

    --target TARGET   Zig target triple (e.g., x86_64-linux-gnu)
    --out DIR         Output directory for the .whl file (default: dist)
    --zig-binary PATH Path to a pre-built binary (skips zig build)
"""

import argparse
import hashlib
import base64
import csv
import io
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import zipfile

VERSION = "0.1.0"
PACKAGE = "aipipe"

# Map Zig targets to Python wheel platform tags
ZIG_TO_WHEEL_PLATFORM = {
    "x86_64-linux-gnu": "manylinux_2_17_x86_64.manylinux2014_x86_64",
    "x86_64-linux-musl": "musllinux_1_1_x86_64",
    "aarch64-linux-gnu": "manylinux_2_17_aarch64.manylinux2014_aarch64",
    "aarch64-linux-musl": "musllinux_1_1_aarch64",
    "aarch64-macos-none": "macosx_11_0_arm64",
    "x86_64-macos-none": "macosx_10_12_x86_64",
    "x86_64-windows-gnu": "win_amd64",
}


def detect_native_platform():
    """Detect the current platform and return a wheel platform tag."""
    system = platform.system().lower()
    machine = platform.machine().lower()

    if system == "linux":
        if machine in ("x86_64", "amd64"):
            return "manylinux_2_17_x86_64.manylinux2014_x86_64"
        elif machine == "aarch64":
            return "manylinux_2_17_aarch64.manylinux2014_aarch64"
    elif system == "darwin":
        if machine == "arm64":
            return "macosx_11_0_arm64"
        elif machine == "x86_64":
            return "macosx_10_12_x86_64"
    elif system == "windows":
        if machine in ("amd64", "x86_64"):
            return "win_amd64"

    raise RuntimeError(f"Unsupported platform: {system}-{machine}")


def build_zig(target=None, project_root="."):
    """Build the Zig binary and return the path to it."""
    cmd = ["zig", "build", "-Doptimize=ReleaseFast"]

    if target:
        cmd.extend([f"-Dtarget={target}"])

    subprocess.check_call(cmd, cwd=project_root)

    # Determine binary name
    is_windows = target and "windows" in target
    binary_name = "aipipe.exe" if is_windows else "aipipe"
    binary_path = os.path.join(project_root, "zig-out", "bin", binary_name)

    if not os.path.exists(binary_path):
        raise FileNotFoundError(f"Binary not found at {binary_path}")

    return binary_path


def sha256_digest(path):
    """Compute SHA-256 digest of a file, return urlsafe base64 (no padding)."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return base64.urlsafe_b64encode(h.digest()).rstrip(b"=").decode("ascii")


def sha256_digest_bytes(data):
    """Compute SHA-256 digest of bytes, return urlsafe base64 (no padding)."""
    h = hashlib.sha256(data)
    return base64.urlsafe_b64encode(h.digest()).rstrip(b"=").decode("ascii")


def build_wheel(binary_path, platform_tag, out_dir, project_root="."):
    """Build a wheel containing the binary and Python wrapper."""
    os.makedirs(out_dir, exist_ok=True)

    dist_info_name = f"{PACKAGE}-{VERSION}.dist-info"
    data_name = f"{PACKAGE}-{VERSION}.data"

    # Determine binary name in wheel
    is_windows = "win" in platform_tag
    binary_name = "aipipe.exe" if is_windows else "aipipe"

    wheel_filename = f"{PACKAGE}-{VERSION}-py3-none-{platform_tag}.whl"
    wheel_path = os.path.join(out_dir, wheel_filename)

    record_entries = []

    with zipfile.ZipFile(wheel_path, "w", zipfile.ZIP_DEFLATED) as whl:
        # 1. Add the Python package files
        python_src = os.path.join(project_root, "python", PACKAGE)
        for py_file in ("__init__.py", "__main__.py"):
            src_path = os.path.join(python_src, py_file)
            arcname = f"{PACKAGE}/{py_file}"
            whl.write(src_path, arcname)
            record_entries.append((arcname, sha256_digest(src_path), os.path.getsize(src_path)))

        # 2. Add the binary to data/scripts/
        scripts_arcname = f"{data_name}/scripts/{binary_name}"
        whl.write(binary_path, scripts_arcname)
        record_entries.append((scripts_arcname, sha256_digest(binary_path), os.path.getsize(binary_path)))

        # 3. Add METADATA
        metadata_content = (
            f"Metadata-Version: 2.1\n"
            f"Name: {PACKAGE}\n"
            f"Version: {VERSION}\n"
            f"Summary: Fast utilities for AI agent workflows\n"
            f"License: Apache-2.0\n"
            f"Requires-Python: >=3.9\n"
        ).encode("utf-8")
        metadata_arcname = f"{dist_info_name}/METADATA"
        whl.writestr(metadata_arcname, metadata_content)
        record_entries.append((metadata_arcname, sha256_digest_bytes(metadata_content), len(metadata_content)))

        # 4. Add WHEEL metadata
        wheel_content = (
            f"Wheel-Version: 1.0\n"
            f"Generator: aipipe-build\n"
            f"Root-Is-Purelib: false\n"
            f"Tag: py3-none-{platform_tag}\n"
        ).encode("utf-8")
        wheel_arcname = f"{dist_info_name}/WHEEL"
        whl.writestr(wheel_arcname, wheel_content)
        record_entries.append((wheel_arcname, sha256_digest_bytes(wheel_content), len(wheel_content)))

        # 5. Add top_level.txt
        top_level_content = f"{PACKAGE}\n".encode("utf-8")
        top_level_arcname = f"{dist_info_name}/top_level.txt"
        whl.writestr(top_level_arcname, top_level_content)
        record_entries.append((top_level_arcname, sha256_digest_bytes(top_level_content), len(top_level_content)))

        # 6. Add entry_points.txt
        entry_points_content = (
            f"[console_scripts]\n"
            f"aipipe = aipipe.__main__:_run\n"
        ).encode("utf-8")
        entry_points_arcname = f"{dist_info_name}/entry_points.txt"
        whl.writestr(entry_points_arcname, entry_points_content)
        record_entries.append((entry_points_arcname, sha256_digest_bytes(entry_points_content), len(entry_points_content)))

        # 7. Add RECORD (must be last, and its own entry has no hash)
        record_buf = io.StringIO()
        writer = csv.writer(record_buf, lineterminator="\n")
        for arcname, digest, size in record_entries:
            writer.writerow([arcname, f"sha256={digest}", str(size)])
        record_arcname = f"{dist_info_name}/RECORD"
        writer.writerow([record_arcname, "", ""])
        whl.writestr(record_arcname, record_buf.getvalue().encode("utf-8"))

    print(f"Built: {wheel_path}")
    return wheel_path


def main():
    parser = argparse.ArgumentParser(description="Build aipipe wheel")
    parser.add_argument("--target", help="Zig target triple (e.g., x86_64-linux-gnu)")
    parser.add_argument("--out", default="dist", help="Output directory")
    parser.add_argument("--zig-binary", help="Path to pre-built binary (skip zig build)")
    args = parser.parse_args()

    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    # Determine platform tag
    if args.target:
        platform_tag = ZIG_TO_WHEEL_PLATFORM.get(args.target)
        if not platform_tag:
            print(f"Error: unknown target '{args.target}'", file=sys.stderr)
            print(f"Known targets: {', '.join(ZIG_TO_WHEEL_PLATFORM.keys())}", file=sys.stderr)
            sys.exit(1)
    else:
        platform_tag = detect_native_platform()

    # Build or use provided binary
    if args.zig_binary:
        binary_path = args.zig_binary
        if not os.path.exists(binary_path):
            print(f"Error: binary not found at {binary_path}", file=sys.stderr)
            sys.exit(1)
    else:
        binary_path = build_zig(target=args.target, project_root=project_root)

    # Build the wheel
    out_dir = os.path.join(project_root, args.out)
    build_wheel(binary_path, platform_tag, out_dir, project_root)


if __name__ == "__main__":
    main()
