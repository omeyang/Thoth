# evals

`claude plugin eval` 用例。每个技能一个触发用例（`trigger-<skill>/`）：用用户会说的话提问，检查模型是否选中了对应技能。

```bash
claude plugin eval . --tag trigger --runs 1          # 本地快速跑一遍
claude plugin eval . --trust-plugin --json out.json --threshold 0.8   # CI
```

用例目录：`prompt.md`（frontmatter + 提问）与 `graders/*.md`（一文件一判定）。行为类用例（检查产出内容）按需追加到同一目录，判定类型见官方文档。`results/` 已加入 `.gitignore`。
