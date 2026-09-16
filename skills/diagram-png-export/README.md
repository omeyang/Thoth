# diagram-png-export

跨项目交付图表 PNG 附件，供用户完整预览、下载和迁移到 WIKI。具体约定与导出步骤见 [SKILL.md](SKILL.md)。

适用于 Claude Code 和 Codex。可以将本目录链接到各自的用户级 `skills/diagram-png-export` 目录，两者复用同一份内容。

## 使用示例

- “设计篇里的图都导出 PNG”：检查 Mermaid 和手工 SVG，按页面顺序完整导出。
- “新项目画一张架构图”：交付图表时同时提供可预览的高清 PNG。
- “这张顺序图太宽，截图不完整”：从完整画布渲染，扩展越界文字所需空间。
- “只给 Mermaid 源码，不生成文件”：遵循用户本次指定，不额外生成附件。

本机 vault/Caddy 的路径和命令单独记录在[站点参考](references/vault-preview.md)中，其他项目使用自身的构建和预览方式。
