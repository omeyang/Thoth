# Evals

`trigger-explain-business-visually/` 检查自然语言请求是否选择业务图解技能。支持 `claude plugin eval` 的环境可按其官方方式运行该用例；当前仓库本身不再携带 Claude 插件清单。

`explain-business-visually/fixtures/` 包含三个明确标注的假设场景：

- `refactor-risk`：历史意图、前提变化和近误对比；
- `incident-review`：错误归因、反证和三步时间线；
- `decision`：选项、代价、可逆性和证据缺口。

它们由 `scripts/tests/test_explain_business_visually.py` 与 CI 自动审计。`baseline.md` 记录旧版基线，`verification.md` 只记录实际执行结果。fixture 通过不等于独立 teach-back 盲测通过。
