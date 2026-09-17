# lite · ci 槽位

## 输入

- 验证命令：`--test-cmd` > `.reqloop.yaml` 的 `test_cmd` > 自动推断
- 环境：本地工作区（lite 不切换环境）

## 步骤

1. **推断验证命令**（首个命中即用，并展示给用户确认）：
   1. `Makefile` 含 `test` target → `make test`
   2. `go.mod` → `go test -race -cover ./... && go vet ./...`（`golangci-lint` 存在则追加 `golangci-lint run`）
   3. `package.json` 含 `test` script → `npm test`
   4. `Cargo.toml` → `cargo test`
   5. 都没有 → 请用户输入
2. **执行**：逐条运行，完整 stdout/stderr 落盘到 `.reqloop/runtime-{id}.log`
3. **归档结果**：build / test / lint 三项各自 ✅/❌，测试覆盖率（能解析时）、lint 问题数
4. 失败**不中止**流程，标红后交阶段 7 汇总

## 输出字段（写入 `.reqloop/runtime-{id}.md` frontmatter 与「CI 结果」段）

- `env: local`
- `ci_pipeline: local:<命令>`
- `build / test / lint: pass | fail | skipped`

## 失败处理

- 命令不存在 → 记 `skipped` 并提示安装；不得改用"更容易跑过"的命令
- 超时（默认 20 分钟）→ 记录已得结果，`partial: true`
