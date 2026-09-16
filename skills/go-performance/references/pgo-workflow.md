# PGO 落地完整工作流（Go 1.21 GA，1.25 成熟）

## 什么是 PGO

Profile-Guided Optimization：编译器根据**真实生产 CPU profile** 做"带证据"的决策：

1. **更激进内联**：热函数优先内联，突破默认 80 预算
2. **更好的布局**：热路径代码排在一起，cache 友好
3. **更好的分支预测提示**：常见路径标注
4. **devirtualize**：基于 profile 看到某接口调用几乎总是同一具体类型 → 直接调用

## 典型收益

- **2-14% CPU 降低**（官方数据，Go 1.21 发布）
- 零代码改动
- 对接口调用密集、小热函数多的服务效果最好
- 对 I/O bound、GC 占比高的服务效果有限

---

## 1. 基础流程

### 1.1 采集生产 profile

```bash
# 单机 30 秒
curl -o default.pgo 'http://prod-host:6060/debug/pprof/profile?seconds=30'
```

### 1.2 放置

```
myservice/
├── cmd/
│   └── app/
│       ├── main.go
│       └── default.pgo        # ← 放这里，go build 自动检测
├── go.mod
└── ...
```

### 1.3 构建

```bash
go build ./cmd/app
# 自动使用 cmd/app/default.pgo
# 输出会有 "pgo: default.pgo" 字样

# 显式指定
go build -pgo=./cmd/app/default.pgo -o app ./cmd/app

# 明确关闭（对比基线用）
go build -pgo=off -o baseline ./cmd/app
```

### 1.4 验证

```bash
# 编译两个版本
go build -pgo=off  -o baseline ./cmd/app
go build -pgo=auto -o pgoed    ./cmd/app

# 压测两个版本（用同样负载、同样时长、预热相同）
wrk -t8 -c100 -d60s http://baseline:8080/endpoint > base.txt
wrk -t8 -c100 -d60s http://pgoed:8080/endpoint    > pgo.txt

# 对比指标：RPS、p50/p99 延迟、CPU 利用率
```

---

## 2. 多机 / 多实例 profile 合并

生产通常有多个实例。一个实例的 profile 不代表全局。

```bash
# 采样多实例
for host in host-a host-b host-c; do
    curl -o "prof-$host.pb.gz" "http://$host:6060/debug/pprof/profile?seconds=60" &
done
wait

# 合并（Go 1.21+ 自动支持）
go tool pprof -proto prof-host-a.pb.gz prof-host-b.pb.gz prof-host-c.pb.gz > default.pgo
```

或用 `pprof merge`：

```bash
go install github.com/google/pprof@latest
pprof -proto prof-*.pb.gz > default.pgo
```

**合并策略**：
- 至少 3-5 个实例 × 60 秒
- 确保采样时处于**稳态**（启动完成、JIT/缓存预热、无 GC 初始化抖动）
- 避免冷启动期，至少 5 分钟后开始采样

---

## 3. 监控 profile 老化

PGO profile 是**快照**，代码变化后老 profile 可能失准。Go 编译器会宽容处理（函数不匹配就忽略），但效果打折。

**监测指标**：

```bash
# 编译时看 PGO 匹配率
go build -pgo=auto -ldflags="-v" ./cmd/app 2>&1 | grep -i pgo

# 或手动看 profile 涵盖多少当前代码
go tool pprof -top -nodecount=100 default.pgo | \
    awk 'NR>5 {print $NF}' | sort -u > pgo-funcs.txt

# 对比当前代码的函数列表
go list -f '{{range .GoFiles}}{{.}} {{end}}' ./... | xargs grep -h "^func " | \
    awk '{print $2}' | sed 's/(.*//' | sort -u > current-funcs.txt

comm -13 pgo-funcs.txt current-funcs.txt | wc -l   # PGO 没有但当前代码有的 —— 新代码
comm -23 pgo-funcs.txt current-funcs.txt | wc -l   # PGO 有但当前代码没了 —— 重构/删除
```

**更新策略**：
- 每次重大 release 前重新采样
- 或每周自动采样、CI 对比、差异大就 PR 更新 `default.pgo`

---

## 4. CI 集成

### 4.1 策略 1：checkin profile 到 repo

```bash
# 定期（如周五自动化）采样 → PR
./scripts/fetch-pgo.sh --hosts prod-a,prod-b,prod-c --duration 60 --output cmd/app/default.pgo
git add cmd/app/default.pgo
git commit -m "chore: refresh PGO profile $(date -I)"
gh pr create --title "chore: refresh PGO profile"
```

**优点**：构建可复现；审查流程完整。
**缺点**：repo 大小增加（典型 profile 1-5 MB）；更新有滞后。

### 4.2 策略 2：CI 阶段下载 profile

```yaml
# .github/workflows/build.yml
- name: Fetch latest PGO profile
  run: |
    aws s3 cp s3://our-pgo-bucket/prod/latest.pgo cmd/app/default.pgo

- name: Build with PGO
  run: go build -pgo=auto -o app ./cmd/app
```

**优点**：profile 始终最新。
**缺点**：依赖外部存储；需自动采样基础设施。

### 4.3 策略 3：两阶段 CI

阶段 1：无 PGO 构建 → 部署 canary → 采样生产 profile
阶段 2：用采到的 profile 构建正式版 → 全量部署

**适合**：超大规模服务，profile 变化快。

---

## 5. Monorepo / 多二进制

```
monorepo/
├── cmd/
│   ├── api-server/
│   │   ├── main.go
│   │   └── default.pgo       # api-server 专属 profile
│   ├── worker/
│   │   ├── main.go
│   │   └── default.pgo       # worker 专属 profile
│   └── cli/
│       └── main.go           # 无 profile，不 PGO
└── go.mod
```

**每个二进制单独采样、单独 profile**。绝对不要用同一个 profile 给所有二进制：热路径不同、浪费甚至反效果。

---

## 6. 常见问题

### Q1: 启动短命的 CLI 要 PGO 吗？

不需要。PGO 优化稳态热路径，CLI 生命周期短、代码路径分散，收益极小。

### Q2: 测试/开发构建要 PGO 吗？

不要。PGO 构建比普通构建慢 20-50%。开发期：

```bash
go build -pgo=off ./...     # 快速迭代
go build -pgo=auto ./...    # 正式 release
```

或用 `GOFLAGS`：

```bash
export GOFLAGS="-pgo=off"   # dev shell 配置
```

### Q3: PGO 和 `//go:noinline` 冲突？

PGO 不会覆盖显式 `//go:noinline` —— 你的指令优先。

### Q4: PGO 改变行为吗？

不应该。PGO 只影响优化决策，不影响正确性。但复杂 devirtualize 曾在早期版本引入过 bug（1.21.0-1.21.2），**用 1.22+ 版本更稳**。1.25 已非常成熟。

### Q5: profile 多大合适？

几百 KB 到几 MB 最常见。**过小**（<100 KB）= 采样不足；**过大**（>50 MB）= 可能包含调试符号，用 `go tool pprof -proto` 清洗。

### Q6: 能用测试 profile 吗？

能，但效果差。测试 profile 反映的是单元测试热点，和生产负载分布差异大。**只在没有生产 profile 时**作为 fallback。

---

## 7. 排查 PGO 无效

如果 PGO 开了但性能无明显改变：

1. **确认启用**：
   ```bash
   go build -pgo=auto -x -o /dev/null ./cmd/app 2>&1 | grep pgo
   ```
2. **看 profile 覆盖率**：`go tool pprof -top default.pgo` 应有代表性热点
3. **看是否瓶颈在 IO / GC**：PGO 主要优化 CPU，IO / GC bound 收益有限
4. **Go 版本太老**：1.21.0-1.21.2 有问题，升到 1.22+ / 1.25+
5. **采样不稳**：启动期、冷缓存采的 profile 不代表稳态

---

## 8. 进阶：手动组合 profile

PGO 接受任何符合 pprof protobuf 的 CPU profile。可以：

```bash
# 权重合并：生产 70% + staging 30%
# pprof merge 支持 -weight（通过 duration 模拟）
go tool pprof -proto \
    -sample_index=cpu \
    prod.pb.gz staging.pb.gz > default.pgo
```

实际场景：新功能在 staging 已验证、生产尚未全量时，合并两个环境的 profile 以提前优化。

---

## 9. 验证清单

- [ ] profile 来自稳态生产（非启动、非压力峰值的单点）
- [ ] profile 来自多实例、至少累计 3-5 分钟
- [ ] `default.pgo` 位于 `cmd/<binary>/` 下
- [ ] `go build` 输出显示 PGO 激活
- [ ] 基线 vs PGO 对比测试：RPS + p99 + CPU 利用率
- [ ] CI 每月或每大版本自动 refresh profile
- [ ] monorepo 每个二进制独立 profile
