#!/usr/bin/env python3
"""
Patch docker-compose.yml to enable or disable Xdebug in php service.
No external deps. Usage:
  patch-compose-xdebug.py <compose_file> enable|disable
"""
import sys
import re


def patch(compose_path: str, action: str) -> bool:
    with open(compose_path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    in_php = False
    in_env = False
    list_item_indent = "      "  # default for compose env list
    new_lines = []
    i = 0
    xdebug_mode_line_idx = -1
    first_env_line_idx = -1

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        # Detect php service start (top-level key "php:")
        if re.match(r"^\s{0,2}php\s*:", line):
            in_php = True
            in_env = False
            new_lines.append(line)
            i += 1
            continue

        # Exiting php service (next top-level key or EOF)
        if in_php and line and not line.startswith(" ") and not line.startswith("\t"):
            in_php = False
            in_env = False
            new_lines.append(line)
            i += 1
            continue

        if in_php and re.match(r"^\s{4,}environment\s*:", line):
            in_env = True
            new_lines.append(line)
            i += 1
            continue

        if in_php and in_env:
            # Still in env block (lines starting with more indent)
            if stripped.startswith("- "):
                if first_env_line_idx < 0:
                    first_env_line_idx = len(new_lines)
                    list_item_indent = line[: len(line) - len(line.lstrip())]
                if "XDEBUG_MODE" in line:
                    xdebug_mode_line_idx = len(new_lines)
                new_lines.append(line)
                i += 1
                continue
            elif stripped:
                in_env = False

        new_lines.append(line)
        i += 1

    if action == "disable":
        xdebug_line = list_item_indent + "- XDEBUG_MODE=off\n"
        if xdebug_mode_line_idx >= 0:
            pass  # Already present, no change
        elif first_env_line_idx >= 0:
            new_lines.insert(first_env_line_idx + 1, xdebug_line)
        else:
            return False
    elif action == "enable":
        if xdebug_mode_line_idx >= 0:
            new_lines.pop(xdebug_mode_line_idx)
    else:
        return False

    with open(compose_path, "w", encoding="utf-8") as f:
        f.writelines(new_lines)
    return True


def main():
    if len(sys.argv) != 3:
        print("Usage: patch-compose-xdebug.py <compose_file> enable|disable", file=sys.stderr)
        sys.exit(2)
    path = sys.argv[1]
    action = sys.argv[2]
    if action not in ("enable", "disable"):
        print("Action must be enable or disable", file=sys.stderr)
        sys.exit(2)
    if not patch(path, action):
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
