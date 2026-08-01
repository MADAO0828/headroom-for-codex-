# Headroom for Codex++

## 功能与目的

这是 Codex++ 的本地 Headroom 代理工程：通过统一启动链路、独立 Policy Gateway、请求分类和 Headroom 压缩，降低主对话上下文开销，同时保证 spawned 子 Agent 不被错误压缩，并在压缩失败时继续转发原始请求。

## 框架与运行链路

- Python 3.14 + FastAPI/Uvicorn + HTTPX：Policy Gateway `127.0.0.1:18787`。
- Headroom `0.32.1`：代理 `127.0.0.1:18789`，上游 Codex++ helper `127.0.0.1:57321`。
- ONNX Runtime CPU `1.28.0`：当前生产 Kompress 后端。
- PowerShell 7：启动、路由守护、监控和状态页。
- Codex++ 管理工具通过进程级环境覆盖获得路由，不修改供应商配置文件。

请求策略固定为：`main -> compress`，`spawned -> bypass`。Gateway 保留原始 SSE 字节；上游异常 EOF 会补发标准 `response.failed` 终止事件。

## 唯一启动方法

执行项目根目录的：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "D:\新建文件夹\headroom for codex++\scripts\Start-HeadroomForCodexPP.ps1"
```

顺序为 Headroom proxy、Gateway、路由守护、Codex++ 管理工具、Codex++ 客户端。旧的两个独立桌面快捷方式不应再并行点击。启动脚本必须等待 `/livez`、`/health` 和进程级路由证据；Headroom 未 ready 时不得让客户端盲发请求。

## 当前进度

- Gateway spawned 分类、冲突 metadata 保护、内部 header 剥离、SSE fail-open 已完成；Python 合同测试 `27/27`，PowerShell startup-chain `PASS`。
- route keeper/startup gate 已改为只读供应商配置、进程级路由覆盖；最终 route-state 为 `route_scope=process`、`config_mutated=false`。跨轮配置 hash 可能因用户自行切换供应商而变化，本轮不据历史 hash 推断未变。
- CPU ORT `1.28.0` 已在隔离 worker 真实调用 Kompress，session provider 为 `CPUExecutionProvider`；证据见 `evidence/cpu-kompress-ort-20260731.json`。生产链保持单 worker、`intra_op=12`、`inter_op=1`、并发上限 1。
- 压缩端点的 token 契约已修复：当压缩标记开销导致 `tokens_after > tokens_before` 时，`tokens_saved` 归一为 0，不再返回负节省。
- 之前的 50+50 压力窗口曾复现 36 个 504（main 35/50、spawned 29/50）；并发 8 路时全部触发 Headroom 单压缩槽/约 25-30 秒预算耗尽，监控的短探测也会误报未就绪。该窗口已标记为失败证据，不再当作验收结果。
- fail-open 修复后，8 路并发（4 main + 4 spawned）全部 HTTP 200；随后 50+50 `/v1/compress` 合同重跑全部 200、504=0、旁路误压缩=0、负节省=0，脱敏结果见 `evidence/synthetic-acceptance-20260731-rerun.json`。重启后的 2+2 smoke 见 `evidence/post-restart-compress-smoke-20260731.json`。
- `scripts/Clear-HeadroomRuntimeArtifacts.ps1 -Execute` 已覆盖项目日志、状态、路由/启动快照、隔离 broker 状态和 TEMP 启动日志；最近一次清理 `evidence/runtime-clear-20260801-040406445.json` 为 `completed`，19/19 已备份并删除，剩余 0。
- P15/v2/v3 已修复 Gateway/helper 与 monitor 的预启动门禁，并通过 fixture、startup-chain、AST parser 和编码检查；真实唯一入口仍未通过最终启动验收。
- 项目根目录保留源码、脚本、缓存和完整 Kompress 模型 blob；运行日志/计数按验收要求清零，受保护会话、凭据、认证数据库和完整会话正文仍留在原位置，不能复制或上传。

## 未解决问题

1. Headroom `/debug/warmup` 在当前 Uvicorn worker 仍显示 `Kompress=deferred`，`/health` 的 Kompress check 为 deferred/unhealthy；独立真实推理已证明 CPU ONNX 可用，Gateway 会在该状态下 fail-open。若要让状态页反映 worker 内已加载对象，需要上游 Headroom 提供跨 worker warmup 状态契约。
2. 50+50 验收是脱敏 `/v1/compress` 合同样本；由于当前 Codex++ helper 的认证和真实会话边界，尚未宣称 50+50 自然 SSE 对话完成。
3. DirectML、Windows ML MIGraphX/VitisAI 和 AMD plugin 仍只在隔离实验范围；官方硬件/模型条件不足以进入生产。
4. Gateway `/health` 在 helper 没有原生 `/health` 路由时可能需要约 5-7 秒完成依赖探测；当前启动 gate 有界等待且已通过，但后续可将 helper TCP 探测与 HTTP 健康探测分离以缩短诊断延迟。
5. GitHub 发布尚未完成：本地安全快照已提交为 `17dab5a`，但推送在 94 秒后因本机 DNS/网络无法到达 `github.com` 超时，远端状态保持 UNKNOWN。审计还阻止发布疑似硬编码 API key、验收 trace、JSONL/session evidence、route state、未签名 wrapper 和未覆盖的 extensionless model blobs。`.gitignore/.gitattributes` 已加入防误提交规则，待网络恢复后只能安全发布脱敏文件和经 LFS 核验的模型。
6. P12d 已按授权停止旧 Codex++ Manager/client 及项目 Headroom writers，相关端口当前均无监听；由于 Manager bridge `/user-scripts/delete` 在停止前后均不可达，indicator metadata 未删除，桌面/任务/防火墙切换仍需后续确认。收据见 `evidence/p12d-cutover-receipt.json`。
7. P12f 已再次静默后来出现的旧 runtime（Manager/client、Headroom/Broker）；`18789/18790/57321/57865/57866` 当前无监听且 5 秒无重生，配置哈希停止前后不变。未启动 root-only 入口；收据见 `evidence/p12f-quiescence-receipt.json`。
8. P12g 已完成系统对象切换验证：精确 `Headroom 18787` 防火墙规则已在管理员上下文移除；唯一桌面入口、旧快捷方式和四个 ColdStart 任务均已独立核验。收据见 `evidence/p12g-admin-verify.json`。
9. 2026-08-01 真实启动复核进行了三轮：第一轮 `policy_gateway_ready_timeout`（冷启动 helper 缺失）；第二轮 `readiness_failed`（monitor 预启动 owner 缺失）；第三轮 `manager_process_not_observed`，`runtime/state/startup-result.json` 明确为 `route_keeper_failed/headroom_not_ready`。三轮均已停止精确项目进程并清除运行日志/状态；当前没有生产服务监听，不能报告唯一入口已完成。
10. 第三轮后续所需修复点已定位为 Manager 启动 gate/route keeper 的预启动 pending 契约：root gate 允许 pending 还不够，`codex-manager-bootstrap.vbs` 调用的 `codexpp-startup-gate.ps1` 与 route keeper 仍在 helper 未启动时 fail-closed。按项目规则本轮停止继续改写，待下一轮重新授权/复核。

## 发布边界

GitHub 发布只允许经过脱敏检查、测试和冻结差异后进行；不上传凭据、令牌、会话正文、认证数据库或个人数据。模型二进制如需发布必须使用 Git LFS，并先核对许可和远端容量。当前仓库已本地初始化并配置 `origin`，但远端状态未知；DNS 失败时不得重试推送或改用强制覆盖。

## 2026-08-01 最新复核状态

以下内容覆盖前文同名的历史“未完成”描述；历史失败记录仍保留用于审计。

- 唯一桌面入口已确认：`D:\Desktop\Headroom for Codex++.lnk` -> 项目根 `scripts\Launch-HeadroomForCodexPP.vbs`。启动顺序为 Kompress broker、Headroom、Gateway、monitor、route keeper、Manager、Codex++ client。
- 最新启动收据 `runtime\state\headroom-start-result.json` 为 `succeeded`；route-state 为 `ready`、`route_scope=process`、`config_mutated=false`；Kompress 为 `CPUExecutionProvider/onnx` ready。
- 独立自然流验收 `evidence\final-acceptance-20260801.json` 已完成 `50 main + 50 spawned`：全部 HTTP 200、SSE `response.completed`，504、5xx、静默断流、缺少终态、解码异常、传输中断均为 0；策略为 `main/compress` 与 `spawned/bypass`，误分类为 0。
- P19 修复 route-state 长流新鲜度：route keeper 每 20 秒以内进行带完整身份、配置哈希和路径校验的原子 heartbeat；`evidence\p19-runtime-acceptance.json` 的 4 个运行样本均保持 route green，最大 route age 16.6 秒，配置哈希不变。
- route keeper 重启后的 1+1 SSE smoke 见 `evidence\p19-post-restart-sse-smoke.json`，main/spawned 均 200、`response.completed`、无解码异常。
- `src\headroom\codexpp-headroom\reconcile-codexpp.ps1` 当前为纯只读验证器；最近验证输出 `READ_ONLY=true`、`CONFIG_HASH_UNCHANGED=true`、`COMPATIBLE=true`。
- C 盘 Headroom 专属 `route-warning-ui-v1-20260731` 备份已在树哈希一致后移入项目 `backups\c-drive\...` 并删除原目录，收据为 `evidence\p20-c-drive-headroom-backup-removal.json`。其他 Codex++ 备份、供应商配置、认证、会话和 `D:\gpt-image2` 未触碰。
- 当前自动化验证：Python `30/30`；startup-root、startup-chain、迁移脚本测试均 PASS；PowerShell AST 46 个脚本无语法错误；P19 heartbeat fixture、编码和 `git diff --check` 均 PASS。

### 当前未决项

1. 上游未提供精确 usage token 字段，监控保持 `token-accounting.incomplete` 黄色；这不影响路由、压缩或 SSE 终态。
2. DirectML、MIGraphX、VitisAI/NPU 仍是隔离实验，生产后端保持 CPU ORT；没有通过完整模型、重复运行和长流闸门的加速后端不会被启用。
3. GitHub 推送仍须在网络可达后按脱敏 allowlist、LFS 和远端空仓库状态复核；禁止上传 runtime 私有状态、缓存、日志、备份、模型、凭据或会话正文，禁止强推。

## 2026-08-01 路由实测（Codex）

- 只读核查确认受管 Codex++ 的进程级路由为 `http://127.0.0.1:18787/v1`，`route_scope=process`、`proxy=local-headroom`、`config_mutated=false`；Gateway `18787` 的上游是 Headroom `18789`，Headroom 状态目标为 Relay `57321`。
- 两次最小 Responses 探针均经本地 Gateway 返回 HTTP 200（约 7.7-7.9 秒）；最新一次 Gateway 计数为 `main/compress=1`、`ok=1`，Headroom `/health=200`。这证明探针请求实际经过 Headroom 链，而不只是配置文件指向本地端口。
- `.codex\config.toml` 仍显示 `https://skyapi2026.com`；这是未受管的官方 `codex.exe` 进程所用配置线索。监控对该进程报告 `route.failed`，因为它不在受管 Codex++ 进程树内；不能把当前 Codex 桌面会话当作 Headroom 验收证据。
- 测试期间服务曾短暂重启并回到 `ready`；未修改供应商、Base URL、API key、认证、模型、会话或二进制。

## 2026-07-31 审计复核（Codex）

- 代码级复核通过：Python `27/27`、PowerShell parser `40/40`、startup-chain `PASS`、activation fixture `PASS`；端口 `18787/18788/18789/57321` 当前均可达，route-state 为 `ready/process/config_mutated=false`。
- 不能宣称运行态已完成：当前 Headroom `/health` 的 Kompress 为 `enabled=true/ready=false/unhealthy`，`/debug/warmup` 为 `deferred`，`/stats` 尚无模型请求或压缩样本。
- 发现部署漂移：项目根 `src/headroom/codexpp-headroom/gateway.py` SHA-256 为 `484913DD...`，运行副本 SHA-256 为 `9E07E3C6...`；根版本有 helper fallback 和压缩旁路，运行副本没有，需同步并重启后才能复验 504 防护。
- 桌面两个 Codex++ 快捷方式仍直接指向 EXE，没有指向唯一启动入口；自然 Codex++ SSE `50+50` 和独立验收回执仍缺失。
- 本地 Git 当前为 `a6c29a6` 且工作树有未提交/未跟踪文件；GitHub 推送远端状态仍为 `UNKNOWN`。本次审计未停止服务、未清理日志、未修改供应商配置、未触碰 `D:\gpt-image2`。

## 2026-08-01 Public Release Snapshot

- This tree contains sanitized source, tests, rules, documentation, and model metadata only.
- Production compression remains CPU ONNX Runtime `1.28.0`; DirectML, MIGraphX, VitisAI, and NPU experiments remain isolated and are not enabled by this release.
- Runtime state, caches, logs, backups, model binaries, credentials, authentication databases, and session content are excluded by the release allowlist.
