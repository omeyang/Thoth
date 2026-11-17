#!/usr/bin/env python3
"""业务图解的内容与静态结构审计；浏览器行为仍需另行实测。"""
import argparse
import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path


class PageParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ids = []
        self.links = []
        self.buttons = []
        self.images = []
        self.autoplay = False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if attrs.get("id"):
            self.ids.append(attrs["id"])
        if tag == "a" and "href" in attrs:
            self.links.append(attrs["href"])
        if tag == "button":
            self.buttons.append(attrs)
        if tag == "img":
            self.images.append(attrs)
        if "autoplay" in attrs:
            self.autoplay = True


def nonempty(value):
    return isinstance(value, str) and bool(value.strip())


def require_fields(errors, value, fields, prefix):
    if not isinstance(value, dict):
        errors.append(f"{prefix} 必须是对象")
        return
    for field in fields:
        item = value.get(field)
        if isinstance(item, list):
            if not item:
                errors.append(f"{prefix}.{field} 不能为空数组")
        elif not nonempty(item):
            errors.append(f"{prefix}.{field} 缺失或为空")


def audit(page_path, manifest_path):
    errors = []
    warnings = []
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

    for field in ["audience", "question"]:
        if not nonempty(data.get(field)):
            errors.append(f"{field} 缺失或为空")
    require_fields(errors, data.get("scenario"), ["actor", "trigger", "event", "outcome", "owner"], "scenario")
    if not isinstance(data.get("scenario"), dict) or not isinstance(data["scenario"].get("preconditions", None), list):
        errors.append("scenario.preconditions 必须是数组")

    evidence = data.get("evidence")
    evidence_ids = set()
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
        if evidence_id in evidence_ids:
            errors.append(f"{prefix}.id 重复：{evidence_id}")
        evidence_ids.add(evidence_id)

    confusions = data.get("confusions")
    if not isinstance(confusions, list) or not confusions:
        errors.append("confusions 至少需要一个易混淆场景")
        confusions = []
    for index, item in enumerate(confusions):
        require_fields(errors, item, ["scenario", "same", "different", "handling"], f"confusions[{index}]")

    examples = data.get("examples")
    if not isinstance(examples, list) or len(examples) < 2:
        errors.append("examples 至少需要两个具体示例")
        examples = []
    for index, item in enumerate(examples):
        prefix = f"examples[{index}]"
        require_fields(errors, item, ["name", "actor", "event", "result"], prefix)
        if not isinstance(item, dict):
            continue
        refs = item.get("evidence")
        if not isinstance(refs, list) or not refs:
            errors.append(f"{prefix}.evidence 至少引用一个证据 ID")
        else:
            for ref in refs:
                if ref not in evidence_ids:
                    errors.append(f"{prefix} 引用了不存在的证据：{ref}")
        if item.get("label") and item["label"] not in {"风险示例", "假设示例"}:
            errors.append(f"{prefix}.label 只能是 风险示例/假设示例")

    history = data.get("history")
    if not isinstance(history, dict) or not isinstance(history.get("applicable"), bool):
        errors.append("history.applicable 必须是布尔值")
    elif history["applicable"]:
        require_fields(errors, history, ["before", "why_no_issue", "changed"], "history")
    elif not nonempty(history.get("reason")):
        errors.append("history 不适用时必须用 reason 说明")

    impacts = data.get("impacts")
    if not isinstance(impacts, list) or not impacts:
        errors.append("impacts 至少需要一个影响对象")
        impacts = []
    for index, item in enumerate(impacts):
        require_fields(errors, item, ["area", "effect", "scope"], f"impacts[{index}]")

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
                require_fields(errors, option, ["name", "consequence"], f"decision.options[{index}]")
        if not isinstance(decision.get("missing_evidence"), list):
            errors.append("decision.missing_evidence 必须是数组")
    elif not nonempty(decision.get("reason")):
        errors.append("decision 不需要人工决策时必须用 reason 说明")

    visual = data.get("visual")
    if not isinstance(visual, dict):
        errors.append("visual 必须是对象")
    else:
        if not isinstance(visual.get("steps"), list) or len(visual["steps"]) < 2:
            errors.append("visual.steps 至少需要两个演示步骤")
        controls = set(visual.get("controls", []))
        required_controls = {"play", "pause", "previous", "next", "reset"}
        if not required_controls.issubset(controls):
            errors.append("visual.controls 必须包含 play/pause/previous/next/reset")
        if visual.get("reduced_motion") is not True:
            errors.append("visual.reduced_motion 必须为 true")
        if not isinstance(visual.get("animation"), bool):
            errors.append("visual.animation 必须是布尔值")

    claims = data.get("claims")
    if not isinstance(claims, list) or not claims:
        errors.append("claims 至少需要一条关键结论")
        claims = []
    for index, item in enumerate(claims):
        prefix = f"claims[{index}]"
        require_fields(errors, item, ["text", "kind"], prefix)
        if not isinstance(item, dict):
            continue
        if item.get("kind") not in {"fact", "risk", "inference", "hypothesis"}:
            errors.append(f"{prefix}.kind 非法")
        refs = item.get("evidence")
        if not isinstance(refs, list) or not refs:
            errors.append(f"{prefix}.evidence 至少引用一个证据 ID")
        else:
            for ref in refs:
                if ref not in evidence_ids:
                    errors.append(f"{prefix} 引用了不存在的证据：{ref}")
        if item.get("kind") != "fact":
            expected = {"risk": "风险示例", "inference": "推断", "hypothesis": "假设"}.get(item.get("kind"))
            if item.get("label") != expected:
                errors.append(f"{prefix}.label 必须明确为 {expected}")

    parser = PageParser()
    try:
        parser.feed(html)
    except Exception as exc:
        errors.append(f"HTML 解析失败：{exc}")
    if not re.search(r'<html\b[^>]*\blang=["\']zh', html, re.I):
        errors.append("HTML 必须使用中文 lang")
    if not re.search(r'<meta\b[^>]*name=["\']viewport["\']', html, re.I):
        errors.append("缺少 viewport meta")
    if re.search(r"user-scalable\s*=\s*no|maximum-scale\s*=\s*1", html, re.I):
        errors.append("不得禁止页面缩放")
    if len(parser.ids) != len(set(parser.ids)):
        errors.append("HTML 存在重复 id")
    for href in parser.links:
        if not href:
            errors.append("存在空链接")
        elif href == "#":
            errors.append("存在占位链接 href=#")
        elif href.startswith("#") and href[1:] not in parser.ids:
            errors.append(f"链接目标不存在：{href}")
    for index, attrs in enumerate(parser.images):
        if not nonempty(attrs.get("alt")):
            errors.append(f"img[{index}] 缺少有意义的 alt")
    if parser.autoplay:
        errors.append("禁止 autoplay 自动播放")
    if any("type" not in attrs for attrs in parser.buttons):
        errors.append("button 必须显式声明 type")
    if "animation" in html or "transition" in html or "setInterval" in html or "requestAnimationFrame" in html:
        if "prefers-reduced-motion" not in html:
            errors.append("含动画/过渡但缺少 prefers-reduced-motion 支持")

    # 按钮可以走内联事件、外部 JS 或表单；只报告可能的死控件，不冒充运行时验证。
    scripts = re.findall(r'<script\b[^>]*src=["\']([^"\']+)["\']', html, re.I)
    script_text = ""
    for src in scripts:
        if re.match(r"^[a-z]+://", src, re.I):
            continue
        script_path = (page_path.parent / src).resolve()
        try:
            script_text += script_path.read_text(encoding="utf-8")
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
    for pattern in [r"\bXX\b", r"\bYY\b", r"\bTODO\b", r"\bTBD\b", r"<[^>]*(?:填写|占位)[^>]*>"]:
        if re.search(pattern, visible_and_code, re.I):
            errors.append(f"发现未替换占位符：{pattern}")
    banned = data.get("banned_terms", [])
    if not isinstance(banned, list):
        errors.append("banned_terms 必须是数组")
    else:
        for term in banned:
            if nonempty(term) and term.casefold() in visible_and_code.casefold():
                errors.append(f"发现禁用或未解释术语：{term}")

    return {
        "page": str(page_path),
        "manifest": str(manifest_path),
        "errors": errors,
        "warnings": warnings,
        "summary": {
            "evidence": len(evidence), "confusions": len(confusions), "examples": len(examples),
            "impacts": len(impacts), "claims": len(claims), "buttons": len(parser.buttons), "links": len(parser.links),
        },
        "browser_verification_required": True,
    }


def main():
    parser = argparse.ArgumentParser(description="审计业务图解的内容清单和静态 HTML 结构")
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
