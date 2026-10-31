#!/usr/bin/env python3
"""Convert a Surge profile to a honk dae file.

stdlib only, so it runs on macOS. Secrets stay in the output you choose;
tests must use fake passwords. Summary counts go to stderr.
"""

from __future__ import annotations

import argparse
import re
import sys
import urllib.request
from dataclasses import dataclass, field
from urllib.parse import quote, urlsplit


DROPPED_TYPES = {
    "PROCESS-NAME",
    "PROCESS-PATH",
    "USER-AGENT",
    "URL-REGEX",
    "URL-WILDCARD",
    "SCRIPT",
    "RULE-SET",
    "DOMAIN-SET",
    "SUBNET",
    "DEST-PORT",
    "SRC-IP",
    "IN-PORT",
    "AND",
    "OR",
    "NOT",
    "PROTOCOL",
    "DEST-GEOIP",
}


@dataclass
class Node:
    name: str
    host: str
    port: int
    method: str
    password: str


@dataclass
class Group:
    name: str
    kind: str
    members: list[str] = field(default_factory=list)
    policy_path: str | None = None
    interval: int | None = None
    regex: str | None = None


@dataclass
class Counts:
    nodes: int = 0
    groups: int = 0
    rules: int = 0
    dropped_process_name: int = 0
    dropped_other: int = 0
    subscriptions: int = 0


def split_csv(line: str) -> list[str]:
    parts: list[str] = []
    buf: list[str] = []
    quote: str | None = None
    for char in line:
        if quote:
            buf.append(char)
            if char == quote:
                quote = None
        elif char in "'\"":
            quote = char
            buf.append(char)
        elif char == ",":
            parts.append("".join(buf).strip())
            buf = []
        else:
            buf.append(char)
    tail = "".join(buf).strip()
    if tail:
        parts.append(tail)
    return parts


def unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    return value


def section_name(line: str) -> str | None:
    if line.startswith("[") and line.endswith("]"):
        return line[1:-1]
    return None


def parse_proxy(line: str) -> Node | None:
    parts = split_csv(line)
    if len(parts) < 4 or "=" not in parts[0]:
        return None
    name, kind = (item.strip() for item in parts[0].split("=", 1))
    name = unquote(name)
    if kind.strip().lower() != "ss":
        return None
    host = unquote(parts[1])
    try:
        port = int(unquote(parts[2]))
    except ValueError:
        return None
    method = ""
    password = ""
    for item in parts[3:]:
        if "=" not in item:
            continue
        key, value = item.split("=", 1)
        key = key.strip().lower()
        value = unquote(value.strip())
        if key in {"encrypt-method", "method"}:
            method = value
        elif key == "password":
            password = value
    if not name or not host or not method or port <= 0 or port > 65535:
        return None
    return Node(name, host, port, method, password)


def parse_group(line: str) -> Group | None:
    parts = split_csv(line)
    if not parts or "=" not in parts[0]:
        return None
    name, kind = (item.strip() for item in parts[0].split("=", 1))
    name = unquote(name)
    kind = kind.strip().lower()
    group = Group(name=name, kind=kind)
    for item in parts[1:]:
        if "=" in item:
            key, value = item.split("=", 1)
            key = key.strip().lower()
            value = unquote(value.strip())
            if key == "policy-path":
                group.policy_path = value
            elif key == "update-interval":
                try:
                    group.interval = int(value)
                except ValueError:
                    group.interval = None
            elif key == "policy-regex-filter":
                group.regex = value
        else:
            member = unquote(item)
            if member:
                group.members.append(member)
    return group if name else None


def keep_name(name: str, pattern: str | None) -> bool:
    if not pattern:
        return True
    return re.search(pattern, name) is not None


def load_policy(url_or_path: str, fetch: bool) -> str:
    if re.match(r"https?://", url_or_path):
        if not fetch:
            raise SystemExit(f"refusing to fetch {url_or_path} without --fetch")
        with urllib.request.urlopen(url_or_path, timeout=30) as response:
            return response.read().decode("utf-8", "replace")
    with open(url_or_path, encoding="utf-8") as handle:
        return handle.read()


def nodes_from_body(text: str, pattern: str | None) -> list[Node]:
    found: list[Node] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("["):
            continue
        node = parse_proxy(line)
        if node and keep_name(node.name, pattern):
            found.append(node)
    return found


def quote_dae(value: str) -> str:
    if "'" not in value:
        return f"'{value}'"
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def ss_link(node: Node) -> str:
    import base64

    user = base64.b64encode(f"{node.method}:{node.password}".encode()).decode()
    host = f"[{node.host}]" if ":" in node.host else node.host
    return f"ss://{user}@{host}:{node.port}#{quote(node.name, safe='')}"


def tag_for(url: str, used: set[str]) -> str:
    host = urlsplit(url).hostname or "airport"
    base = re.sub(r"[^A-Za-z0-9_]", "_", host).strip("_") or "airport"
    tag = base
    number = 2
    while tag in used:
        tag = f"{base}_{number}"
        number += 1
    used.add(tag)
    return tag


def target_name(value: str) -> str:
    upper = value.strip()
    if upper.upper() == "DIRECT":
        return "direct"
    if upper.upper() == "REJECT":
        return "block"
    return upper


def rule_line(kind: str, value: str, policy: str) -> str | None:
    target = target_name(policy)
    if kind == "DOMAIN":
        return f"    domain(full: {quote_dae(value)}) -> {dae_target(target)}"
    if kind == "DOMAIN-SUFFIX":
        return f"    domain(suffix: {quote_dae(value)}) -> {dae_target(target)}"
    if kind == "DOMAIN-KEYWORD":
        return f"    domain(keyword: {quote_dae(value)}) -> {dae_target(target)}"
    if kind in {"IP-CIDR", "IP-CIDR6"}:
        rendered = quote_dae(value) if ":" in value else value
        return f"    dip({rendered}) -> {dae_target(target)}"
    if kind == "GEOIP":
        code = value.strip().lower()
        return f"    dip(geoip:{code}) -> {dae_target(target)}"
    return None


def dae_target(target: str) -> str:
    if target in {"direct", "block"}:
        return target
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", target):
        return target
    return quote_dae(target)


def convert(text: str, bodies: dict[str, str]) -> tuple[str, Counts]:
    section = ""
    inline: list[Node] = []
    groups: list[Group] = []
    rules: list[str] = []
    fallback = "direct"
    counts = Counts()
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith(";"):
            continue
        name = section_name(line)
        if name is not None:
            section = name
            continue
        if section == "Proxy":
            node = parse_proxy(line)
            if node:
                inline.append(node)
        elif section == "Proxy Group":
            group = parse_group(line)
            if group and group.kind == "select":
                groups.append(group)
        elif section == "Rule":
            parts = split_csv(line)
            if len(parts) < 2:
                counts.dropped_other += 1
                continue
            kind = parts[0].strip().upper()
            if kind == "FINAL":
                fallback = target_name(parts[1])
                continue
            if kind == "PROCESS-NAME":
                counts.dropped_process_name += 1
                continue
            if kind in DROPPED_TYPES or kind not in {
                "DOMAIN",
                "DOMAIN-SUFFIX",
                "DOMAIN-KEYWORD",
                "IP-CIDR",
                "IP-CIDR6",
                "GEOIP",
            }:
                counts.dropped_other += 1
                continue
            if len(parts) < 3:
                counts.dropped_other += 1
                continue
            rendered = rule_line(kind, unquote(parts[1]), parts[2])
            if rendered is None:
                counts.dropped_other += 1
                continue
            rules.append(rendered)

    urls: list[str] = []
    regex = ""
    interval = 86400
    for group in groups:
        if group.policy_path and group.policy_path not in urls:
            urls.append(group.policy_path)
        if group.regex and not regex:
            regex = group.regex
        if group.interval:
            interval = group.interval
    tags: dict[str, str] = {}
    used: set[str] = set()
    remote: dict[str, list[Node]] = {}
    for url in urls:
        tag = tag_for(url, used)
        tags[url] = tag
        body = bodies.get(url, "")
        remote[tag] = nodes_from_body(body, regex or None) if body else []

    lines = [
        "# Generated by merlin/tools/surge2honk.py. Do not commit real passwords.",
        "global {",
        "    lan_interface: br0",
        "    wan_interface: auto",
        "    log_level: info",
        "    dial_mode: domain",
        "    bootstrap_resolver: '1.1.1.1:53'",
        "    store_subscribe: true",
        "}",
        "",
    ]
    if regex:
        lines.append(f"# merlin-policy-regex:{regex}")
    node_lines = []
    for node in inline:
        node_lines.append(f"    {quote_dae(node.name)}: {quote_dae(ss_link(node))}")
    for tag, nodes in remote.items():
        for node in nodes:
            node_lines.append(f"    {quote_dae(node.name)}: {quote_dae(ss_link(node))}")
    if node_lines:
        lines.extend(["node {", *node_lines, "}", ""])
    if urls:
        lines.append("subscription {")
        for url in urls:
            lines.append(f"    {tags[url]}: {quote_dae(url)} {{")
            lines.append(f"        interval: {interval}s")
            lines.append("        route: direct")
            lines.append("    }")
        lines.extend(["}", ""])
        counts.subscriptions = len(urls)
    known = {node.name for node in inline}
    for nodes in remote.values():
        known.update(node.name for node in nodes)
    lines.append("group {")
    for group in groups:
        expanded = expand_members(group, tags, remote, known)
        lines.append(
            "    # merlin-members:"
            + group.name
            + "="
            + "|".join(token if kind != "sub" else f"@{token}" for kind, token in expanded)
        )
        lines.append(f"    {dae_target(group.name)} {{")
        emitted_sub = False
        emitted_names: list[str] = []
        for kind, token in expanded:
            if kind == "group":
                lines.append(f"        filter: group({dae_target(token)})")
            elif kind == "direct":
                lines.append("        filter: name(direct)")
            elif kind == "block":
                lines.append("        filter: name(block)")
            elif kind == "sub":
                if not emitted_sub:
                    lines.append(f"        filter: subtag({quote_dae(token)})")
                    emitted_sub = True
            else:
                emitted_names.append(token)
        if emitted_names:
            joined = ", ".join(quote_dae(name) for name in emitted_names)
            lines.append(f"        filter: name({joined})")
        lines.append("        policy: select")
        first = expanded[0] if expanded else None
        if first and first[0] == "node":
            lines.append(f"        default: {quote_dae(first[1])}")
        elif first and first[0] != "sub":
            lines.append(f"        default: {dae_target(first[1])}")
        elif first and first[0] == "sub":
            tag_nodes = remote.get(first[1], [])
            if tag_nodes:
                lines.append(f"        default: {quote_dae(tag_nodes[0].name)}")
        lines.append("    }")
    lines.extend(["}", "", "routing {"])
    lines.extend(rules)
    lines.append(f"    fallback: {dae_target(fallback)}")
    lines.append("}")
    lines.append("")
    counts.nodes = len(inline) + sum(len(nodes) for nodes in remote.values())
    counts.groups = len(groups)
    counts.rules = len(rules)
    return "\n".join(lines), counts


def expand_members(
    group: Group,
    tags: dict[str, str],
    remote: dict[str, list[Node]],
    known: set[str],
) -> list[tuple[str, str]]:
    expanded: list[tuple[str, str]] = []
    for member in group.members:
        upper = member.upper()
        if upper == "DIRECT":
            expanded.append(("direct", "direct"))
        elif upper == "REJECT":
            expanded.append(("block", "block"))
        elif member in known:
            expanded.append(("node", member))
        else:
            expanded.append(("group", member))
    if group.policy_path and group.policy_path in tags:
        expanded.append(("sub", tags[group.policy_path]))
    return expanded


def summary(counts: Counts) -> str:
    return (
        f"nodes={counts.nodes} groups={counts.groups} rules={counts.rules} "
        f"dropped_process_name={counts.dropped_process_name} "
        f"dropped_other={counts.dropped_other} subscriptions={counts.subscriptions}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Convert a Surge profile to honk dae")
    parser.add_argument("profile")
    parser.add_argument("-o", "--output")
    parser.add_argument("--fetch", action="store_true")
    parser.add_argument("--subscription-file", action="append", default=[], metavar="URL=PATH")
    args = parser.parse_args()
    text = open(args.profile, encoding="utf-8").read()
    preview, _ = convert(text, {})
    urls = []
    for line in preview.splitlines():
        if line.strip().startswith("#"):
            continue
    # Re-read URLs from the profile rather than the preview.
    groups = []
    section = ""
    for raw in text.splitlines():
        line = raw.strip()
        name = section_name(line) if line else None
        if name is not None:
            section = name
            continue
        if section == "Proxy Group":
            group = parse_group(line)
            if group and group.policy_path:
                groups.append(group.policy_path)
    bodies = {}
    files = {}
    for item in args.subscription_file:
        url, path = item.split("=", 1)
        files[url] = path
    for url in dict.fromkeys(groups):
        if url in files:
            bodies[url] = open(files[url], encoding="utf-8").read()
        elif args.fetch or not re.match(r"https?://", url):
            bodies[url] = load_policy(url, args.fetch or not re.match(r"https?://", url))
    rendered, counts = convert(text, bodies)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as handle:
            handle.write(rendered)
    else:
        sys.stdout.write(rendered)
    print(summary(counts), file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
