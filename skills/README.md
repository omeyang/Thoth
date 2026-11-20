# Skills

当前只维护两个技能，完整目录见 [CATALOG.md](CATALOG.md)。

```text
skills/<name>/
├── SKILL.md       必需，frontmatter 的 name 与目录一致
├── references/    按需读取的方法与契约
├── scripts/       可选，标准库审计工具
├── templates/     可选，实际验收模板
└── assets/        可选，真实示例资产
```

业务图解负责事实、理解和行动；UI 工艺负责视觉、交互和可用性。不要为增加数量而新建技能，也不要恢复旧综合插件结构。

修改后运行 `scripts/gen-catalog.sh`、`scripts/validate.sh` 和全部 Python 单元测试。
