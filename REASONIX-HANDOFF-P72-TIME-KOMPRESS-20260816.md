# Headroom P72 激活与 Kompress 性能交接

状态：`SOURCE_READY / PRODUCTION_WAITING_REASONIX_ACTIVATION`

## 已知事实

- 当前官方数据面已确认经过 `18787 -> 18789 -> 57321 -> selected upstream`。
- `/status` 的时间字段保留 UTC `Z`；indicator 和 dashboard 源码已转换为本机 `China Standard Time (UTC+08:00)` 显示。
- 当前 broker：`CPUExecutionProvider/onnx`，`ready=true`，`timeout=0`，`worker_restart=0`，`device_removal=0`，`error=0`。
- 当前容量证据：`queue_limit=4`、串行 worker lock、`queue_full_delta=7`，最近记录有 `passthrough(queue_full)` 后再 `compressed`。这表示容量溢出和 fail-open，不表示 provider 崩溃。

## 用户手动激活窗口

1. 用户退出 Codex、ChatGPT、Codex++ Manager 和 Client。
2. 确认没有受管 Manager/Client/官方 app-server PID。
3. 备份当前 monitor、indicator、dashboard 和 Headroom runtime 对应文件，记录 SHA-256。
4. 使用项目现有启动/安装脚本同步 P72 源文件；不得修改供应商定义、Base URL、Key、认证、模型、会话或 Vortex。
5. 重启 Headroom/Gateway/Monitor 与官方窗口。
6. 验证顶部和独立监视器 item 时间均显示本地 `UTC+08:00`，而 `/status` 仍输出带 `Z` 的 UTC。

## 运行验收

- `/status` 的 `official_dataplane=confirmed`。
- 新 main 请求的 token `completed` 增长，`missing=0`、`invalid=0`；spawned 进入 excluded/bypass，不污染 missing。
- 记录 `queue_full_delta`、fallback、压缩成功数、p95；若当前窗口仍新增 queue-full，Kompress 保持黄色并明确标记为容量告警。
- 任何 504、静默 SSE 断流、缺失终态、解码异常都必须为 0。

## 隔离性能包

在不触碰生产的隔离 worker 中比较：

- `queue_limit=4/8/16`。
- `queue_wait_seconds=0.1/0.3/0.6`。
- 保持单 worker 与可行并行度两组。
- 每组至少 30 个 main-equivalent 压缩请求，记录 fallback rate、p95、CPU、内存和 SSE 终态。

只有在 fallback 显著下降、p95 不恶化、CPU 不过度订阅且所有终态通过时，才提出生产参数变更；否则保留当前 fail-open。

## 回滚

任何启动或验收失败：停止当前 generation，恢复备份文件，重新验证配置/供应商哈希，保留脱敏收据；不得重放非幂等请求，不得修改用户供应商配置。

作者：Codex，2026-08-16。
