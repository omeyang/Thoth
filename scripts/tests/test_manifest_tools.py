from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "tools"


def manifest() -> dict:
    return {
        "question": "这次变更是否安全？",
        "one_sentence": "已有记录支持当前事实，推断仍需说明边界。",
        "banned_terms": ["内部代号"],
        "evidence": [{"id": "E1", "source": "evidence.txt:1", "fact": "测试记录显示一次写入。", "status": "observed"}],
        "claims": [{"text": "发生了一次写入。", "kind": "fact", "evidence": ["E1"]}],
        "decision": {
            "needed": True,
            "question": "是否继续？",
            "owner": "负责人",
            "options": [
                {"name": "继续", "consequence": "应用变更", "cost": "需要观察", "reversible": True},
                {"name": "暂停", "consequence": "保持现状", "cost": "延后交付", "reversible": True},
            ],
        },
    }


class ManifestToolsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "evidence.txt").write_text("one write\n", encoding="utf-8")
        self.manifest = self.root / "content.json"
        self.write(manifest())

    def tearDown(self) -> None:
        self.temp.cleanup()

    def write(self, data: dict) -> None:
        self.manifest.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")

    def run_tool(self, name: str, root: bool = True) -> tuple[subprocess.CompletedProcess, dict]:
        command = [sys.executable, str(TOOLS / name), "--manifest", str(self.manifest)]
        if root and name != "check_reasoning.py":
            command += ["--root", str(self.root)]
        result = subprocess.run(command, check=False, capture_output=True, text=True, encoding="utf-8")
        return result, json.loads(result.stdout)

    def test_three_tools_run_independently(self) -> None:
        for name, gate in (("verify_facts.py", "求实"), ("check_reasoning.py", "求是"), ("check_hallucination.py", "防幻觉")):
            with self.subTest(tool=name):
                result, payload = self.run_tool(name)
                self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                self.assertEqual(gate, payload["gate"])
                self.assertEqual([], payload["errors"])

    def test_facts_can_verify_source_file_and_line(self) -> None:
        data = manifest()
        data["evidence"][0]["source"] = "evidence.txt:2"
        self.write(data)
        result, payload = self.run_tool("verify_facts.py")
        self.assertEqual(1, result.returncode)
        self.assertTrue(any("行号超出范围" in error for error in payload["errors"]))

    def test_facts_reject_unknown_evidence(self) -> None:
        data = manifest()
        data["claims"][0]["evidence"] = ["missing"]
        self.write(data)
        result, payload = self.run_tool("verify_facts.py")
        self.assertEqual(1, result.returncode)
        self.assertTrue(any("不存在的证据" in error for error in payload["errors"]))

    def test_reasoning_requires_reasoning_and_boundary(self) -> None:
        data = manifest()
        data["claims"].append({"text": "可能重复写入。", "kind": "inference"})
        self.write(data)
        result, payload = self.run_tool("check_reasoning.py", root=False)
        self.assertEqual(1, result.returncode)
        self.assertTrue(any("reasoning" in error for error in payload["errors"]))
        self.assertTrue(any("boundary" in error for error in payload["errors"]))

    def test_hallucination_combines_all_gates_and_content_risks(self) -> None:
        data = manifest()
        data["one_sentence"] = "TODO：等待内部代号确认"
        data["claims"].append({"text": "可能重复写入。", "kind": "hypothesis"})
        self.write(data)
        result, payload = self.run_tool("check_hallucination.py")
        self.assertEqual(1, result.returncode)
        for text in ("占位符", "禁用术语", "reasoning", "boundary"):
            self.assertTrue(any(text in error for error in payload["errors"]), text)
        self.assertIn("不能证明", payload["guarantee"])

    def test_invalid_json_is_reported_by_each_tool(self) -> None:
        self.manifest.write_text("{broken", encoding="utf-8")
        for name in ("verify_facts.py", "check_reasoning.py", "check_hallucination.py"):
            with self.subTest(tool=name):
                result, payload = self.run_tool(name)
                self.assertEqual(1, result.returncode)
                self.assertTrue(any("不可读" in error for error in payload["errors"]))


if __name__ == "__main__":
    unittest.main()
