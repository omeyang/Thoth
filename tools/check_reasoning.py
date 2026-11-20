#!/usr/bin/env python3
"""求是工具：独立检查推理、边界与决策适配。"""

import argparse
import json
import sys
from pathlib import Path

from manifest_gates import check_reasoning


def main() -> int:
    parser = argparse.ArgumentParser(description="求是：检查推断/假设的 reasoning、boundary 与决策代价")
    parser.add_argument("--manifest", required=True, type=Path)
    args = parser.parse_args()
    try:
        data = json.loads(args.manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        errors = [f"内容清单不可读：{exc}"]
    else:
        errors = check_reasoning(data)
    report = {"gate": "求是", "manifest": str(args.manifest.resolve()), "errors": errors, "reasoning_correctness_requires_review": True}
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
