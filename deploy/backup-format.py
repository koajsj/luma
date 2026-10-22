#!/usr/bin/env python3
"""Validate the fixed Luma backup format without extracting untrusted paths."""

import hashlib
import json
import re
import sys
import tarfile
from pathlib import Path


FILES = (
    "FORMAT", "VERSION", "KEY_ID", "BACKUP_KEY_ID",
    "postgres.dump.age", "storage.tar.gz.age",
)
LEGACY_FILES = ("postgres.dump", "storage.tar.gz", "VERSION", "KEY_ID")
OBJECT = re.compile(r"storage/ciphertext/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def manifest(directory):
    return {"format": 2, "files": {name: digest(directory / name) for name in FILES}}


def verify_manifest(directory, source):
    value = json.load(source)
    if (not isinstance(value, dict) or set(value) != {"format", "files"}
            or value["format"] != 2 or not isinstance(value["files"], dict)
            or set(value["files"]) != set(FILES)):
        raise ValueError("备份清单格式不正确")
    for name in FILES:
        path = directory / name
        if path.is_symlink() or not path.is_file() or not re.fullmatch(r"[0-9a-f]{64}", value["files"][name]):
            raise ValueError("备份文件或校验值不正确")
        if digest(path) != value["files"][name]:
            raise ValueError("备份完整性校验失败")


def verify_legacy(directory):
    checksums = directory / "SHA256SUMS"
    if checksums.is_symlink() or not checksums.is_file():
        raise ValueError("旧备份缺少校验清单")
    entries = checksums.read_text(encoding="ascii").splitlines()
    if len(entries) != len(LEGACY_FILES):
        raise ValueError("旧备份校验清单格式不正确")
    for entry, name in zip(entries, LEGACY_FILES):
        match = re.fullmatch(r"([0-9a-f]{64})  " + re.escape(name), entry)
        path = directory / name
        if not match or path.is_symlink() or not path.is_file() or digest(path) != match.group(1):
            raise ValueError("旧备份完整性校验失败")


def verify_storage(source):
    total = 0
    seen = set()
    with tarfile.open(fileobj=source, mode="r|gz") as archive:
        for item in archive:
            name = item.name.rstrip("/")
            if name in seen:
                raise ValueError("备份包含重复路径")
            seen.add(name)
            if name in {"storage", "storage/ciphertext"} and item.isdir():
                continue
            if not OBJECT.fullmatch(name) or not item.isfile():
                raise ValueError("备份包含不安全的文件路径或类型")
            total += item.size
    if "storage" not in seen:
        raise ValueError("备份缺少 storage 目录")
    print(total)


try:
    command = sys.argv[1]
    if command == "manifest" and len(sys.argv) == 3:
        json.dump(manifest(Path(sys.argv[2])), sys.stdout, sort_keys=True, separators=(",", ":"))
    elif command == "verify-manifest" and len(sys.argv) == 3:
        verify_manifest(Path(sys.argv[2]), sys.stdin)
    elif command == "verify-storage" and len(sys.argv) == 2:
        verify_storage(sys.stdin.buffer)
    elif command == "verify-legacy" and len(sys.argv) == 3:
        verify_legacy(Path(sys.argv[2]))
    else:
        raise ValueError("备份校验命令无效")
except (OSError, ValueError, UnicodeError, TypeError, json.JSONDecodeError, tarfile.TarError, EOFError) as error:
    print(f"Luma：{error}", file=sys.stderr)
    sys.exit(1)
