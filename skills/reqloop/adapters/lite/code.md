# lite · code 槽位

## 输入

- diff 基线 `--base <ref>`（默认 `main`；`.reqloop.yaml` 的 `base` 可覆盖）
- 或 PR 号（`gh` 可用时）

## 步骤

1. **确定代码范围**（首个成功即停）：
   1. 当前分支有 upstream → `git diff <base>...HEAD`
   2. `gh pr view` 能解析出 PR → `gh pr diff`
   3. 都不行 → 请用户选择：[a] 分支 vs 基线 [b] `<from>..<to>` commit 范围 [c] PR 号
2. **采集内容**：完整 diff（新增文件拉全文）、`git log <base>..HEAD` 的 commit 列表与 message
3. **按模块归档**（单仓库多模块也要拆，供阶段 4b 做模块间影响分析）：
   - Go workspace：`go list -m` 枚举模块，按模块目录拆 diff
   - Nx / Turborepo：`nx affected` 或 `turbo run --filter` 确定受影响包
   - 其它 monorepo：按顶级目录前缀拆，每个顶级目录视为一个逻辑模块
   - 单模块仓库：整仓一个目录
4. **归档结构**

   ```
   .reqloop/code-{id}/
   ├── INDEX.md              # 模块 × diff 总览：模块名 / 文件数 / 变更行数 / commit 范围
   └── <module>/
       ├── changes.diff
       └── commits.md
   ```

## 输出字段（INDEX.md）

- 基线 ref、HEAD commit、模块列表、每模块文件数与变更行数

## 失败处理

- 基线 ref 不存在 → 中止并列出候选分支
- 跨仓库变更（不同 git remote）→ lite 不支持，INDEX.md 标注 `cross_repo: unsupported`，提示改用企业适配器
