#!/usr/bin/env python3
"""Validate and package one Thoth skill as .zip and .skill archives."""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")


def frontmatter(text: str) -> dict[str, str]:
    lines = text.splitlines()
    if not lines or lines[0] != "---":
        raise ValueError("缺少 YAML frontmatter")
    try:
        end = lines.index("---", 1)
    except ValueError as exc:
        raise ValueError("frontmatter 未闭合") from exc
    result: dict[str, str] = {}
    for line in lines[1:end]:
        if ":" in line and not line.startswith((" ", "\t")):
            key, value = line.split(":", 1)
            result[key.strip()] = value.strip().strip('"').strip("'")
    return result


def validate(skill: Path) -> None:
    entry = skill / "SKILL.md"
    if not entry.is_file():
        raise ValueError(f"缺少 {entry}")
    metadata = frontmatter(entry.read_text(encoding="utf-8"))
    name = metadata.get("name", "")
    description = metadata.get("description", "")
    if not NAME_RE.fullmatch(name) or name != skill.name:
        raise ValueError("name 必须是小写短横线格式且与目录一致")
    if not description or len(description) > 1024:
        raise ValueError("description 必填且不超过 1024 字符")
    if len(entry.read_text(encoding="utf-8").splitlines()) > 500:
        raise ValueError("SKILL.md 超过 500 行")
    for path in skill.rglob("*"):
        if path.is_symlink():
            raise ValueError(f"安装包不允许符号链接：{path}")
        if path.is_file() and path.relative_to(skill).parts[0] not in {"scripts", "references", "assets"} and path.name != "SKILL.md":
            raise ValueError(f"Skill 根目录含非标准文件：{path}")


def files(skill: Path) -> list[Path]:
    return [
        path for path in sorted(skill.rglob("*"))
        if path.is_file() and "__pycache__" not in path.parts and path.suffix not in {".pyc", ".pyo"}
    ]


def write_archive(skill: Path, output: Path) -> None:
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in files(skill):
            relative = Path(skill.name) / path.relative_to(skill)
            info = zipfile.ZipInfo(relative.as_posix(), date_time=(2020, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, path.read_bytes())


def main() -> int:
    parser = argparse.ArgumentParser(description="将 Thoth Skill 打包为跨客户端安装文件")
    parser.add_argument("skill", help="skills/ 下的技能名，例如 ui-craft")
    parser.add_argument("--output", type=Path, default=ROOT / "dist", help="输出目录，默认 dist/")
    args = parser.parse_args()
    skill = (ROOT / "skills" / args.skill).resolve()
    if skill.parent != (ROOT / "skills").resolve() or not skill.is_dir():
        parser.error(f"技能目录不存在：{args.skill}")
    try:
        validate(skill)
        output = args.output.expanduser().resolve()
        output.mkdir(parents=True, exist_ok=True)
        for suffix in (".zip", ".skill"):
            archive = output / f"{args.skill}{suffix}"
            write_archive(skill, archive)
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            print(f"{archive}\tsha256={digest}")
    except (OSError, ValueError, zipfile.BadZipFile) as exc:
        print(f"package-skill: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
