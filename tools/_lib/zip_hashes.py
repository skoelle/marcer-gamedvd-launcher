# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Disk-image decoding and hashing for the Marcer catalog pipeline.

The same rules as the former `tools/piratefinder-gen` importer: `.msa` is
unpacked to raw sectors, `.st` is hashed as stored and `.stx` is hashed as a
file. Hashes are stored per member so the desktop app can match a ZIP against
an external catalogue without decoding it at runtime.
"""
from __future__ import annotations

import hashlib
import zipfile
import zlib
from pathlib import Path

IMAGE_SUFFIXES = frozenset({".msa", ".st", ".stx"})
MAX_MEMBER_SIZE = 64 * 1024 * 1024


def hashes_of(data: bytes) -> dict:
    return {
        "sha1": hashlib.sha1(data, usedforsecurity=False).hexdigest(),
        "sha512": hashlib.sha512(data).hexdigest(),
        "crc32": f"{zlib.crc32(data) & 0xFFFFFFFF:08x}",
        "size": len(data),
    }


def decode_msa(data: bytes) -> bytes:
    """Decode an MSA archive to the raw ST sector image."""
    if len(data) < 10 or data[0] != 0x0E or data[1] != 0x0F:
        raise ValueError("not an MSA file")
    sectors = _word(data, 2)
    sides = _word(data, 4) + 1
    start = _word(data, 6)
    end = _word(data, 8)
    if sectors < 1 or sectors > 36:
        raise ValueError(f"invalid sectors per track: {sectors}")
    if sides not in (1, 2):
        raise ValueError(f"invalid sides: {sides}")
    if end < start or end > 255:
        raise ValueError(f"invalid track range: {start}-{end}")
    sector_size = 512
    track_size = sectors * sector_size
    raw = bytearray((end + 1) * sides * track_size)
    index = 10
    for track in range(start, end + 1):
        for side in range(sides):
            if index + 2 > len(data):
                raise ValueError("MSA ends before a track header")
            length = _word(data, index)
            index += 2
            if index + length > len(data):
                raise ValueError("MSA track is truncated")
            packed = data[index:index + length]
            index += length
            if length > track_size:
                raise ValueError("MSA track is too long")
            unpacked = (
                packed if length == track_size else _unpack_track(packed, track_size)
            )
            offset = (track * sides + side) * track_size
            raw[offset:offset + track_size] = unpacked
    return bytes(raw)


def _unpack_track(packed: bytes, expected: int) -> bytes:
    out = bytearray()
    index = 0
    while index < len(packed):
        marker = packed.find(0xE5, index)
        if marker < 0:
            out.extend(packed[index:])
            break
        out.extend(packed[index:marker])
        index = marker + 1
        if index + 3 > len(packed):
            raise ValueError("MSA run record is cut off")
        fill = packed[index]
        count = (packed[index + 1] << 8) | packed[index + 2]
        index += 3
        out.extend(bytes([fill]) * count)
        if len(out) > expected:
            raise ValueError("MSA track expands past its size")
    if len(out) != expected:
        raise ValueError(
            f"MSA track unpacked to {len(out)} bytes, expected {expected}"
        )
    return bytes(out)


def _word(data: bytes, offset: int) -> int:
    return (data[offset] << 8) | data[offset + 1]


def _suffix(name: str) -> str:
    dot = name.rfind(".")
    return "" if dot < 0 else name[dot:].lower()


def zip_members(path: Path) -> tuple[list[dict], str]:
    """Return the image members of ``path`` and a ZIP-level error string."""
    members: list[dict] = []
    try:
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                if info.is_dir() or info.file_size <= 0:
                    continue
                if info.file_size > MAX_MEMBER_SIZE:
                    continue
                suffix = _suffix(info.filename.replace("\\", "/"))
                if suffix not in IMAGE_SUFFIXES:
                    continue
                try:
                    data = archive.read(info)
                except (OSError, RuntimeError, zipfile.BadZipFile) as error:
                    members.append({
                        "name": info.filename,
                        "format": suffix.lstrip("."),
                        "error": str(error),
                    })
                    continue
                member = {
                    "name": info.filename,
                    "format": suffix.lstrip("."),
                    "crc32": f"{zlib.crc32(data) & 0xFFFFFFFF:08x}",
                    "size": len(data),
                }
                if suffix == ".msa":
                    try:
                        raw = decode_msa(data)
                        member["raw"] = hashes_of(raw)
                        member["raw_size"] = len(raw)
                    except ValueError as error:
                        member["error"] = str(error)
                    member["file"] = hashes_of(data)
                elif suffix == ".st":
                    member["raw"] = hashes_of(data)
                    member["raw_size"] = len(data)
                else:
                    member["file"] = hashes_of(data)
                members.append(member)
    except (OSError, zipfile.BadZipFile) as error:
        return [], str(error)
    return members, ""


def fingerprint(members: list[dict]) -> str:
    """Stable ZIP-container fingerprint: sorted ``crc32:size`` pairs."""
    values = {
        f"{member['crc32']}:{member['size']}"
        for member in members
        if member.get("crc32") and member.get("size")
    }
    return ",".join(sorted(values))


def payload(members: list[dict]) -> list[dict]:
    """Compact member payload stored in the full index."""
    out = []
    for member in members:
        item = {
            "name": member.get("name", ""),
            "format": member.get("format", ""),
        }
        if member.get("crc32"):
            item["crc32"] = member["crc32"]
        if member.get("size"):
            item["size"] = member["size"]
        if member.get("raw"):
            item["raw"] = member["raw"]
        if member.get("file"):
            item["file"] = member["file"]
        if member.get("error"):
            item["error"] = member["error"]
        out.append(item)
    return out
