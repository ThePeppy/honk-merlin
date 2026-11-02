#!/usr/bin/env python3
"""Download pinned doona and slim geo databases for the Merlin addon."""

from __future__ import annotations

import hashlib
import io
import sys
import tarfile
import urllib.request
from pathlib import Path

GEO = {
    "geosite.dat": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/geosite.dat",
    "geoip.dat": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/geoip.dat",
}
KEEP_GEO_CODES = frozenset({"cn", "private"})
GEO_KEEP = {
    "geoip.dat": KEEP_GEO_CODES,
    "geosite.dat": KEEP_GEO_CODES,
}
GEO_FALLBACK = {
    "geosite.dat": "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat",
    "geoip.dat": "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat",
}
ROOT = Path(__file__).resolve().parents[2]
PINS = ROOT / ".github" / "ci" / "pins.env"
DOONA_REPO = "https://github.com/Zakkaus/doona"


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "honk-merlin-build"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def fetch_first(urls: list[str], min_bytes: int = 100_000) -> bytes:
    errors = []
    for url in urls:
        try:
            body = fetch(url)
        except Exception as error:  # noqa: BLE001 - report every mirror
            errors.append(f"{url}: {error}")
            continue
        if len(body) < min_bytes:
            errors.append(f"{url}: only {len(body)} bytes")
            continue
        return body
    raise SystemExit("asset download failed:\n" + "\n".join(errors))


def load_pins(path: Path = PINS) -> dict[str, str]:
    pins: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        pins[key.strip()] = value.strip()
    return pins


def _read_varint(data: bytes, index: int) -> tuple[int, int]:
    shift = 0
    value = 0
    while index < len(data):
        byte = data[index]
        index += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, index
        shift += 7
        if shift > 63:
            raise ValueError("varint too long")
    raise ValueError("truncated varint")


def _write_varint(value: int) -> bytes:
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def _skip_field(data: bytes, index: int, wire: int) -> int:
    if wire == 0:
        _, index = _read_varint(data, index)
        return index
    if wire == 1:
        if index + 8 > len(data):
            raise ValueError("truncated 64-bit field")
        return index + 8
    if wire == 2:
        length, index = _read_varint(data, index)
        if index + length > len(data):
            raise ValueError("truncated length-delimited field")
        return index + length
    if wire == 5:
        if index + 4 > len(data):
            raise ValueError("truncated 32-bit field")
        return index + 4
    raise ValueError(f"unsupported protobuf wire type {wire}")


def _entry_code(entry: bytes) -> str | None:
    index = 0
    while index < len(entry):
        tag, index = _read_varint(entry, index)
        field, wire = tag >> 3, tag & 7
        if field == 1 and wire == 2:
            length, index = _read_varint(entry, index)
            return entry[index : index + length].decode("utf-8", "replace").lower()
        index = _skip_field(entry, index, wire)
    return None


def slim_dat(data: bytes, codes: frozenset[str]) -> bytes:
    """Keep GeoIPList/GeoSiteList entries whose country_code is in `codes`."""
    index = 0
    kept = bytearray()
    found: set[str] = set()
    while index < len(data):
        tag, index = _read_varint(data, index)
        field, wire = tag >> 3, tag & 7
        if field == 1 and wire == 2:
            length, index = _read_varint(data, index)
            entry = data[index : index + length]
            index += length
            code = _entry_code(entry)
            if code in codes:
                found.add(code)
                kept.append(0x0A)
                kept.extend(_write_varint(len(entry)))
                kept.extend(entry)
            continue
        index = _skip_field(data, index, wire)
    missing = codes - found
    if missing:
        raise SystemExit(f"geo dat missing codes: {' '.join(sorted(missing))}")
    return bytes(kept)


def extract_doona(archive: bytes, dest: Path) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as bundle:
        members = [member for member in bundle.getmembers() if member.isfile()]
        if not members:
            raise SystemExit("doona archive is empty")
        prefix = members[0].name.split("/", 1)[0] + "/"
        strip = all(member.name.startswith(prefix) for member in members)
        for member in members:
            name = member.name[len(prefix) :] if strip else member.name
            relative = Path(name)
            parts = relative.parts
            if (
                not name
                or relative.is_absolute()
                or ".." in parts
                or relative.name.startswith("._")
                or "fonts" in parts
            ):
                continue
            target = dest / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            extracted = bundle.extractfile(member)
            if extracted is None:
                raise SystemExit(f"doona archive missing {member.name}")
            target.write_bytes(extracted.read())
    if not (dest / "index.html").is_file():
        raise SystemExit("doona archive has no index.html")


def fetch_doona(dest: Path, pins: dict[str, str]) -> None:
    version = pins["DOONA_VERSION"]
    checksum = pins["DOONA_SHA256"]
    url = f"{DOONA_REPO}/releases/download/v{version}/doona-{version}.tar.gz"
    archive = fetch_first([url], min_bytes=100_000)
    digest = hashlib.sha256(archive).hexdigest()
    if digest != checksum:
        raise SystemExit(f"doona sha256 {digest}, expected {checksum}")
    extract_doona(archive, dest)
    print(f"doona {version} {len(archive)} bytes")


def main() -> None:
    dest = Path(sys.argv[1])
    dest.mkdir(parents=True, exist_ok=True)
    pins = load_pins()
    ui = dest / "ui"
    if ui.exists():
        raise SystemExit(f"{ui} already exists")
    fetch_doona(ui, pins)
    for name, url in GEO.items():
        body = fetch_first([url, GEO_FALLBACK[name]])
        slim = slim_dat(body, GEO_KEEP[name])
        (dest / name).write_bytes(slim)
        print(f"{name} {len(body)} -> {len(slim)} bytes")


if __name__ == "__main__":
    main()
