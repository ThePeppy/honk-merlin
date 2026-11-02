#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
_SPEC = importlib.util.spec_from_file_location(
    "fetch_assets", Path(__file__).with_name("fetch-assets.py")
)
_MODULE = importlib.util.module_from_spec(_SPEC)
assert _SPEC.loader is not None
_SPEC.loader.exec_module(_MODULE)
extract_doona = _MODULE.extract_doona
load_pins = _MODULE.load_pins
slim_dat = _MODULE.slim_dat


def varint(value: int) -> bytes:
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def field_bytes(number: int, payload: bytes) -> bytes:
    return bytes([(number << 3) | 2]) + varint(len(payload)) + payload


def geo_list(*codes: str) -> bytes:
    blob = bytearray()
    for code in codes:
        blob.extend(field_bytes(1, field_bytes(1, code.encode("ascii"))))
    return bytes(blob)


class SlimDatTest(unittest.TestCase):
    def test_keeps_cn_and_private(self):
        slim = slim_dat(geo_list("cn", "us", "private", "jp"), frozenset({"cn", "private"}))
        self.assertEqual(slim, geo_list("cn", "private"))

    def test_drops_other_codes(self):
        slim = slim_dat(geo_list("cn", "geolocation-cn", "private"), frozenset({"cn", "private"}))
        self.assertEqual(slim, geo_list("cn", "private"))

    def test_codes_are_case_insensitive(self):
        slim = slim_dat(geo_list("CN", "PRIVATE"), frozenset({"cn", "private"}))
        self.assertEqual(slim, geo_list("CN", "PRIVATE"))

    def test_missing_code_fails(self):
        with self.assertRaises(SystemExit):
            slim_dat(geo_list("cn"), frozenset({"cn", "private"}))


class PinsAndArchiveTest(unittest.TestCase):
    def test_pins_name_doona(self):
        pins = load_pins()
        self.assertTrue(pins["DOONA_VERSION"])
        self.assertEqual(len(pins["DOONA_SHA256"]), 64)

    def test_extract_doona_strips_fonts_and_appledouble(self):
        import io
        import tarfile
        import tempfile

        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w:gz") as bundle:
            def add(name: str, body: bytes) -> None:
                info = tarfile.TarInfo(name)
                info.size = len(body)
                bundle.addfile(info, io.BytesIO(body))

            add("doona/index.html", b"<html>doona</html>")
            add("doona/fonts/Noto.ttf", b"font")
            add("doona/._index.html", b"appledouble")
            add("doona/assets/app.js", b"js")
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / "ui"
            extract_doona(buf.getvalue(), dest)
            self.assertEqual((dest / "index.html").read_bytes(), b"<html>doona</html>")
            self.assertEqual((dest / "assets" / "app.js").read_bytes(), b"js")
            self.assertFalse((dest / "fonts" / "Noto.ttf").exists())
            self.assertFalse((dest / "._index.html").exists())


if __name__ == "__main__":
    unittest.main()
