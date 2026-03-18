#!/usr/bin/env python3
"""
Миграция Xdebug в проекте: compose (volume xdebug.ini, extra_hosts, без XDEBUG_CONFIG),
xdebug.ini (log_level), .vscode/launch.json (hostname 0.0.0.0).
Usage: migrate-xdebug-project-layout.py <project_dir>
Exit 0 если что-то изменилось или уже ок, 1 при ошибке.
"""
import json
import re
import sys
from pathlib import Path


def php_service_lines(lines):
    start = None
    for i, line in enumerate(lines):
        if re.match(r"^  php\s*:", line):
            start = i
            break
    if start is None:
        return None
    j = start + 1
    while j < len(lines):
        ln = lines[j]
        if ln.strip() and re.match(r"^  [a-zA-Z0-9_-]+\s*:", ln):
            break
        j += 1
    return start, j


def patch_compose(path: Path) -> bool:
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines(keepends=True)
    span = php_service_lines(lines)
    if not span:
        return False
    a, b = span
    sec = lines[a:b]
    changed = False
    new_sec: list[str] = []
    vol_added = any("xdebug.ini" in x and "conf.d" in x for x in sec)
    for line in sec:
        if "XDEBUG_CONFIG" in line and "client_host" in line:
            changed = True
            continue
        new_sec.append(line)
        if (
            not vol_added
            and line.strip().startswith("- ./")
            and "php.ini" in line
            and "custom.ini" in line
        ):
            indent = re.match(r"^(\s*)", line)
            ind = indent.group(1) if indent else "      "
            new_sec.append(f"{ind}- ./xdebug.ini:/usr/local/etc/php/conf.d/xdebug.ini:ro\n")
            vol_added = True
            changed = True
    if not vol_added:
        out2: list[str] = []
        for line in new_sec:
            out2.append(line)
            if "logs/php" in line and "/var/log/php" in line:
                ind = re.match(r"^(\s*)", line)
                i = ind.group(1) if ind else "      "
                out2.append(f"{i}- ./xdebug.ini:/usr/local/etc/php/conf.d/xdebug.ini:ro\n")
                vol_added = True
                changed = True
        new_sec = out2
    if not any("host-gateway" in x for x in new_sec):
        out3: list[str] = []
        for line in new_sec:
            if line.strip() == "networks:":
                out3.append("    extra_hosts:\n")
                out3.append('      - "host.docker.internal:host-gateway"\n')
                changed = True
            out3.append(line)
        new_sec = out3
    if changed or new_sec != sec:
        if new_sec != sec:
            changed = True
        lines[a:b] = new_sec
        path.write_text("".join(lines), encoding="utf-8")
    return changed


def patch_xdebug_ini(path: Path) -> bool:
    if not path.is_file():
        return False
    t = path.read_text(encoding="utf-8", errors="replace")
    orig = t
    if "единый источник правды" not in t and "[xdebug]" in t:
        t = t.replace(
            "[xdebug]",
            "[xdebug]\n; client_host — единый источник правды вместе с extra_hosts в compose",
            1,
        )
    if "xdebug.log_level" not in t:
        t = t.rstrip() + (
            "\n\n; Уровень лога: 1 по умолчанию; при диагностике можно поднять до 7\n"
            "xdebug.log_level=1\n"
        )
    if t != orig:
        path.write_text(t, encoding="utf-8")
        return True
    return False


def patch_launch(path: Path) -> bool:
    if not path.is_file():
        return False
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return False
    cfgs = data.get("configurations") or []
    changed = False
    for c in cfgs:
        if c.get("type") == "php" and c.get("request") == "launch":
            if c.get("hostname") != "0.0.0.0":
                c["hostname"] = "0.0.0.0"
                changed = True
    if changed:
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return changed


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: migrate-xdebug-project-layout.py <project_dir>", file=sys.stderr)
        return 2
    d = Path(sys.argv[1]).resolve()
    if not d.is_dir():
        print(f"Not a directory: {d}", file=sys.stderr)
        return 1
    compose = d / "docker-compose.yml"
    n = 0
    if compose.is_file():
        if patch_compose(compose):
            n += 1
            print(f"  compose: {compose.name}")
    xi = d / "xdebug.ini"
    if xi.is_file() and patch_xdebug_ini(xi):
        n += 1
        print(f"  xdebug.ini")
    launch = d / ".vscode" / "launch.json"
    if launch.is_file() and patch_launch(launch):
        n += 1
        print(f"  .vscode/launch.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
