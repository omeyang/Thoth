#!/usr/bin/env python3
"""Shared manifest gates for 求实、求是 and hallucination-risk checks."""

from __future__ import annotations

import re
from pathlib import Path


def nonempty(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())


def require_fields(errors: list[str], value: object, fields: list[str], prefix: str) -> None:
    if not isinstance(value, dict):
        errors.append(f"{prefix} 必须是对象")
        return
    for field in fields:
        if not nonempty(value.get(field)):
            errors.append(f"{prefix}.{field} 缺失或为空")


def validate_references(errors: list[str], item: dict, evidence_ids: set[str], prefix: str, required: bool) -> None:
    refs = item.get("evidence")
    if not isinstance(refs, list) or (required and not refs):
        errors.append(f"{prefix}.evidence {'至少引用一个证据 ID' if required else '必须是数组'}")
        return
    for ref in refs:
        if ref not in evidence_ids:
            errors.append(f"{prefix} 引用了不存在的证据：{ref}")


def _check_source_pointer(source: str, root: Path) -> str | None:
    """Validate a local source pointer only when --root was explicitly supplied."""
    if re.match(r"^[a-z][a-z0-9+.-]*://", source, re.I):
        return None
    pointer = source.split("#", 1)[0]
    match = re.fullmatch(r"(.+?):(\d+)(?:-(\d+))?", pointer)
    line = None
    if match and not re.match(r"^[A-Za-z]:[\\/]", pointer):
        pointer, first, last = match.groups()
        line = int(first)
        if last and int(last) < line:
            return f"来源行号范围倒置：{source}"
    path = Path(pointer)
    resolved = path if path.is_absolute() else root / path
    if not resolved.is_file():
        return f"来源文件不存在：{resolved}"
    if line is not None:
        try:
            line_count = sum(1 for _ in resolved.open(encoding="utf-8"))
        except (OSError, UnicodeDecodeError) as exc:
            return f"来源文件不可读：{resolved}：{exc}"
        if line < 1 or line > line_count:
            return f"来源行号超出范围：{source}（文件共 {line_count} 行）"
    return None


def check_facts(data: object, root: Path | None = None) -> list[str]:
    """求实：证据、事实引用与可选来源指针检查。"""
    if not isinstance(data, dict):
        return ["content.json 顶层必须是对象"]
    errors: list[str] = []
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
        if root is not None and nonempty(item.get("source")):
            source_error = _check_source_pointer(item["source"], root.resolve())
            if source_error:
                errors.append(f"{prefix}：{source_error}")

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
    return errors


def check_reasoning(data: object) -> list[str]:
    """求是：显式推理、失效边界与决策代价检查。"""
    if not isinstance(data, dict):
        return ["content.json 顶层必须是对象"]
    errors: list[str] = []
    claims = data.get("claims")
    if isinstance(claims, list):
        for index, item in enumerate(claims):
            if isinstance(item, dict) and item.get("kind") in {"inference", "hypothesis"}:
                require_fields(errors, item, ["reasoning", "boundary"], f"claims[{index}]")

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
    return errors


def check_content_risks(data: object) -> list[str]:
    """Additional hallucination-risk signals; a pass is not proof of truth."""
    if not isinstance(data, dict):
        return ["content.json 顶层必须是对象"]
    errors: list[str] = []
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
    rendered = repr(data)
    for pattern in (r"\bXX\b", r"\bYY\b", r"\bTODO\b", r"\bTBD\b", r"\{\{[^{}]+\}\}"):
        if re.search(pattern, rendered, re.I):
            errors.append(f"发现未替换占位符：{pattern}")
    return errors
