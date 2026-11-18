from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
AUDIT_PATH = ROOT / "skills" / "ui-craft" / "scripts" / "audit_ui.py"
SPEC = importlib.util.spec_from_file_location("audit_ui", AUDIT_PATH)
assert SPEC and SPEC.loader
AUDIT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = AUDIT
SPEC.loader.exec_module(AUDIT)


class AuditUiTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def write(self, text: str) -> Path:
        page = self.root / "index.html"
        page.write_text(text, encoding="utf-8")
        return page

    def test_clean_page_has_no_findings(self) -> None:
        page = self.write("""<!doctype html>
<html lang="zh-CN"><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
<body><main><h1>浏览器如何更新页面</h1><img src="diagram.svg" alt="渲染流程" width="640" height="360">
<label for="step">步骤</label><input id="step" name="step"><button type="button">下一步</button>
<style>button { transition: transform 160ms ease-out; }
@media (prefers-reduced-motion: reduce) { button { transition: none; } }</style>
</main></body></html>""")
        findings, count = AUDIT.run(page)
        self.assertEqual(1, count)
        self.assertEqual([], findings)

    def test_bad_page_reports_actionable_rules(self) -> None:
        page = self.write("""<html><head><meta name="viewport" content="width=device-width, maximum-scale=1"></head>
<body><div onclick="go()">打开</div><img src="x.png"><button aria-label="设置"></button>
<input type="text"><a href="https://example.com" target="_blank">外部</a>
<style>div { transition: all 300ms; outline: none; }</style><p>Lorem ipsum...</p></body></html>""")
        findings, _ = AUDIT.run(page)
        rules = {finding.rule for finding in findings}
        self.assertTrue({"zoom", "semantic-action", "img-alt", "img-size", "control-label", "noopener", "transition-all", "focus-outline", "placeholder", "ellipsis", "html-lang", "main-landmark", "h1", "reduced-motion"}.issubset(rules))

    def test_json_output_is_machine_readable(self) -> None:
        page = self.write("<html><body><main><h1>测试</h1></main></body></html>")
        result = subprocess.run(
            [sys.executable, str(AUDIT_PATH), "--path", str(page), "--json"],
            check=False, capture_output=True, text=True, encoding="utf-8",
        )
        self.assertEqual(1, result.returncode)
        payload = json.loads(result.stdout)
        self.assertEqual(1, payload["files"])
        self.assertEqual("html-lang", payload["findings"][0]["rule"])

    def test_package_contains_root_and_is_reproducible(self) -> None:
        output = self.root / "dist"
        command = [sys.executable, str(ROOT / "scripts" / "package-skill.py"), "ui-craft", "--output", str(output)]
        first = subprocess.run(command, check=True, capture_output=True, text=True, encoding="utf-8")
        archive_path = output / "ui-craft.skill"
        first_bytes = archive_path.read_bytes()
        subprocess.run(command, check=True, capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(first_bytes, archive_path.read_bytes())
        self.assertIn("sha256=", first.stdout)
        with zipfile.ZipFile(archive_path) as archive:
            names = archive.namelist()
            self.assertIn("ui-craft/SKILL.md", names)
            self.assertIn("ui-craft/scripts/audit_ui.py", names)
            self.assertTrue(all(name.startswith("ui-craft/") for name in names))
            self.assertIsNone(archive.testzip())


if __name__ == "__main__":
    unittest.main()
