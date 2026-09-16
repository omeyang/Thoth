# lite · requirements 槽位

## 输入

- 需求标识（任意唯一字符串：`PR-42` / `issue-123` / 自定义）
- （可选）`--prd <路径>` 本地 PRD 文件

## 步骤

1. **零配置推断需求描述**（按顺序，首个成功即停）：
   1. 当前分支有关联 PR 且 `gh` 可用 → `gh pr view --json title,body,comments`
   2. `git log --format='%s%n%b' <base>..HEAD` 拼接最近的 commit message
   3. 仓库存在 `.github/ISSUE_TEMPLATE` 且 ID 形如 `issue-N` → `gh issue view N --json title,body,comments`
2. **推断失败** → 请用户直接粘贴需求描述（PR 描述 / issue 正文 / 口头需求）
3. **附加 PRD**：用户给了路径则读全文附加；给的是链接则提示手工下载后提供路径，不自动抓取
4. **展示推断结果并一次性确认**，不逐条追问：

   ```
   需求描述: [来源 + 摘要前 3 行]
   PRD: 无 / <路径>
   > 确认 (Y/n) 或修改：
   ```

## 输出字段（写入 `.reqloop/req-{id}.md` frontmatter）

- `source: pr | commits | issue | manual`
- `source_ref`: PR 号 / commit 范围 / issue 号 / `manual`
- `has_prd: true | false`
- 正文段：需求描述、验收标准（从描述中提取的清单；没有则写「未声明」）、评论补充、PRD 附加

## 失败处理

- 三种推断全部失败且用户不提供文本 → 中止，说明没有声明侧输入无法反讲
- PRD 读取失败 → 警告继续，`has_prd: false`
