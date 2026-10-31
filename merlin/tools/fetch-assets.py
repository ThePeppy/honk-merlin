#!/usr/bin/env python3
"""Download the offline Clash UI and the geo databases honk already parses."""

import io
import sys
import urllib.request
import zipfile
from pathlib import Path

UI_URL = "https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip"
GEO = {
    "geosite.dat": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/geosite.dat",
    "geoip.dat": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/geoip.dat",
}
# Same bytes as the raw GitHub paths honk uses when it downloads geodata itself.
GEO_FALLBACK = {
    "geosite.dat": "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat",
    "geoip.dat": "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat",
}


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "honk-merlin-build"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def fetch_first(urls: list[str]) -> bytes:
    errors = []
    for url in urls:
        try:
            body = fetch(url)
        except Exception as error:  # noqa: BLE001 - report every mirror
            errors.append(f"{url}: {error}")
            continue
        if len(body) < 100_000:
            errors.append(f"{url}: only {len(body)} bytes")
            continue
        return body
    raise SystemExit("asset download failed:\n" + "\n".join(errors))


def extract_ui(archive: bytes, dest: Path) -> None:
    with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
        names = [name for name in bundle.namelist() if not name.endswith("/")]
        if not names:
            raise SystemExit("zashboard archive is empty")
        prefix = names[0].split("/", 1)[0] + "/"
        strip = all(name.startswith(prefix) for name in names)
        for name in names:
            relative = name[len(prefix) :] if strip else name
            if not relative or relative.startswith("/") or ".." in Path(relative).parts:
                raise SystemExit(f"refusing archive path {name}")
            target = dest / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(bundle.read(name))
    if not (dest / "index.html").is_file():
        raise SystemExit("zashboard archive has no index.html")


def main() -> None:
    dest = Path(sys.argv[1])
    dest.mkdir(parents=True, exist_ok=True)
    ui = dest / "ui"
    ui.mkdir(parents=True, exist_ok=True)
    extract_ui(fetch(UI_URL), ui)
    for name, url in GEO.items():
        body = fetch_first([url, GEO_FALLBACK[name]])
        (dest / name).write_bytes(body)
        print(f"{name} {len(body)} bytes")


if __name__ == "__main__":
    main()
