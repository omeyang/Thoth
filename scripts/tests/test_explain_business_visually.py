from __future__ import annotations

import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SKILL = ROOT / "skills" / "explain-business-visually"
AUDIT_PATH = SKILL / "scripts" / "audit_explainer.py"
SPEC = importlib.util.spec_from_file_location("audit_explainer", AUDIT_PATH)
assert SPEC and SPEC.loader
AUDIT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = AUDIT
SPEC.loader.exec_module(AUDIT)


def valid_manifest() -> dict:
    return {
        "question": "结果不明时应该先查状态吗？",
        "one_sentence": "没收到结果不等于动作没有发生，先确认状态能避免重复执行。",
        "banned_terms": ["内部总线"],
        "evidence": [{"id": "E1", "source": "service.log:42", "fact": "执行记录先于超时出现。", "status": "observed"}],
        "claims": [{"text": "动作已经发生。", "kind": "fact", "evidence": ["E1"]}],
        "decision": {
            "needed": True,
            "question": "先查还是重试？",
            "owner": "值班负责人",
            "options": [
                {"name": "先查", "consequence": "确认实际状态", "cost": "多一次查询", "reversible": True},
                {"name": "重试", "consequence": "可能再次执行", "cost": "产生重复结果", "reversible": False},
            ],
        },
        "teachback": [
            {"question": "超时说明什么？", "answer": "没有收到结果。", "misconception": "没有执行。"},
            {"question": "为什么先查？", "answer": "避免重复。", "misconception": "重试总是安全。"},
            {"question": "何时可重试？", "answer": "重复执行不改变结果时。", "misconception": "任何超时都重试。"},
        ],
    }


class AuditExplainerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.page = self.root / "index.html"
        self.manifest = self.root / "content.json"
        self.page.write_text("""<!doctype html><html lang="zh-CN"><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
<body><main><section data-first-screen><h1>先确认状态，再决定是否重试</h1><p>没收到结果不等于没有执行。</p></section></main></body></html>""", encoding="utf-8")
        self.manifest.write_text(json.dumps(valid_manifest(), ensure_ascii=False), encoding="utf-8")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def update(self, mutate) -> dict:
        data = valid_manifest()
        mutate(data)
        self.manifest.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        return AUDIT.audit(self.page, self.manifest)

    def test_static_page_needs_no_legacy_quotas_or_player(self) -> None:
        report = AUDIT.audit(self.page, self.manifest)
        self.assertEqual([], report["errors"])
        self.assertTrue(report["teachback_blind_test_required"])

    def test_fact_needs_evidence_but_inference_can_be_explicit(self) -> None:
        report = self.update(lambda data: data["claims"][0].pop("evidence"))
        self.assertTrue(any("evidence" in error for error in report["errors"]))
        inference = {"text": "可能重复执行。", "kind": "inference", "reasoning": "已执行后重试会再次进入写入路径。", "boundary": "动作未执行或重复执行不改变结果时不成立。"}
        report = self.update(lambda data: data.update(claims=[inference]))
        self.assertEqual([], report["errors"])

    def test_inference_requires_reasoning_and_boundary(self) -> None:
        report = self.update(lambda data: data.update(claims=[{"text": "可能重复执行。", "kind": "inference"}]))
        self.assertTrue(any("reasoning" in error for error in report["errors"]))
        self.assertTrue(any("boundary" in error for error in report["errors"]))
        hypothesis = {"text": "重试可能放大故障。", "kind": "hypothesis", "reasoning": "重试会增加请求量。", "boundary": "重试未发生或被限流时不成立。"}
        report = self.update(lambda data: data.update(claims=[hypothesis]))
        self.assertEqual([], report["errors"])

    def test_unknown_evidence_id_is_rejected(self) -> None:
        report = self.update(lambda data: data["claims"][0].update(evidence=["missing"]))
        self.assertTrue(any("不存在的证据" in error for error in report["errors"]))

    def test_feynman_sentence_length_and_terms_are_enforced(self) -> None:
        report = self.update(lambda data: data.update(one_sentence="长" * 101))
        self.assertTrue(any("100 字" in error for error in report["errors"]))
        report = self.update(lambda data: data.update(one_sentence="内部总线导致这个问题。"))
        self.assertTrue(any("禁用术语" in error for error in report["errors"]))

    def test_first_screen_terms_must_be_defined(self) -> None:
        self.page.write_text("""<html lang="zh-CN"><head><meta name="viewport" content="width=device-width"></head><body><main><section><h1>内部总线</h1></section></main></body></html>""", encoding="utf-8")
        report = AUDIT.audit(self.page, self.manifest)
        self.assertTrue(any("未定义" in error for error in report["errors"]))
        self.page.write_text("""<html lang="zh-CN"><head><meta name="viewport" content="width=device-width"></head><body><main><section><h1><dfn>内部总线</dfn></h1><p>这里表示服务之间的消息通道。</p></section></main></body></html>""", encoding="utf-8")
        report = AUDIT.audit(self.page, self.manifest)
        self.assertFalse(any("未定义" in error for error in report["errors"]))

    def test_teachback_requires_answers_and_misconceptions(self) -> None:
        report = self.update(lambda data: data.update(teachback=data["teachback"][:2]))
        self.assertTrue(any("至少需要三题" in error for error in report["errors"]))
        report = self.update(lambda data: data["teachback"][0].pop("misconception"))
        self.assertTrue(any("misconception" in error for error in report["errors"]))

    def test_animation_uses_semantic_steps_without_mandatory_play(self) -> None:
        def add_visual(data: dict) -> None:
            data["visual"] = {
                "animation": True,
                "reduced_motion": True,
                "controls": ["pause", "previous", "next", "reset"],
                "steps": [
                    {"id": "before", "caption": "因为请求到达，所以开始处理。", "state": {"status": "new"}},
                    {"id": "after", "caption": "因为写入完成，所以出现记录。", "state": {"status": "done"}, "final": True},
                ],
            }
        self.page.write_text("""<html lang="zh-CN"><head><meta name="viewport" content="width=device-width"></head><body><main><section><h1>状态变化</h1><div data-step="before">开始</div><div data-step="after">完成</div></section></main></body></html>""", encoding="utf-8")
        report = self.update(add_visual)
        self.assertEqual([], report["errors"])

    def test_animation_rejects_static_steps_and_missing_final_state(self) -> None:
        def add_bad_visual(data: dict) -> None:
            data["visual"] = {
                "animation": True, "reduced_motion": True, "controls": ["pause", "previous", "next", "reset"],
                "steps": [
                    {"id": "before", "caption": "第一步。", "state": {"status": "same"}},
                    {"id": "after", "caption": "第二步。", "state": {"status": "same"}},
                ],
            }
        self.page.write_text("""<html lang="zh-CN"><head><meta name="viewport" content="width=device-width"></head><body><main><section><h1>状态变化</h1><div data-step="before"></div><div data-step="after"></div></section></main></body></html>""", encoding="utf-8")
        report = self.update(add_bad_visual)
        self.assertTrue(any("不构成状态变化" in error for error in report["errors"]))
        self.assertTrue(any("最终静态状态" in error for error in report["errors"]))

    def test_shared_html_hygiene_reports_hard_errors(self) -> None:
        self.page.write_text("""<html lang="zh-CN"><head><meta name="viewport" content="width=device-width, maximum-scale=1"></head><body><main><section><h1 id="x">重复</h1><a id="x" href="#">空链接</a><video autoplay></video></section></main></body></html>""", encoding="utf-8")
        report = AUDIT.audit(self.page, self.manifest)
        for rule in ("zoom", "duplicate-id", "empty-link", "autoplay"):
            self.assertTrue(any(rule in error for error in report["errors"]), rule)

    def test_standalone_package_contains_shared_audit_and_templates(self) -> None:
        output = self.root / "dist"
        command = [sys.executable, str(ROOT / "scripts" / "package-skill.py"), "explain-business-visually", "--output", str(output)]
        subprocess.run(command, check=True, capture_output=True, text=True, encoding="utf-8")
        archive_path = output / "explain-business-visually.skill"
        with zipfile.ZipFile(archive_path) as archive:
            names = archive.namelist()
            self.assertIn("explain-business-visually/scripts/html_hygiene.py", names)
            self.assertIn("explain-business-visually/scripts/manifest_gates.py", names)
            self.assertIn("explain-business-visually/templates/teachback.md", names)
            self.assertNotIn("explain-business-visually/references/content-quality.md", names)
            archive.extractall(self.root / "unpacked")
        script = self.root / "unpacked" / "explain-business-visually" / "scripts" / "audit_explainer.py"
        result = subprocess.run([sys.executable, str(script), "--help"], check=False, capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(0, result.returncode, result.stderr)


if __name__ == "__main__":
    unittest.main()
