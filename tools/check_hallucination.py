#!/usr/bin/env python3
"""防幻觉工具：组合求实、求是、占位符和术语风险检查。"""

import argparse
import json
import sys
from pathlib import Path

from manifest_gates import check_content_risks, check_facts, check_reasoning


def main() -> int:
    parser = argparse.ArgumentParser(description="防幻觉：组合求实、求是和内容风险检查；通过不等于绝对无幻觉")
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--root", type=Path, help="同时核验来源文件与行号")
    args = parser.parse_args()
    try:
        data = json.loads(args.manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        errors = [f"内容清单不可读：{exc}"]
    else:
        errors = check_facts(data, args.root) + check_reasoning(data) + check_content_risks(data)
    report = {
        "gate": "防幻觉",
        "manifest": str(args.manifest.resolve()),
        "checks": ["求实", "求是", "占位符", "禁用术语"],
        "errors": errors,
        "guarantee": "仅发现可静态检查的风险，不能证明不存在幻觉",
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
