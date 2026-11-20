#!/usr/bin/env python3
"""求实工具：独立检查事实、证据引用及可选本地来源指针。"""

import argparse
import json
import sys
from pathlib import Path

from manifest_gates import check_facts


def main() -> int:
    parser = argparse.ArgumentParser(description="求实：检查 content.json 的事实与证据；--root 启用来源文件/行号核验")
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--root", type=Path, help="来源相对路径的根目录；不提供则只检查引用关系")
    args = parser.parse_args()
    try:
        data = json.loads(args.manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        data, errors = None, [f"内容清单不可读：{exc}"]
    else:
        errors = check_facts(data, args.root)
    report = {"gate": "求实", "manifest": str(args.manifest.resolve()), "errors": errors, "source_files_checked": args.root is not None}
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
