#!/usr/bin/env python3
"""Shared deterministic HTML/CSS/JS hygiene checks. Standard library only."""

from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass, replace
from html.parser import HTMLParser
from pathlib import Path
from typing import Iterable

EXTENSIONS = {".html", ".htm", ".css", ".js", ".jsx", ".ts", ".tsx"}
SKIP_DIRS = {".git", "node_modules", "dist", "build", ".next", "coverage"}


@dataclass(frozen=True)
class Finding:
    path: str
    line: int
    severity: str
    rule: str
    message: str


def line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def line_for_regex(text: str, match: re.Match[str]) -> int:
    return line_of(text, match.start())


def display(path: Path, root: Path) -> str:
    try:
        return str(path.relative_to(root if root.is_dir() else root.parent)).replace("\\", "/")
    except ValueError:
        return str(path)


class PageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.findings: list[Finding] = []
        self.ids: dict[str, int] = {}
        self.fragments: list[tuple[str, int]] = []
        self.html_attrs: dict[str, str | None] | None = None
        self.has_viewport = False
        self.has_main = False
        self.h1_count = 0
        self.open_button: dict[str, str | None] | None = None
        self.button_line = 0
        self.button_text: list[str] = []

    def add(self, line: int, severity: str, rule: str, message: str) -> None:
        self.findings.append(Finding("", line, severity, rule, message))

    def handle_starttag(self, tag: str, attrs_list: list[tuple[str, str | None]]) -> None:
        attrs = dict(attrs_list)
        line = self.getpos()[0]
        if tag == "html":
            self.html_attrs = attrs
        if tag == "main":
            self.has_main = True
        if tag == "h1":
            self.h1_count += 1
        if attrs.get("id"):
            element_id = attrs["id"] or ""
            if element_id in self.ids:
                self.add(line, "error", "duplicate-id", f"重复 id #{element_id}，首次出现在第 {self.ids[element_id]} 行")
            else:
                self.ids[element_id] = line
        if "autoplay" in attrs:
            self.add(line, "error", "autoplay", "禁止 autoplay；由读者主动开始")
        if tag == "img":
            if "alt" not in attrs:
                self.add(line, "error", "img-alt", "img 缺少 alt；装饰图使用空 alt")
            if not attrs.get("width") or not attrs.get("height"):
                self.add(line, "warning", "img-size", "img 缺少显式 width/height，可能造成布局偏移")
        if tag in {"div", "span"} and any(key.lower() == "onclick" for key in attrs):
            self.add(line, "error", "semantic-action", f"{tag} 使用 onclick；改用 button 或 a")
        if tag == "a":
            href = attrs.get("href", "") or ""
            if not href or href == "#":
                self.add(line, "error", "empty-link", "链接必须有真实导航目标")
            elif href.startswith("#"):
                self.fragments.append((href[1:], line))
            if attrs.get("target") == "_blank" and "noopener" not in (attrs.get("rel") or ""):
                self.add(line, "error", "noopener", "target=_blank 链接缺少 rel=noopener")
        if tag == "meta" and (attrs.get("name") or "").lower() == "viewport":
            self.has_viewport = True
            content = (attrs.get("content") or "").replace(" ", "").lower()
            if "user-scalable=no" in content or re.search(r"maximum-scale=(?:0|1)(?:\.0)?(?:,|$)", content):
                self.add(line, "error", "zoom", "不要禁用页面缩放")
        if tag == "button":
            self.open_button = attrs
            self.button_line = line
            self.button_text = []
        if tag in {"input", "select", "textarea"}:
            input_type = (attrs.get("type") or "").lower()
            if tag == "input" and input_type in {"hidden", "submit", "button", "reset", "image"}:
                return
            if not any(attrs.get(key) for key in ("aria-label", "aria-labelledby", "id", "title")):
                self.add(line, "error", "control-label", f"{tag} 缺少可关联 label 或可访问名称")

    def handle_data(self, data: str) -> None:
        if self.open_button is not None:
            self.button_text.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag == "button" and self.open_button is not None:
            attrs = self.open_button
            has_name = any(attrs.get(key) for key in ("aria-label", "aria-labelledby", "title"))
            if not has_name and not "".join(self.button_text).strip():
                self.add(self.button_line, "error", "button-name", "button 没有文本或可访问名称")
            self.open_button = None
            self.button_text = []

    def finish(self) -> None:
        if self.html_attrs is None or not self.html_attrs.get("lang"):
            self.add(1, "error", "html-lang", "html 缺少 lang")
        if not self.has_viewport:
            self.add(1, "error", "viewport", "页面缺少 viewport meta")
        for target, line in self.fragments:
            if target not in self.ids:
                self.add(line, "error", "fragment-target", f"链接目标不存在：#{target}")
        if not self.has_main:
            self.add(1, "warning", "main-landmark", "页面缺少 main 主区域")
        if self.h1_count == 0:
            self.add(1, "warning", "h1", "页面缺少 h1")
        elif self.h1_count > 1:
            self.add(1, "warning", "h1", f"页面包含 {self.h1_count} 个 h1，请确认层级是否有意")


def parse_html(path: Path, text: str, root: Path) -> tuple[PageParser, list[Finding]]:
    parser = PageParser()
    try:
        parser.feed(text)
        parser.close()
        parser.finish()
    except Exception as exc:
        parser.add(1, "warning", "html-parse", f"HTML 解析未完成：{exc}")
    return parser, [replace(finding, path=display(path, root)) for finding in parser.findings]


def audit_html(path: Path, text: str, root: Path) -> list[Finding]:
    return parse_html(path, text, root)[1]


def audit_source(path: Path, text: str, root: Path) -> list[Finding]:
    findings: list[Finding] = []

    def add(match: re.Match[str], severity: str, rule: str, message: str) -> None:
        findings.append(Finding(display(path, root), line_for_regex(text, match), severity, rule, message))

    patterns = [
        (r"transition(?:-property)?\s*:\s*all\b", "error", "transition-all", "transition: all 改为明确的属性列表"),
        (r"onPaste\s*=\s*\{?[^}\n]*preventDefault|onpaste\s*=\s*[\"'][^\"']*preventDefault", "error", "paste", "不要阻止用户粘贴"),
        (r"\b(?:Lorem ipsum|lorem ipsum)\b", "warning", "placeholder", "占位文案应替换为真实内容"),
        (r"\.\.\.(?:[\"'<])", "warning", "ellipsis", "界面省略号优先使用 …"),
    ]
    for pattern, severity, rule, message in patterns:
        for match in re.finditer(pattern, text, re.IGNORECASE):
            add(match, severity, rule, message)

    if path.suffix.lower() in {".css", ".html", ".jsx", ".tsx"}:
        for match in re.finditer(r"outline\s*:\s*(?:none|0)\b", text, re.IGNORECASE):
            line = line_for_regex(text, match)
            nearby = "\n".join(text.splitlines()[max(0, line - 3): line + 8])
            if "focus-visible" not in nearby and ":focus" not in nearby:
                add(match, "error", "focus-outline", "移除 outline 时必须提供清晰的焦点替代")

    has_motion = bool(re.search(r"@keyframes|\banimation\s*:|\btransition\s*:|\.animate\s*\(", text))
    if has_motion and "prefers-reduced-motion" not in text and "useReducedMotion" not in text:
        match = re.search(r"@keyframes|\banimation\s*:|\btransition\s*:|\.animate\s*\(", text)
        assert match is not None
        add(match, "warning", "reduced-motion", "检测到动效，但当前文件未见 prefers-reduced-motion 处理；请在页面级确认")
    return findings


def iter_files(target: Path) -> Iterable[Path]:
    if target.is_file():
        if target.suffix.lower() in EXTENSIONS:
            yield target
        return
    for path in sorted(target.rglob("*")):
        if path.is_file() and path.suffix.lower() in EXTENSIONS and not any(part in SKIP_DIRS for part in path.parts):
            yield path


def run(target: Path) -> tuple[list[Finding], int]:
    root = target if target.is_dir() else target.parent
    findings: list[Finding] = []
    count = 0
    for path in iter_files(target):
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError) as exc:
            findings.append(Finding(display(path, root), 1, "warning", "read", f"跳过无法读取的文件：{exc}"))
            continue
        count += 1
        if path.suffix.lower() in {".html", ".htm"}:
            findings.extend(audit_html(path, text, root))
        findings.extend(audit_source(path, text, root))
    return sorted(findings, key=lambda item: (item.path, item.line, item.rule)), count


def finding_dict(finding: Finding) -> dict[str, object]:
    return asdict(finding)


def json_report(findings: list[Finding], count: int) -> str:
    errors = sum(item.severity == "error" for item in findings)
    warnings = sum(item.severity == "warning" for item in findings)
    return json.dumps({"files": count, "errors": errors, "warnings": warnings, "findings": [finding_dict(item) for item in findings]}, ensure_ascii=False, indent=2)
