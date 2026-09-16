# 本机 vault 文档站的导出附件

这是 `diagram-png-export` 的一个站点实例，**不是所有项目都必须采用的目录结构**。只有目标确实是 vault 文档站时，才使用这里的操作。先核对该仓库的 README、构建工具和站点配置。

## 来源与样式

vault 同时有 Mermaid 代码块和手工内联 SVG。Mermaid 的当前 SVG 缓存在源稿旁 `svg-cache/`，也内嵌在构建后的 HTML 中；手工 SVG 直接写在 Markdown 中。

浏览器导出时使用 `src/style.css`、`src/fonts.css` 和 `src/assets/fonts/`。固定浅色主题，保留每张 SVG 自己的样式与 marker；不同图分开渲染，避免 `.acf` 等同名规则互相覆盖。

## 放置附件与生成预览

检查后的 PNG 放在源稿旁的同名目录，例如：

```text
src/projects/<项目>/02-design.md
src/projects/<项目>/02-design/01-components.png
src/projects/<项目>/02-design/02-storage.png
```

构建工具会自动发现这些图片并复制到对应 `content/` 目录；不手工维护站点副本。

```sh
python3.12 tools/build.py
```

按站点现有权限让 Caddy 读取：`content/` 中目录为 `0750`、文件为 `0640`，属主为 root，属组为站点配置中的 `WEB_GROUP`。再运行：

```sh
PYTHON=python3.12 tools/check.sh
PYTHON=python3.12 tools/verify.sh --live
```

预览链接使用已有站点域名，加上图片的站内路径：

```text
/projects/<项目>/02-design/01-components.png
```

现有 Caddy 直接读取 `content/`；新增静态附件不需要更改认证、路由或重载服务。写入该目录后文件即进入现有站点的访问范围。

## 清理

用户确认迁移完成且附件不再需要后，从 `src/` 的对应目录移除本次导出文件，再运行构建，由构建工具清掉 `content/` 中的旧产物；如果曾增加下载链接，也移除这些链接。

保留 Markdown、内联 SVG 和 `svg-cache/`。清理任务专用临时目录，检查原页面未受影响，运行静态与 HTTP 检查并按仓库约定更新变更记录。
