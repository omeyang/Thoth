from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SKILL = ROOT / "skills" / "ui-craft" / "SKILL.md"


class UiCraftContractTest(unittest.TestCase):
    def test_local_references_exist(self) -> None:
        text = SKILL.read_text(encoding="utf-8")
        references = re.findall(r"\[[^]]+\]\((references/[^)]+)\)", text)
        self.assertGreaterEqual(len(references), 8)
        for reference in references:
            with self.subTest(reference=reference):
                self.assertTrue((SKILL.parent / reference).is_file())

    def test_official_methods_are_routed_and_attributed(self) -> None:
        text = SKILL.read_text(encoding="utf-8")
        sources = (SKILL.parent / "references" / "sources.md").read_text(encoding="utf-8")
        review = (SKILL.parent / "references" / "review.md").read_text(encoding="utf-8")
        self.assertIn("references/design-system.md", text)
        self.assertIn("references/figma-implementation.md", text)
        self.assertIn("Microsoft Frontend Design Review", sources)
        self.assertIn("Google Labs Stitch Skills", sources)
        self.assertIn("OpenAI Figma Implement Design", sources)
        self.assertIn("顺畅地理解到行动", review)
        self.assertIn("不是固定上限", review)


if __name__ == "__main__":
    unittest.main()
