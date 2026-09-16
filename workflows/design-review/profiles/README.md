# profiles — 项目 profile（插件）

design-review 的引擎、通用模板与通用原则都在本仓库；**项目私有信息**（基线系统是谁、参考仓库在哪、
项目特有的审查原则、每晚 cron 审哪个仓库）放在仓库之外的 profile 目录里，按需加载。

## 布局

```
<profile-root>/design-review/<name>/
├─ profile.env                    # cron-batch.sh 读：REPO / REDESIGN_SUBDIR / MAX_ROUNDS / WINDOW_END_HOUR / PARENT_DOC
├─ principles.md                  # 项目原则：追加在通用 templates/principles.md 之后，优先级更高
├─ agent-legacy-archeologist.md   # 与 templates/ 同名即覆盖对应角色模板（任意 agent-*.md）
└─ design-review.yaml.example     # （可选）该项目的 .design-review.yaml 范本
```

## 查找顺序

`profile: <name>`（或 `--profile <name>` / `DR_PROFILE=<name>`）按以下顺序找第一个存在的目录：

1. `$THOTH_PROFILES/design-review/<name>`
2. `${XDG_CONFIG_HOME:-~/.config}/thoth/profiles/design-review/<name>`
3. `$THOTH_HOME/workflows/design-review/profiles/<name>`（本目录，内置）

含 `/` 或以 `~`、`$` 开头的值视为路径（支持 `$THOTH_PROFILES`、`$THOTH_HOME`、`~` 前缀展开）。

## 覆盖规则

| 内容 | 通用（本仓库） | profile |
|---|---|---|
| 角色模板 | `templates/agent-*.md` | 同名文件覆盖；或在 yaml `roles.Rn.template` 指定任意路径 |
| 原则 | `templates/principles.md` | `principles.md` 作为「项目原则」追加注入，不替换通用原则 |
| 参考仓库 | 无（示例占位） | 写在项目 `.design-review.yaml` 的 `refs.manifest`，run 时生成 refs-manifest.yaml |
| cron 旋钮 | 无 | `profile.env` |

`example/` 是可复制的骨架；私有 profile 建议放在单独的私有仓库，把该仓库根作为 `$THOTH_PROFILES`
或软链到 `~/.config/thoth/profiles`。
