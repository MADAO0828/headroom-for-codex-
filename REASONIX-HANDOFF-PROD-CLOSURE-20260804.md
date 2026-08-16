# Reasonix 生产收口交接：PROD-CLOSURE-R1-R3/v1

## 状态与边界

- 集成包：`PROD-CLOSURE-20260804/v1`
- 操作包：`PROD-CLOSURE-R1-R3/v1`
- 当前状态：`PENDING`，等待 Reasonix 可读回执和用户手动激活窗口。
- C0-C4 已由 Codex 完成：`evidence/prod-closure-c0-c4-20260804.json`。
- 当前生产结论：`Route C=OFF/NO-GO`、`official_dataplane=NOT_PROVEN`。
- 允许写入：生产进程生命周期、UAC/桌面入口运行收据、官方窗口链路证据、回滚收据，以及 `README.md`/`HANDOFF.md` 追加记录。
- 禁止：修改 Codex++ 供应商定义、`config.toml`、Base URL、API key、认证、模型、会话、Vortex/系统代理、`D:\gpt-image2`；不得使用 `git reset`、`git clean` 或强制推送；不得记录凭据、会话正文或完整请求体。
- Agent 不能代替用户退出/重启当前 Codex、Codex++ Manager/Client 或确认 UAC；必须由用户手动完成窗口后继续。

## 先读证据

1. `README.md`
2. `HANDOFF.md`
3. `WORK.md`
4. `evidence/prod-closure-c0-c4-20260804.json`
5. `evidence/candidate-manifest-source-20260804.json`
6. `evidence/candidate-manifest-release-20260804.json`

最终 candidate 的 ID、entry count 和 SHA-256 以 `evidence/prod-closure-c0-c4-20260804.json` 为准。

## 用户激活窗口

请先让用户执行：

1. 退出所有官方 Codex/ChatGPT、Codex++ Manager 和 Client 窗口。
2. 确认受管 Manager/Client PID 已退出；不要按名称终止不匹配的进程。
3. 双击 `D:\Desktop\Headroom for Codex++.lnk`，必要时由用户确认 UAC/SmartScreen。
4. 等待启动入口完成后返回本任务。

用户未完成上述窗口时，操作包必须保持 `PENDING`，不得报告生产成功。

## R1：生产 ready 链

启动后只读确认：

- `18787` Gateway、`18788` Monitor、`18789` Headroom、`18790` broker、`57322` egress 以及现有 ingress/relay 端口均由预期项目路径监听。
- PID、绝对路径、启动时间、模块/源码 hash、route heartbeat 和 managed state 一致。
- `route-state` 为新鲜 `ready/process/config_mutated=false`；不得接受旧 heartbeat 或仅凭端口存在判定 ready。
- 生产启动失败时执行项目提供的回滚脚本或安全回滚流程，只停止当前 generation；保留脱敏失败收据。

## R2：官方数据面与分级流量

只在 R1 ready 后执行：

- 真实官方 PID 的网络连接必须出现 `57321 -> 18787 -> 18789 -> 57322 -> selected upstream` 的 correlation 证据；Vortex `7897` 连接不能被误计为 Headroom 成功。
- 分级放量：`1 main + 1 spawned`，再 `10 + 10`，最后 `50 + 50`。测试流量和自然窗口流量分开标记。
- 每条 SSE 必须有 `response.completed` 或标准 `response.failed`；不能出现 `stream disconnected before response.completed`、静默 EOF、解码异常或压缩层 504。
- main 仅在真实压缩候选有可复核 broker delta 时计为压缩；`main/compress` 标签不能替代 broker 计数。
- 真实 spawned 必须全部 bypass，不能仅凭 `thread_source=subagent` 判定。
- 记录 Gateway/Headroom/broker/egress/上游的脱敏 correlation、计数、fallback、worker restart 和 device loss。

## R3：切换、重启、回滚与独立收据

- 至少两次普通供应商切换：只观察管理工具预期配置变化，Headroom 不得改写供应商定义或 Base URL。
- 按计划做一次服务重启/Manager 重启和一次故障注入；非幂等请求不可因 5xx/超时盲目重放。
- 发生 ready、correlation、SSE 终态、压缩、配置哈希任一失败，立即停止当前 generation 并回滚；不得自动重试风暴或进入 Route B。
- 结束后生成可读 JSON 收据，至少包含：`status`、`package_id`、用户激活时间、端口/PID/path/hash 快照、official dataplane 判定、分级流量计数、main/spawned 分类、压缩前后计量、504/断流/解码/超时计数、配置保护哈希前后值、失败路径、回滚状态、下一步。
- 收据不得包含 key、token、完整 URL 中的凭据部分、会话正文或请求体；若状态无法确认，使用 `UNKNOWN`，不得写 `SUCCEEDED`。

## 停止条件

任一条件成立即停止并回滚：端口/路径/PID 不匹配、route heartbeat stale、`config.toml` 受保护字段变化、官方仍连接 `7897` 且无 `57321` correlation、压缩层 504、静默 SSE 断流、spawned 被压缩、设备移除重试风暴、UAC/启动失败或收据无法脱敏。

## 回交

完成或失败后把以下内容交回 Codex：

- 收据文件绝对路径和 SHA-256；
- 实际执行命令与用户激活窗口时间；
- 生产端口/PID/path/hash 证据；
- 失败时的回滚收据和残留状态；
- 明确标记 `SUCCEEDED`、`FAILED` 或 `UNKNOWN`，不得以“脚本运行结束”代替验收。

作者：Codex，2026-08-04。
