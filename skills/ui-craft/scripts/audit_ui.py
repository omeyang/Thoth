#!/usr/bin/env python3
"""UI source audit backed by the shared HTML hygiene layer."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from html_hygiene import json_report, run  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description="审计 UI 源码中的语义、焦点、动效与内容风险")
    parser.add_argument("--path", required=True, type=Path, help="HTML/CSS/JS/TS 文件或项目目录")
    parser.add_argument("--strict", action="store_true", help="warning 也使退出码变为 1")
    parser.add_argument("--json", action="store_true", help="输出机器可读 JSON")
    args = parser.parse_args()
    target = args.path.expanduser().resolve()
    if not target.exists():
        parser.error(f"路径不存在：{target}")
    findings, count = run(target)
    errors = sum(item.severity == "error" for item in findings)
    warnings = sum(item.severity == "warning" for item in findings)
    if args.json:
        print(json_report(findings, count))
    else:
        for item in findings:
            print(f"{item.path}:{item.line}: {item.severity.upper()} {item.rule}: {item.message}")
        print(f"audit_ui: {count} files, {errors} errors, {warnings} warnings")
    return 1 if errors or (args.strict and warnings) else 0


if __name__ == "__main__":
    sys.exit(main())
