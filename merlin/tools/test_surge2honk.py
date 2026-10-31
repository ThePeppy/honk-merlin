#!/usr/bin/env python3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "merlin" / "tools" / "surge2honk.py"

PROFILE = """\
[Proxy]
Left = ss, 203.0.113.10, 8388, encrypt-method=chacha20-ietf-poly1305, password=fake-left, udp-relay=true

[Proxy Group]
Proxies = select, policy-path=https://airport.example/list, update-interval=3600, policy-regex-filter=^(?!.*(剩余流量|距离下次|套餐到期)).*$
Netflix = select, Proxies, DIRECT, policy-path=https://airport.example/list, update-interval=3600, policy-regex-filter=^(?!.*(剩余流量|距离下次|套餐到期)).*$

[Rule]
PROCESS-NAME,Safari,DIRECT
USER-AGENT,curl*,REJECT
DOMAIN,www.example.com,Netflix
DOMAIN-SUFFIX,example.com,Proxies
DOMAIN-KEYWORD,cdn,Proxies
IP-CIDR,198.51.100.0/24,DIRECT,no-resolve
IP-CIDR6,2001:db8::/32,REJECT,no-resolve
GEOIP,CN,DIRECT
FINAL,Proxies
"""

SUB = """\
Alpha = ss, 203.0.113.20, 1, encrypt-method=chacha20-ietf-poly1305, password=fake-alpha, udp-relay=true
剩余流量 = ss, 203.0.113.21, 1, encrypt-method=chacha20-ietf-poly1305, password=fake-info, udp-relay=true
距离下次重置 = ss, 203.0.113.22, 1, encrypt-method=chacha20-ietf-poly1305, password=fake-info, udp-relay=true
Beta = ss, 203.0.113.23, 2, encrypt-method=chacha20-ietf-poly1305, password=fake-beta, udp-relay=true
"""


class ConvertTest(unittest.TestCase):
    def test_counts_and_shape(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            profile = Path(tmp) / "surge.conf"
            body = Path(tmp) / "sub.txt"
            out = Path(tmp) / "config.dae"
            profile.write_text(PROFILE, encoding="utf-8")
            body.write_text(SUB, encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(TOOL),
                    str(profile),
                    "-o",
                    str(out),
                    f"--subscription-file=https://airport.example/list={body}",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn(
                "nodes=3 groups=2 rules=6 dropped_process_name=1 dropped_other=1 subscriptions=1",
                result.stderr,
            )
            text = out.read_text(encoding="utf-8")
            self.assertNotIn("fake-info", text)
            self.assertNotIn("'剩余流量'", text)
            self.assertIn("'Left'", text)
            self.assertIn("'Alpha'", text)
            self.assertIn("domain(full: 'www.example.com') -> Netflix", text)
            self.assertIn("domain(suffix: 'example.com') -> Proxies", text)
            self.assertIn("domain(keyword: 'cdn') -> Proxies", text)
            self.assertIn("dip(198.51.100.0/24) -> direct", text)
            self.assertIn("dip('2001:db8::/32') -> block", text)
            self.assertIn("dip(geoip:cn) -> direct", text)
            self.assertIn("fallback: Proxies", text)
            self.assertIn("interval: 3600s", text)
            self.assertIn("route: direct", text)
            self.assertIn("filter: subtag('airport_example')", text)
            self.assertIn("filter: group(Proxies)", text)
            self.assertIn("filter: name(direct)", text)
            self.assertIn("default: Proxies", text)
            self.assertIn("default: 'Alpha'", text)
            self.assertIn("# merlin-members:Netflix=Proxies|direct|@airport_example", text)
            self.assertNotIn("PROCESS-NAME", text)
            self.assertNotIn("USER-AGENT", text)


if __name__ == "__main__":
    unittest.main()
