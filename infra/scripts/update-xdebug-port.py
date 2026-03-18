#!/usr/bin/env python3
"""
Обновление порта Xdebug в проекте:
- xdebug.ini: xdebug.client_port=<port>
- .vscode/launch.json: configurations[*] (php, request=launch) -> port=<port>

Usage: update-xdebug-port.py <project_dir> <port>
"""
import json
import sys
from pathlib import Path


def patch_xdebug_ini(path: Path, port: int) -> bool:
    if not path.is_file():
        return False
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    changed = False
    found = False
    for i, line in enumerate(lines):
        if line.strip().startswith("xdebug.client_port="):
            if line.strip() != f"xdebug.client_port={port}":
                lines[i] = f"xdebug.client_port={port}"
                changed = True
            found = True
            break
    if not found:
        lines.append(f"xdebug.client_port={port}")
        changed = True
    if changed:
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return changed


def patch_launch(path: Path, port: int) -> bool:
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
            if c.get("port") != port:
                c["port"] = port
                changed = True
    if changed:
        path.write_text(
            json.dumps(data, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
    return changed


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: update-xdebug-port.py <project_dir> <port>", file=sys.stderr)
        return 2
    project_dir = Path(sys.argv[1]).resolve()
    if not project_dir.is_dir():
        print(f"Not a directory: {project_dir}", file=sys.stderr)
        return 1
    try:
        port = int(sys.argv[2])
    except ValueError:
        print("Port must be an integer", file=sys.stderr)
        return 1
    if port <= 0 or port > 65535:
        print("Port must be between 1 and 65535", file=sys.stderr)
        return 1

    changed_any = False
    xi = project_dir / "xdebug.ini"
    if patch_xdebug_ini(xi, port):
        changed_any = True
        print("  xdebug.ini: xdebug.client_port=%d" % port)
    launch = project_dir / ".vscode" / "launch.json"
    if patch_launch(launch, port):
        changed_any = True
        print("  .vscode/launch.json: port=%d" % port)

    return 0 if changed_any else 0


if __name__ == "__main__":
    sys.exit(main())

