#!/usr/bin/env python3
"""Audit the six-field explainer contract; never claim comprehension from static checks."""

from __future__ import annotations

import argparse
import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
SHARED_DIR = SCRIPT_DIR if (SCRIPT_DIR / "html_hygiene.py").is_file() else SCRIPT_DIR.parent.parent / "ui-craft" / "scripts"
sys.path.insert(0, str(SHARED_DIR))
from html_hygiene import run as audit_hygiene  # noqa: E402


class ContentParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.buttons: list[dict[str, str | None]] = []
        self.scripts: list[str] = []
        self.inline_scripts: list[str] = []
        self.step_ids: list[str] = []
        self.first_screen: list[str] = []
        self.defined_terms: set[str] = set()
        self.capture_depth = 0
        self.seen_first_screen = False
        self.definitions: list[dict[str, object]] = []
        self.in_script = False

    def handle_starttag(self, tag: str, attrs_list: list[tuple[str, str | None]]) -> None:
        attrs = dict(attrs_list)
        if tag == "button":
            self.buttons.append(attrs)
        if tag == "script":
            self.in_script = True
            self.inline_scripts.append("")
            if attrs.get("src"):
                self.scripts.append(attrs["src"] or "")
        if attrs.get("data-step"):
            self.step_ids.append(attrs["data-step"] or "")
        if self.capture_depth:
            self.capture_depth += 1
        elif not self.seen_first_screen and ("data-first-screen" in attrs or tag == "section"):
            self.seen_first_screen = True
            self.capture_depth = 1
        if self.capture_depth and tag in {"dfn", "abbr"} and (tag == "dfn" or attrs.get("title")):
            self.definitions.append({"tag": tag, "depth": self.capture_depth, "text": []})

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.handle_starttag(tag, attrs)
        self.handle_endtag(tag)

    def handle_data(self, data: str) -> None:
        if self.in_script:
            self.inline_scripts[-1] += data
        if self.capture_depth:
            self.first_screen.append(data)
            for definition in self.definitions:
                definition["text"].append(data)  # type: ignore[index]

    def handle_endtag(self, tag: str) -> None:
        if tag == "script":
            self.in_script = False
        if self.capture_depth and self.definitions:
            definition = self.definitions[-1]
            if definition["tag"] == tag and definition["depth"] == self.capture_depth:
                term = "".join(definition["text"]).strip()  # type: ignore[arg-type]
                if term:
                    self.defined_terms.add(term.casefold())
                self.definitions.pop()
        if self.capture_depth:
            self.capture_depth -= 1


def nonempty(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())


def require_fields(errors: list[str], value: object, fields: list[str], prefix: str) -> None:
    if not isinstance(value, dict):
        errors.append(f"{prefix} 必须是对象")
        return
    for field in fields:
        if not nonempty(value.get(field)):
            errors.append(f"{prefix}.{field} 缺失或为空")


def validate_references(errors: list[str], item: dict[str, object], evidence_ids: set[str], prefix: str, required: bool) -> None:
    refs = item.get("evidence")
    if not isinstance(refs, list) or (required and not refs):
        errors.append(f"{prefix}.evidence {'至少引用一个证据 ID' if required else '必须是数组'}")
        return
    for ref in refs:
        if ref not in evidence_ids:
            errors.append(f"{prefix} 引用了不存在的证据：{ref}")


def audit(page_path: str | Path, manifest_path: str | Path) -> dict[str, object]:
    errors: list[str] = []
    warnings: list[str] = []
    page_path = Path(page_path).resolve()
    manifest_path = Path(manifest_path).resolve()
    try:
        html = page_path.read_text(encoding="utf-8")
    except OSError as exc:
        return {"page": str(page_path), "manifest": str(manifest_path), "errors": [f"页面不可读：{exc}"], "warnings": warnings}
    try:
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return {"page": str(page_path), "manifest": str(manifest_path), "errors": [f"内容清单不可读：{exc}"], "warnings": warnings}
    if not isinstance(data, dict):
        return {"page": str(page_path), "manifest": str(manifest_path), "errors": ["content.json 顶层必须是对象"], "warnings": warnings}

    for field in ("question", "one_sentence"):
        if not nonempty(data.get(field)):
            errors.append(f"{field} 缺失或为空")
    sentence = data.get("one_sentence")
    if nonempty(sentence) and len(re.sub(r"\s+", "", sentence)) > 100:
        errors.append("one_sentence 超过 100 字")

    banned = data.get("banned_terms", [])
    if not isinstance(banned, list) or any(not nonempty(term) for term in banned):
        errors.append("banned_terms 必须是非空字符串数组")
        banned = []
    for term in banned:
        if nonempty(sentence) and term.casefold() in sentence.casefold():
            errors.append(f"one_sentence 含禁用术语：{term}")

    evidence = data.get("evidence")
    evidence_ids: set[str] = set()
    if not isinstance(evidence, list) or not evidence:
        errors.append("evidence 至少需要一条")
        evidence = []
    for index, item in enumerate(evidence):
        prefix = f"evidence[{index}]"
        require_fields(errors, item, ["id", "source", "fact", "status"], prefix)
        if not isinstance(item, dict):
            continue
        if item.get("status") not in {"observed", "verified", "documented"}:
            errors.append(f"{prefix}.status 必须是 observed/verified/documented")
        evidence_id = item.get("id")
        if nonempty(evidence_id):
            if evidence_id in evidence_ids:
                errors.append(f"{prefix}.id 重复：{evidence_id}")
            evidence_ids.add(evidence_id)

    claims = data.get("claims")
    if not isinstance(claims, list) or not claims:
        errors.append("claims 至少需要一条")
        claims = []
    for index, item in enumerate(claims):
        prefix = f"claims[{index}]"
        require_fields(errors, item, ["text", "kind"], prefix)
        if not isinstance(item, dict):
            continue
        kind = item.get("kind")
        if kind not in {"fact", "inference", "hypothesis"}:
            errors.append(f"{prefix}.kind 必须是 fact/inference/hypothesis")
        if "evidence" in item or kind == "fact":
            validate_references(errors, item, evidence_ids, prefix, kind == "fact")

    decision = data.get("decision")
    if not isinstance(decision, dict) or not isinstance(decision.get("needed"), bool):
        errors.append("decision.needed 必须是布尔值")
    elif decision["needed"]:
        require_fields(errors, decision, ["question", "owner"], "decision")
        options = decision.get("options")
        if not isinstance(options, list) or len(options) < 2:
            errors.append("decision.options 至少需要两个真实选项")
        else:
            for index, option in enumerate(options):
                prefix = f"decision.options[{index}]"
                require_fields(errors, option, ["name", "consequence", "cost"], prefix)
                if isinstance(option, dict) and not isinstance(option.get("reversible"), bool):
                    errors.append(f"{prefix}.reversible 必须是布尔值")
        if "missing_evidence" in decision and not isinstance(decision["missing_evidence"], list):
            errors.append("decision.missing_evidence 必须是数组")
    elif not nonempty(decision.get("reason")):
        errors.append("decision 不需要人工决策时必须用 reason 说明")

    teachback = data.get("teachback")
    if not isinstance(teachback, list) or len(teachback) < 3:
        errors.append("teachback 至少需要三题")
        teachback = []
    for index, item in enumerate(teachback):
        require_fields(errors, item, ["question", "answer", "misconception"], f"teachback[{index}]")

    visual = data.get("visual", {})
    if not isinstance(visual, dict):
        errors.append("visual 必须是对象")
        visual = {}
    animation = visual.get("animation", False)
    if not isinstance(animation, bool):
        errors.append("visual.animation 必须是布尔值")
        animation = False
    animation_steps = visual.get("steps", [])
    if animation:
        if visual.get("reduced_motion") is not True:
            errors.append("有动画时 visual.reduced_motion 必须为 true")
        controls = set(visual.get("controls", []))
        missing = {"pause", "previous", "next", "reset"} - controls
        if missing:
            errors.append(f"有动画时缺少控件：{'/'.join(sorted(missing))}")
        if not isinstance(animation_steps, list) or not animation_steps:
            errors.append("有动画时 visual.steps 不能为空")
            animation_steps = []
        previous_state: object = object()
        final_count = 0
        for index, step in enumerate(animation_steps):
            prefix = f"visual.steps[{index}]"
            require_fields(errors, step, ["id", "caption"], prefix)
            if not isinstance(step, dict):
                continue
            state = step.get("state")
            if not state:
                errors.append(f"{prefix}.state 必须描述非空状态")
            if index and state == previous_state:
                errors.append(f"{prefix}.state 与上一步相同，不构成状态变化")
            previous_state = state
            if step.get("final") is True:
                final_count += 1
        if animation_steps and not final_count:
            errors.append("动画至少需要一个 final=true 的最终静态状态")

    findings, _ = audit_hygiene(page_path)
    for finding in findings:
        message = f"{finding.path}:{finding.line} {finding.rule}: {finding.message}"
        (errors if finding.severity == "error" else warnings).append(message)

    parser = ContentParser()
    try:
        parser.feed(html)
        parser.close()
    except Exception as exc:
        errors.append(f"内容解析失败：{exc}")
    first_screen = " ".join(parser.first_screen)
    for term in banned:
        if term.casefold() in first_screen.casefold() and term.casefold() not in parser.defined_terms:
            errors.append(f"首屏出现未定义的内部术语：{term}")

    if animation and isinstance(animation_steps, list):
        page_steps = set(parser.step_ids)
        for index, step in enumerate(animation_steps):
            if isinstance(step, dict) and nonempty(step.get("id")) and step["id"] not in page_steps:
                errors.append(f"visual.steps[{index}].id 未对应页面 data-step：{step['id']}")

    script_text = "\n".join(parser.inline_scripts)
    for src in parser.scripts:
        if re.match(r"^[a-z]+://", src, re.I):
            continue
        script_path = (page_path.parent / src).resolve()
        try:
            script_text += "\n" + script_path.read_text(encoding="utf-8")
        except OSError:
            errors.append(f"脚本不可读：{script_path}")
    for attrs in parser.buttons:
        button_id = attrs.get("id")
        if not button_id:
            warnings.append("存在无 id 按钮，需人工核对其处理器")
            continue
        inline = any(key.lower().startswith("on") for key in attrs)
        bound = re.search(rf"(?:getElementById\(['\"]{re.escape(button_id)}['\"]\)|\$\(['\"]{re.escape(button_id)}['\"]\)|querySelector\(['\"]#?{re.escape(button_id)}['\"]\)|#{re.escape(button_id)}\b)", script_text)
        if not inline and not bound:
            errors.append(f"按钮 {button_id} 未找到处理器证据")

    visible_and_code = html + "\n" + script_text
    for pattern in (r"\bXX\b", r"\bYY\b", r"\bTODO\b", r"\bTBD\b", r"\{\{[^{}]+\}\}"):
        if re.search(pattern, visible_and_code, re.I):
            errors.append(f"发现未替换占位符：{pattern}")

    return {
        "page": str(page_path),
        "manifest": str(manifest_path),
        "errors": errors,
        "warnings": warnings,
        "summary": {
            "evidence": len(evidence),
            "claims": len(claims),
            "teachback": len(teachback),
            "animation_steps": len(animation_steps) if isinstance(animation_steps, list) else 0,
        },
        "browser_verification_required": True,
        "teachback_blind_test_required": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="审计业务图解的六字段契约和共享 HTML 卫生规则")
    parser.add_argument("--page", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--output")
    args = parser.parse_args()
    report = audit(args.page, args.manifest)
    rendered = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        Path(args.output).write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 1 if report["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
