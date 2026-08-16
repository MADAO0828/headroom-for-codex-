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

## Codex++ + Headroom 技术路线图

本节是本项目关于**功能实现链路、启动链路和生效链路**的权威入口。后文按日期保留的记录属于历史审计；与本节冲突时，以本节的“当前/目标/未验证”状态标记为准。

### 状态标记

| 标记 | 含义 |
| --- | --- |
| `CURRENT` | 已有源码、脚本或运行收据支持的当前能力 |
| `TARGET / Route C` | 已冻结的目标架构，尚未完成源码实施和真实运行验收 |
| `NOT_PROVEN` | 配置、监听或 UI 存在，但缺少官方窗口真实请求的完整关联证据 |

截至 `2026-08-02`，Codex++ 管理弹窗、renderer 用户脚本、Headroom 指示器、Gateway/Headroom/Kompress sidecars 和受管 helper 均已有实现；但当前官方 ChatGPT/Codex 窗口仍未被证明经过 Headroom，`official_dataplane=bypass/not_proven`。Route C 的核心是保留现有官方窗口和全部 UI 注入，由 **Codex++ native supervisor** 成为请求入口、Headroom sidecars 和上游出口的唯一生命周期所有者。

### 组件职责

| 组件 | 端口/接口 | 当前职责 | Route C 目标职责 |
| --- | --- | --- | --- |
| Codex++ Manager | `57865` | 供应商选择、管理 UI、启动/重启入口 | 保持供应商权威和 UI，不直接执行压缩 |
| Codex++ renderer 注入 | CDP/typed bridge | 管理弹窗、用户脚本、Headroom 指示器和 popup | 原样保留，只承担展示和窄控制面 |
| Codex++ ingress helper | `57321` | 受管 Codex++ 协议代理入口；当前可直达所选上游 | 官方窗口的唯一请求入口，转交 Gateway，不再直接绕过 Headroom |
| Policy Gateway | `18787` | metadata 分类、header 剥离、关联 ID、故障合同 | 继续执行 `main/compress`、`spawned/bypass` 路由和安全 fail-open |
| Headroom proxy | `18789` | 缓存、策略、压缩编排、SSE 透传 | 继续处理压缩和旁路，不保存供应商凭据 |
| Kompress broker | `18790` | 独立队列、ONNX 推理、CPU fallback | 保持隔离 worker；GPU/NPU 仍需单独通过实验闸门 |
| Codex++ egress relay | `57322` | `CURRENT` 不存在 | `TARGET`：读取 SettingsStore 当前上游并完成真实外发，打断 `57321` 自循环 |
| Headroom monitor | `18788` | 汇总服务、路由、错误和 token 状态 | 以官方 PID 和全链 correlation 为唯一数据面确认依据 |
| SettingsStore | 本地受保护存储 | 保存 Codex++ 当前供应商 URL/Key/协议选择 | 仍是唯一供应商权威；Headroom 不复制、不改写这些值 |

### 1. 功能实现链路

```mermaid
flowchart LR
    User["用户操作官方 ChatGPT/Codex 窗口"] --> Renderer["Codex++ renderer 注入"]
    Renderer --> UI["管理弹窗 / 用户脚本 / Headroom 指示器"]
    UI --> Bridge["白名单 typed bridge"]
    Bridge --> Native["Codex++ Rust/Tauri native backend"]
    Native --> Store["SettingsStore 供应商权威"]
    Native -. "TARGET: 生命周期与状态命令" .-> Supervisor["Headroom native supervisor / lease"]
    Supervisor -.-> Gateway["Gateway 18787"]
    Supervisor -.-> Headroom["Headroom 18789"]
    Supervisor -.-> Broker["Kompress broker 18790"]
    Supervisor -.-> Monitor["Monitor 18788"]
```

功能边界：

1. renderer 负责 UI，不拥有 `codex.exe/app-server`、helper、端口或 provider 生命周期。
2. Codex++ native backend 负责官方窗口启动/注入、SettingsStore 和受管进程。
3. Gateway 负责分类和安全合同；Headroom 负责压缩策略；broker 负责模型推理。
4. Route C 新增的 supervisor/lease 只管理本项目进程、端口和 generation，不得修改供应商定义、Base URL、Key、认证、模型或会话。

### 2. 启动链路

#### 当前受管启动链 `CURRENT`

```mermaid
flowchart TD
    Shortcut["桌面 Headroom for Codex++.lnk"] --> VBS["Launch-HeadroomForCodexPP.vbs"]
    VBS --> Progress["Start-HeadroomWithProgress.ps1"]
    Progress --> Root["Start-HeadroomForCodexPP.ps1"]
    Root --> Broker["Kompress broker 18790"]
    Broker --> Headroom["Headroom 18789"]
    Headroom --> Gateway["Gateway 18787"]
    Gateway --> Monitor["Monitor 18788"]
    Monitor --> Keeper["route keeper / startup gate"]
    Keeper --> Manager["Codex++ Manager 57865"]
    Manager --> Client["Codex++ Client / helper 57321"]
    Client -. "由 Codex++ 生命周期决定；需运行态复核" .-> Official["官方 ChatGPT/Codex + renderer 注入"]
```

这条链只证明受管服务和 Codex++ 控制面可以启动。只有官方窗口 PID、Gateway 增量、Headroom/egress 关联和 SSE 终态能够对应同一请求时，才能证明 Headroom 对官方窗口真正生效。

#### Route C 目标启动链 `TARGET / NOT_EXECUTED`

```mermaid
flowchart TD
    Entry["唯一桌面入口"] --> Native["Codex++ native launcher / supervisor"]
    Native --> Lease["创建 owner PID + start time + generation + heartbeat lease"]
    Lease --> Egress["启动内部 egress relay 57322"]
    Egress --> Broker["启动并预热 Kompress broker 18790"]
    Broker --> Headroom["启动 Headroom 18789"]
    Headroom --> Gateway["启动 Gateway 18787"]
    Gateway --> Ingress["启动 ingress helper 57321"]
    Ingress --> Monitor["启动 Monitor 18788"]
    Monitor --> Canary["执行健康、loop、防泄漏和最小 canary"]
    Canary --> Official["激活唯一官方窗口"]
    Official --> Inject["加载现有 Codex++ UI 和 Headroom 指示器"]
    Inject --> Ready["发布 ready；允许用户发送请求"]
```

启动门禁必须同时检查：单一 owner/lease、PID/路径/启动时间、端口、`/livez`、`/health`、真实 egress 非本地上游、配置受保护契约、UI 注入和最小 SSE canary。任一步失败都不得启动第二个 owner，也不得把客户端放行到可能返回 504 的半启动链。

### 3. 生效链路

#### Route C 请求链 `TARGET / NOT_EXECUTED`

```mermaid
flowchart LR
    Official["官方 codex.exe/app-server"] --> Ingress["Codex++ ingress 57321"]
    Ingress --> Gateway["Gateway 18787"]
    Gateway --> Classify{"请求分类"}
    Classify -->|"main"| Headroom["Headroom 18789"]
    Classify -->|"spawned"| Bypass["保持原请求 / bypass"]
    Headroom --> Broker["Kompress broker 18790"]
    Broker -->|"压缩成功"| Egress["Codex++ egress 57322"]
    Broker -->|"超时/异常"| FailOpen["原文 fail-open"]
    Bypass --> Egress
    FailOpen --> Egress
    Egress --> Store["读取 SettingsStore 当前供应商"]
    Store --> Upstream["真实上游 API"]
    Upstream --> SSE["原始 SSE 字节反向透传"]
    SSE --> Official
```

生效规则：

- `main`：Gateway 进入 Headroom；可压缩时调用 broker，不可压缩或任何异常时使用原请求继续外发。
- `spawned`：只有结构化 metadata 同时满足真实 thread spawn 和 parent thread 条件时 bypass；损坏、冲突或证据不足时按 main 处理。
- egress `57322`：只绑定 loopback，要求当前 generation capability，拒绝 `18787/18789/57321/57322` 等本地上游，并在外发前剥离内部路由、调试和 capability header。
- SSE：响应按原始字节返回；上游 EOF 缺少标准终态时补发一次 `response.failed`，不得静默断流或盲目重放非幂等请求。
- 供应商切换：`Manager UI -> native bridge -> SettingsStore`；下一条 egress 请求读取最新选择。Headroom 不改 `config.toml`，也不把 `18787` 回填到供应商页面。

#### 监控与“已生效”判据

```mermaid
flowchart LR
    PID["官方窗口 PID/TCP"] --> Correlation["57321/Gateway/Headroom/57322 correlation"]
    Correlation --> Terminal["response.completed 或标准 response.failed"]
    Terminal --> Snapshot["Monitor 18788 统一快照"]
    Snapshot --> Indicator["官方窗口 Headroom 指示器 / popup"]
```

只有以下证据在同一时间窗口和 generation 内全部成立，才能将 `official_dataplane` 标记为 `confirmed`：

1. 官方 `codex.exe/ChatGPT` 网络进程连接 `57321`；
2. `57321 -> 18787 -> 18789 -> 57322` 有可关联的 request/correlation 记录；
3. egress 连接 SettingsStore 当前选中的真实非本地上游；
4. 每条 SSE 都有标准终态；
5. main/spawned 分类与压缩/旁路计数一致；
6. Manager 重启或供应商切换没有停止有效 owner，也没有修改受保护配置。

仅有端口监听、健康页绿色、route-state、配置指向本地或 renderer 指示器存在，都不足以证明官方窗口已经使用 Headroom。

### 路线落地阶段

| 阶段 | 交付 | 当前状态 |
| --- | --- | --- |
| R0 | 保留现有 UI 注入、Gateway/Headroom/broker/monitor 和受管启动资料 | `CURRENT` |
| R1 | 隔离实现 native supervisor/lease 与 egress `57322`，使用假上游验证 | `NOT_EXECUTED` |
| R2 | 单一官方窗口、单 generation、单 SSE canary，证明全链 correlation | `NOT_EXECUTED` |
| R3 | 50 main + 50 spawned、供应商切换、崩溃/超时/重启验收 | `NOT_EXECUTED` |
| R4 | 通过完整模型闸门后评估 GPU/NPU provider；CPU 始终作为热备 | `EXPERIMENTAL` |

## 唯一启动方法

日常使用直接双击桌面入口：

`D:\Desktop\Headroom for Codex++.lnk`

该快捷方式会以管理员权限调用项目根目录的 `scripts\Launch-HeadroomForCodexPP.vbs`，再按固定顺序启动 Kompress broker、Headroom、Gateway、monitor、route keeper、Codex++ Manager 和 Codex++ Client。退出 Codex/Codex++ 后不需要先打开管理工具，也不要再点击旧的直启快捷方式。

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
- P15/v2/v3 的早期三轮真实启动失败记录仍保留用于审计；P26 修复后，真实唯一桌面入口已通过冷启动和重复点击验收，详见下方最新复核。
- 项目根目录保留源码、脚本、缓存和完整 Kompress 模型 blob；运行日志/计数按验收要求清零，受保护会话、凭据、认证数据库和完整会话正文仍留在原位置，不能复制或上传。
- 官方 Codex++ `v1.2.44` 源码现已由用户提供的 `D:\下载\CodexPlusPlus-1.2.44.zip` 恢复到 `runtime\src\CodexPlusPlus-v1.2.44`；281/281 路径与 commit `77091ccaee4423f35a1b2c51c4ecd703e6201092` 的 Git blob 一致，工作树 clean，并由未参与施工的验收员独立复核通过。旧 partial 目录已备份到 `backups\source-recovery-20260802-zip-promotion`。这只完成源码前置，不代表 Route C 已构建或生产生效。

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
11. Route C 的 v1.2.44 完整源码前置、独立验收和隔离 Node 22/Rust stable MSVC 工具链已完成；native supervisor/lease/57322 施工、Canary 构建和官方窗口真实验收仍未完成；不得把当前 source/toolchain preparation 写成生产集成。

## P57 Route C 交接状态（2026-08-03）

- P47 的官方 v1.2.44 源码和 P46 隔离工具链收据已完成；P48 仅是非 native、非生产 Python PoC。
- P50/P51/P52 的 native Route C 源码存在，但完整 Cargo 矩阵、可运行 Canary 和真实官方窗口验收仍未完成。
- Reasonix 的 P57 worker 曾在共享树留下 launcher 参数/生命周期改动和 egress `/health`、`/livez` 提前探测改动；由于没有返回可读测试/构建/Canary 收据，P57 当前为 `UNKNOWN`，不能报告 native Route C 已交付。
- 当前生产 Route C 继续 `off`；生产端口、供应商配置、Vortex、官方窗口和 `D:\gpt-image2` 未被本轮改变。证据：`evidence/reasonix-route-c-closeout-20260803.json`。
- 仍须由 Reasonix/用户手动完成：隔离构建与假上游回归、Canary 1+1→10+10→50+50、官方窗口退出/激活、UI/indicator、供应商切换、回滚、注销/登录和 24 小时自然样本。

## 2026-08-03 独立复核结果（Codex）

- Reasonix 的 native Route C Canary 传输链可独立复现：隔离 `58321 -> 18887 -> 18889 -> 58322 -> 18891` 返回 HTTP 200 和 `response.completed`，Gateway 分类为 `main/compress` 与 `spawned/bypass`，端口在清理后释放。
- 但这不等于压缩执行。对额外 160049 字节 synthetic main 请求的复核显示 Headroom `requests_compressed=0`、`tokens_saved=0`、最近请求 `memory_skip_reason=no_handler`，Kompress broker `total=0/compressed=0`。当前只证明策略分类和转发，不证明 ONNX/Kompress 实际参与。
- 构建可重复性也未闭环：旧 target 的 `cargo check` 报 `E0463`（找不到 `tokio_tungstenite`/`reqwest`）；全新 target 的 `cargo check` 又触发 Rust 编译进程 `0xc0000409 / STATUS_STACK_BUFFER_OVERRUN`。现有 `current` exe 可以运行 Canary，但不能替代干净源码构建收据。
- 因此 P57 只能标记为“隔离传输部分通过、压缩门禁和可重复构建未完成”；生产 Route C 继续 `off`，官方窗口真实接入、1+1→10+10→50+50、UI/indicator、回滚和 24 小时样本仍未验收。证据：`evidence/route-c-independent-audit-20260803.json`。

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

## 2026-08-01 续作复核

- 当前生产链仍由项目根目录托管：Gateway `18787`、Monitor `18788`、Headroom `18789`、Kompress broker `18790`、Relay `57321`、Manager `57865`、Client `57866` 均在监听；`/livez`、`/health`、`/status` 均返回成功。
- route-state 当前为 `ready`、`route_scope=process`、`config_mutated=false`；Kompress 为 `CPUExecutionProvider/onnx/ready`。本轮未修改 Codex++ 供应商配置、Base URL、认证、模型或会话。
- 复核测试：Python `30/30 PASS`；startup-root、startup-chain、迁移脚本 `PASS`；PowerShell AST `46` 个脚本 `0` 个解析错误。
- 脱敏发布工作树与主分支共有文件哈希一致，工作树干净；GitHub 普通推送因未登录且 `github.com:443` 连接失败而保持 `UNKNOWN`，详见 `evidence/github-publish-20260801.json`。没有强推、覆盖远端或记录凭据。

## 2026-08-01 GitHub 发布完成

- GitHub 认证已由 `gh auth status` 验证成功。
- Git HTTPS 传输仍在 `github.com:443` 连接阶段失败，因此使用 GitHub Git Data API 完成等价发布；没有强推或覆盖已有引用。
- `refs/heads/main` 当前发布提交为 `8a16f88a8aa2073d4f4ac15ecadd5e4738967daf`，远端 tree 为 `b21b913dd817fb33a806765b0189260f46d58f55`。
- 远端 62 个 blob 与本地脱敏发布索引逐项一致：缺失 `0`、多余 `0`、哈希不一致 `0`、敏感路径 `0`。详见 `evidence/github-api-publish-20260801.json`。

作者：Codex。

## 2026-08-04 生产上线收口 C0-C4（Codex）

本轮只完成项目内源码、隔离运行时和候选门禁，未停止或重启 Codex++、Manager、Client 或官方窗口；生产 Route C 仍为 `OFF/NO-GO`。

- Responses `input_text`：最新用户文本进入压缩；历史用户文本只有在此前作为 live tail 已产生并通过校验的缓存结果时才复用，缓存未命中保持原始前缀字节；顶层字符串 `input` 保持字符串 wire shape。
- 压缩失败策略：Responses HTTP/WS 的超时、provider、解码和 malformed output 均 fail-open，继续发送原始 body/frame，不再由压缩层主动返回 413 或关闭 WebSocket。
- correlation：Gateway 传入的 opaque `request_id/correlation_id` 可传至 broker；broker 响应和 bounded body-free receipt 保留同一 ID，不记录请求正文。
- 工具门禁：安装脚本和候选 manifest 排除 `__pycache__`/`.pyc`，并排除候选 manifest 自身，避免清理缓存后产生假 drift。
- 验证：Python tests `33/33`、Gateway contract `30/30`、PowerShell candidate/aggregate/migration/user-script/visible-launcher 全部 PASS；隔离 runtime 为 Python `3.14.5`、Headroom `0.32.1`、ONNX Runtime `1.28.0`。
- 候选：source/release manifest 均通过 validator；具体 candidate ID、entry count 和 SHA-256 集中记录在 `evidence/prod-closure-c0-c4-20260804.json`，避免 README 形成 manifest 自引用漂移。
- 独立验收：首轮因 `WORK.md` 在冻结后漂移而失败，第二轮发现 C0 receipt 中一个源码文件哈希过期；两轮均保留失败收据并按 correction packet 修复。`evidence/prod-closure-c0-c4-independent-acceptance-correction2-20260804.json` 已 `status=SUCCEEDED`，确认候选与收据一致，但只代表项目内/隔离候选通过，不代表生产 ready。
- 最终候选复核：正式验收员在最终收据落盘前连续两次发生 `transport_unknown`；已登记 `sol_takeover`，由主负责人执行同范围的非独立只读核验并记录 `evidence/prod-closure-c0-c4-independent-acceptance-final-20260804.json`。这不改变生产 `Route C=OFF/NO-GO`。

仍未完成的生产项：真实 ready 链、native Route C 可重复 Canary、官方窗口全链 correlation、`1+1 -> 10+10 -> 50+50` SSE、供应商切换/重启/回滚、提升上下文 launcher 测试、独立验收和 GitHub 发布。上述事项必须由用户手动激活窗口并由 Reasonix 执行，不得用本节隔离结果替代。

作者：Codex，2026-08-04。

## 2026-08-04 生产上线制约与收口计划（Codex）

当前生产上线仍受四类硬门禁限制：官方窗口尚未证明进入 Headroom；生产 Headroom/Gateway/Monitor/Broker ready 链当前不完整；native Route C 尚未形成可回滚的生产 candidate；真实官方 50+50 SSE、故障注入、供应商切换和最终验收尚未执行。另有功能风险：普通 Responses `input_text` 目前不会压缩；broker correlation、冷启动/复用稳定性和完整 workspace 提权测试仍需收口。GPU/NPU 属于性能候选，不阻塞 CPU ORT 基线。

分阶段计划已保存至 `docs/PRODUCTION-READINESS-CLOSURE-PLAN-20260804.md`，阶段门禁为：G0 基线冻结、G1 启动监控、G2 native candidate、G3 官方数据面、G4 压缩语义与性能、G5 最终验收发布。未满足 G5 前不得报告生产上线。

作者：Codex。

## 2026-08-04 Route C 返工独立复核（Codex）

本节是对 Reasonix 2026-08-03 返工声明的独立复核；旧段落保留为历史记录，但与本节冲突时以本节和 `evidence/route-c-rework-independent-audit-20260804.json` 为准。

### 已确认

- 全新隔离 Canary `runtime/canary/route-c/20260804-005510572` 通过：`58321 -> 18887 -> 18889 -> 58322 -> 18891`，`response.completed` 正常，假上游收到 3 个请求，Gateway 为 `main/compress=2`、`spawned/bypass=1`。
- 本次 Canary 未复用历史 broker。broker PID `63356` 在请求前后保持一致，计数从 `total=0/compressed=0` 增加到 `total=1/compressed=1`，因此本次 Kompress CPU ORT 执行有隔离证据。
- 在 `runtime/canary/route-c/independent-audit-20260804-core-target` 上，`cargo check --workspace`、`cargo build --workspace`、`cargo clippy --workspace --all-targets -- -D warnings` 和 `codex-plus-core`/`codex-plus-data` 测试均通过；Manager 已包含在 workspace check/build/clippy 中，未复现“Manager 因旧依赖无法编译”。
- Responses 当前只把 `custom_tool_call_output`、`function_call_output`、`local_shell_call_output`、`apply_patch_call_output` 作为压缩候选；普通 `message/input_text` 保留在缓存前缀。因此 `main -> compress` 是策略分类，不等于普通用户输入必然被压缩。

### 仍未通过

- 生产 Route C 继续 `off/NO-GO`：当前生产 `18787/18788/18789/18790` 不构成可验证的运行链，`18788` 不可达，旧 route-state/starter receipt stale/failed；官方 `codex.exe` 仍观察到 Vortex `7897` 路径，没有同一请求的 `57321 -> 18787 -> 18789 -> upstream` correlation。
- 完整 workspace 测试的唯一失败是 launcher 测试二进制受 `requireAdministrator` 清单阻止启动（Windows `os error 740`）；已执行的测试均通过，需在提升上下文重跑该 GUI/管理员测试。
- 官方窗口真实 SSE、1+1 -> 10+10 -> 50+50、UI/indicator、供应商切换、回滚、注销/登录、24 小时自然样本仍未验收。
- WebGPU/NPU/DirectML/MIGraphX 仍为 lab-only；本机没有启动真实硬件 session，生产后端仍为 CPU ORT。

### 本轮修正

`scripts/Start-RouteCCanary.ps1` 已把压缩门从累计 `compressed >= 1` 改为请求前后 broker counter delta，并写入 broker PID、路径、启动时间和命令行哈希；PID 在请求期间变化或 `compressed` 增量为零都会失败。脚本解析、dry-run、startup-root fixture 和全新 Canary 均通过。完整脱敏收据见 `evidence/route-c-rework-independent-audit-20260804.json`。

作者：Codex。

## 2026-08-02 可见启动反馈（Codex）

- 桌面入口仍是 `D:\Desktop\Headroom for Codex++.lnk`，但 VBS 现在调用 `scripts\Start-HeadroomWithProgress.ps1`。该包装器只负责可见反馈，实际 Headroom/Gateway/Manager/Client 启动仍由 `Start-HeadroomForCodexPP.ps1` 完成，子进程保持隐藏。
- 启动窗口按 Kompress `18790`、Headroom `18789`、Gateway `18787`、Monitor `18788`、route-state、Relay/Manager/Client 和最终收据显示 ASCII 进度条；成功显示收据后自动关闭，失败或总超时保留窗口并显示 `status/stage/error_code/detail`、收据和诊断日志路径。
- 包装器以本轮启动前的 `headroom-start-result.json` 哈希和修改时间为基准，不能把上一轮成功/失败收据误报为本轮结果。route-state 只用于阶段提示，最终成功必须同时满足本轮启动子进程退出码为 0 和新的成功收据。
- `Set-HeadroomDesktopEntry.ps1` 现把 `.lnk` 的 `SLDF_RUNAS_USER (0x1000)` 纳入配置校验；已修复当前桌面快捷方式实际缺少该标志的问题。实测 `LinkFlags=0x000010F7`、`run_as=True`，未删除旧快捷方式、未改 Codex++ 配置。
- 已通过 `Test-HeadroomVisibleLauncher.ps1`（成功/失败/旧收据夹具）、`Test-HeadroomMigrationScripts.ps1`、`startup-root.tests.ps1`、`codexpp-startup-chain.tests.ps1` 和 `git diff --check`。尚未由 Agent 自动执行完整桌面启动，需用户手动双击确认真实 UAC/窗口行为。

作者：Codex。

## 2026-08-02 用户实测启动失败复核（Codex）

### 桌面 Headroom 入口

- 截图中的 `The property 'status' cannot be found on this object` 已由源码和运行态共同证实：`scripts\Start-HeadroomWithProgress.ps1` 的 `Test-RouteStateReady` 直接读取 `$watch.status`，但实际 `runtime\state\codexpp-route-watch.json` 是 `schema_version=2`，没有 `status` 字段，且脚本启用了 `Set-StrictMode -Version Latest`。因此可见父包装器在轮询阶段提前异常，尚未来得及读取本轮终态收据。
- 这不是唯一故障。父窗口退出后，隐藏的原启动子进程仍可能继续；其随后生成的最新收据是 `headroom_start_failed / manager_readiness_failed:3`，`startup-result.json` 是 `readiness_failed`。所以本次桌面失败应分成“包装器探针异常”与“子启动链 Manager readiness 失败”两层，不能把截图异常误判为 Manager 根因。
- 证据：`evidence\launcher-failure-analysis-20260802.json`。本轮分析未停止/启动进程，也未修改 Codex++ 配置、供应商、认证、Vortex 或模型。

### OfficialCodexThroughHeadroom 入口

- `scripts\Launch-OfficialCodexThroughHeadroom.vbs` 只执行异步 `shell.Run "pwsh.exe ...", 1, False`，随后立即退出；没有 `runas`、绝对 PowerShell 路径、退出码处理或失败 MsgBox。PowerShell 脚本在 readiness 等待期间没有进度输出，失败时只把错误写入收据并 `exit 2`，所以用户看到的是空白控制台后自动关闭。
- 最新可关联收据 `runtime\state\official-route-a-start.json`（`2026-08-02T09:39:41.8843657Z`）为 `status=not_proven`、`error_code=route_a_services_not_ready`：Gateway/Headroom 当时 HTTP 200，但 `57321` Relay PID 为空。脚本在 readiness 门禁处退出，尚未执行 `ProcessStartInfo` 启动官方 ChatGPT/Codex，因此这次点击没有产生官方数据面接入。
- 之后端口重新出现监听，不能倒推之前那次点击已成功；必须按同一点击窗口重新生成收据并验证官方 PID 到 `18787`、Gateway correlation、Headroom/Relay 上游和 SSE 终态。

### 待修复边界

1. `Test-RouteStateReady` 改为按 route-watch 实际 schema 做空值安全校验；进度探针异常不得提前放弃子进程收据 reconciliation。
2. Official route 入口增加可见阶段、失败摘要和收据路径；失败仍保持 readiness/loopback/protected-hash 门禁，不绕过安全检查。
3. 在以上修复和用户重新激活前，不报告桌面入口或官方路由入口成功。

作者：Codex。

## 2026-08-02 官方窗口临时路由可行性（Codex）

- 用户提出的“保留 Codex++ 供应商 URL/Key，官方窗口运行期间临时指向 Headroom，退出后恢复”结论为：**满足条件后可行**。但不能在客户端刚启动后立即恢复 `config.toml`；官方 Codex 已有线程通常保留启动配置，新线程或显式 reload 可能重新读取已恢复文件，导致同一进程内路由分裂。
- Codex++ 的供应商权威数据在 `.codex-session-delete/settings.json`；Relay `57321` 按该 SettingsStore 选择真实外部 URL/Key，不依赖官方 live `config.toml`。因此可以让 official Codex 指向 `18787`，同时保持截图中的真实上游资料作为 Relay 数据源。
- 直接临时改 live 配置仍有 UI 污染风险：活动供应商编辑页会读取 live `config.toml/auth.json`，供应商切换前还会把 live 文件回填到旧 profile。要保证截图里的 URL/Key 始终不变，必须增加 route-lease guard：路由期间编辑页显示 SettingsStore，切换时禁止回填临时 runtime provider。
- 推荐顺序：先隔离验证官方 `-c/--config` 注入；若桌面 AppX 无法可靠注入，再实施“整个应用生命周期保持临时 live 路由”的事务方案。退出恢复最新选中供应商投影，不恢复启动时的旧供应商。
- 自循环门禁必须覆盖当前选中和全部 fallback 上游，拒绝任何目标解析到 `127.0.0.1/localhost/::1` 的 `18787/18789/57321`。
- 脱敏可行性收据：`evidence/p38-transactional-official-route-feasibility-20260802.json`。本轮未修改配置、进程、供应商、凭据、Vortex 或系统代理。

作者：Codex。

## 2026-08-02 最新官方数据面快照（Codex）

只读采样时间 `2026-08-02T05:40:36.3135903Z`：官方 `codex.exe` PID `48200` 和 ChatGPT 网络子进程 PID `40428` 均连接 Vortex `127.0.0.1:7897`；官方 PID 没有到 `18787/18789/57321` 的已建立连接。受管 Gateway/Headroom/Relay 仍分别监听 `18787/18789/57321`，但监听存在不等于官方窗口使用它们。

因此当前官方数据面仍判定为 `bypass`，不是 `confirmed`。最新收据：`evidence/current-window-route-audit-20260802-live2.json`。本次未发送模型请求、未停止/启动进程、未修改配置或 Vortex。

作者：Codex。

## 2026-08-02 历史路由与故障分层复核（Codex）

- 近一周旧交接和备份源码确认：此前确实有过“官方 Codex -> Gateway 18787 -> Headroom 18789 -> helper 57321”的真实链路窗口，但实现依赖改写官方 `.codex/config.toml` 的活动 `base_url`、设置 `supports_websockets=false`，并尝试让 AppX 继承 `CODEX_HOME`。旧 route keeper 还包含配置备份、`File.Replace` 和 `base_url` 行构造。该机制解释了历史上为什么可能接入成功，同时也明确违反当前配置只读铁律，不能恢复到生产。
- 502/504 已分层：2026-07-30 在 `--no-optimize/--disable-kompress` 完全转发窗口中仍有 16 个 502，但没有压缩超时、504 或 `stream disconnected`，并伴随外部 EOF/`context deadline exceeded` 证据；这批错误不能归因于压缩。2026-07-28 的另一批错误来自外部上游；把 `18787` 写进上游后形成 `57321 -> 18787 -> 18789 -> 57321` 自循环，属于确定性拓扑错误。另有隔离压缩压力样本复现 36 个 504，说明 Kompress 容量保护需要保留，但它不是上述历史 502 的统一根因。
- 历史运行记录在 2026-07-30 09:43:29（+08:00）明确显示 Headroom 命令含 `--no-optimize --disable-kompress`；该记录只作为运行参数证据保留，原始会话正文没有复制到项目。
- 当前官方桌面窗口仍以 Vortex `127.0.0.1:7897` 为实时数据面；`evidence/current-window-route-audit-20260802.json` 没有观察到官方 PID 同窗连接 `18787/18789/57321`。因此当前监控的 `route=green` 只表示受管 Codex++ 控制面，`official_dataplane=bypass` 才是当前窗口结论。
- P34a/P34b 已把 Gateway 请求关联和 `official_dataplane` 证据模型补上：只有官方 PID 到 `18787`、Gateway 同窗增量、关联 ID 和上游证据同时存在，才会标记 `confirmed`；测试分别为 Gateway 30/30、官方数据面夹具 18 assertions。
- 完整审计收据：`evidence/historical-route-audit-20260802.json`。在用户明确授权官方 wrapper/environment、Vortex/系统代理或官方 endpoint 机制前，不修改官方配置、不改 Vortex、不重启生产进程，也不报告当前官方窗口已接入 Headroom。

作者：Codex。

## 2026-08-02 当前官方桌面窗口路由复核（Codex）

- 独立只读采样确认：官方 WindowsApps `ChatGPT.exe` 根进程 PID `49876` 的网络子进程 PID `40428` 有已建立连接到 `127.0.0.1:7897`；`7897` 由 `C:\Users\ma dao\.config\com.vortex.helper\com.vortex.helper.exe` PID `18272` 监听。官方 `codex.exe` PID `48200` 与插件 appserver `codex.exe` PID `36608` 在采样时均没有到 `18787`、`18789` 或 `57321` 的连接。
- 受管链 `18787/18788/18789/18790/57321/57865/57866` 均在监听，`codexpp-route-state.json` 为 `ready/process/local-headroom/config_mutated=false`。这只证明 Codex++ Manager/Client 的控制面和进程级路由，不证明当前官方桌面窗口的数据面。
- 桌面快捷方式实际调用 `wscript.exe -> scripts\\Launch-HeadroomForCodexPP.vbs --phase-b`；源码只启动项目 Headroom/Gateway/monitor/route keeper 及 `D:\program\Codex++` Manager/Client，没有启动或注入官方 WindowsApps `ChatGPT.exe`/`codex.exe` 的代码路径。
- 进程树也没有把当前官方窗口纳入受管树：`ChatGPT.exe` 根 PID `49876` 的父 PID 为 `3192`，官方 `codex.exe` PID `48200` 的父 PID 为 `49876`；受管 Manager/Client 是另一组 PID `50104/51100`。
- 因此撤回此前 P28 中“聚合供应商已使当前官方 Codex 窗口无论切换供应商都经 Headroom”的运行态结论。P28 只能证明受管 Codex++ relay/aggregate 的配置和健康收据；当前官方窗口仍是 `Vortex 7897` 路径，Headroom 接入为 `NOT_PROVEN`。
- 配置域也不同：P28 操作的是 Codex++ 的 `C:\Users\ma dao\.codex-session-delete\settings.json` / `C:\Users\ma dao\.codex-plus-plus-cli\config.toml`；当前官方桌面进程使用 `C:\Users\ma dao\.codex\config.toml`。即使两个文件出现相同的 `57321` 字符串，也不能证明官方 ChatGPT 网络服务采用了 Codex++ 的进程级覆盖。
- 监视器 `route=green` 与 `Codex 连接=green` 的语义必须收窄：前者是受管 Codex++ 路由，后者是活动进程计数；两者都不能代表本窗口真实模型请求。`transport.helper_5xx=1` 和 `token-accounting missing=370` 也只能作为历史/窗口证据，不能归因到本窗口。
- 脱敏审计收据：`evidence/current-window-route-audit-20260802.json`。本轮未重启、未发模型请求、未修改配置/Vortex/系统代理、未读取会话正文或凭据，未触碰 `D:\gpt-image2`。

### 当前未决

1. 若目标是让官方 Codex 桌面窗口进入 Headroom，必须在真实当前窗口请求上同时看到官方进程/网络服务到 `18787`（或可审计的官方进程级 wrapper 证据）以及 Gateway/Headroom 计数增量；受管 Codex++ 的 synthetic probe 不能替代。
2. 在不修改供应商配置、Vortex 或系统代理的约束下，当前没有已验证的官方桌面接入通道。可行方案需要用户明确授权其一：启动时环境/wrapper 注入、Vortex 规则改造、系统代理改造，或官方应用支持的 endpoint/proxy 机制；本项目不会静默选择高风险路径。

作者：Codex。

## 2026-08-01 PHASE-A 收口（Codex）

### 已完成

- `P30a` 已完成受保护路由契约：Manager 普通元数据变化不再误报；`provider`、`base_url`、`wire_api`、认证字段存在性仍 fail-closed；route-state 普通哈希可由 watcher 原子刷新。
- `P30b` 已完成聚合配置的安全 dry-run：精确识别 `relay-aggregate-headroom` 的 1 个 profile 和 1 个 entry，保留 6 个原供应商及当前非聚合激活项；live `settings.json` 哈希保持 `B8C69AAA...C4F9C4`，没有写入。
- `P30c` 已完成 monitor pending 证据修正、指示器只读预检和幂等注册夹具；源码与运行脚本哈希一致，`18788/status` 返回 HTTP 200，CDP `127.0.0.1:9229` 当前不可达，所以按钮、renderer 和 popup 尚未验收。
- 桌面入口和登录自启继续调用同一个 `Launch-HeadroomForCodexPP.vbs`。桌面快捷方式携带 `--phase-b`，启动文件夹快捷方式不携带该参数；下一次用户手动桌面启动才会执行 PHASE-B 配置清理与指示器同步。

### 阶段状态

- `PHASE-A=SUCCEEDED`：代码、隔离 fixture、只读 live dry-run 和文档收据已完成。
- `PHASE-B=WAITING_USER_ACTIVATION`：Agent 不会停止或重启当前进程。用户需退出 Codex/Codex++ Manager/Client，确认受管 PID 已退出，再双击 `D:\Desktop\Headroom for Codex++.lnk`。
- `PHASE-C=PENDING`：等待用户返回后验证七端口、managed state、route watcher、CDP 指示器和真实 `50 main + 50 spawned` 流量。

### 验证边界

本阶段未修改 `config.toml`、供应商定义、Base URL、认证、模型、会话或二进制，未触碰 `D:\gpt-image2`，未改变生产进程生命周期。主机 `Get-Date -AsUTC` 曾报告 `2026-08-02Z`，晚于本任务日 `2026-08-01`；因此收据不把主机时间戳当作当前日期或时序证明。总收据见 `evidence\phase-a-summary-20260801.json`。

作者：Codex。

## 2026-08-01 运行态路由与指示器复核

本节是对现场截图（约 2026-08-01 12:44）及随后实时状态采样的最新记录；它覆盖“启动成功但监视器红色、顶栏无指示器”的现象，历史启动验收记录仍保留用于审计。

### 已确认事实

- Gateway `18787`、Headroom `18789`、Kompress broker `18790` 的 `/livez`、`/health`/`/readyz` 均正常；`codexpp-route-state.json` 为 `status=ready`、`route_scope=process`、`config_mutated=false`，受管路由为 `http://127.0.0.1:18787/v1`。因此本次红色状态不是 Headroom/Gateway 未监听或 `reconcile-codexpp.ps1` 改写配置造成的。
- `runtime/state/managed-codex-processes.json` 的采样时间为 `2026-08-01 12:38:27Z`，仍登记 Manager PID `22764`、Client PID `23592`；实时进程为 Manager PID `18408`（`D:\program\Codex++\codex-plus-plus-manager.exe`）和 Client PID `18216`（`D:\program\Codex++\codex-plus-plus.exe`）。监视器 `Test-ManagedCodexProcessState` 要求 PID、绝对路径和启动时间精确匹配，所以活动客户端存在时会固定生成 `route.failed`。这是监视器输入快照陈旧，不是 route-state heartbeat 过期。
- 另有官方 `codex.exe` PID `13180`，路径为 WindowsApps 下的 OpenAI Codex，父进程为 `ChatGPT.exe` PID `26108`，不属于受管 Codex++ 进程树。它解释了监视器的 1 条“官方 Codex 旁路”警告；截图顶部显示“Codex”与此一致，但当前没有窗口句柄到 PID 的直接映射，因此不能把截图窗口身份写成百分之百确定。
- 项目源码存在 `src/codexpp/Codex++/headroom-status-indicator.js`，其状态端点为 `http://127.0.0.1:18788/status`。但运行中的 `C:\Users\ma dao\AppData\Roaming\Codex++\user_scripts.json` 不含 `user:headroom-status-indicator.js`，运行目录也没有 `headroom-status-indicator.js`；项目源元数据与运行副本的脚本版本也不一致。这是顶栏按钮缺失的独立根因：当前 Manager 没有加载该脚本。
- Manager `57865` 虽在监听，但对常见 user-script REST 路径超时；因此当前无法从 Manager bridge 证明脚本已注册或 `electronBridge` 已注入。`18788/status` 本身可达，弹窗无法呼出不能归因于监视器端点失效。

### 结论与边界

本次现象由两条链叠加：

1. **监视器误报**：Manager/Client 重启后没有把最新 PID、路径和启动时间原子刷新到 `managed-codex-processes.json`，而监视器采用精确身份匹配，故把真实受管客户端判为路由不匹配。
2. **指示器未部署或未注册**：源码中的 Headroom 指示器没有进入当前 Codex++ Manager 的运行脚本目录；如果截图窗口实际属于官方 `codex.exe`，它本来就不会加载 Codex++ 用户脚本，必须先确认使用的是受管 Codex++ 窗口。

本轮只做了只读诊断和文档更新，没有启动/停止进程，没有修改 `config.toml`、供应商定义、Base URL、认证、模型、会话或二进制，也没有触碰 `D:\gpt-image2`。

### 下一步修复要求

- 启动链在 Manager/Client 成功创建后，必须重新采集精确 PID、路径、启动时间并以临时文件加原子替换更新 `managed-codex-processes.json`；监视器还应在快照缺失或 PID 不匹配时重新观测，而不是把新进程直接标红。
- 指示器恢复必须只通过 Codex++ 支持的 user-script 注册/部署路径，精确恢复 `user:headroom-status-indicator.js` 及其文件，保留其他脚本 key；不得删除整个 `user_scripts.json`，不得改写供应商配置。
- 修复后必须分别验证：受管 Codex++ 窗口的顶栏按钮和弹窗、`/status` route green、无旧 PID 快照，以及官方 `codex.exe` 仍被明确标记为旁路而不被误认为受管客户端。

证据来源：`runtime/state/managed-codex-processes.json`、`runtime/state/codexpp-route-state.json`、`runtime/state/codexpp-headroom-monitor-status.json`、`src/codexpp/Codex++/headroom-status-indicator.js`、运行时 `AppData\Roaming\Codex++\user_scripts.json` 和脚本目录；本轮由 `/root/route_process_recon` 与 `/root/indicator_recon` 只读交叉核验。

作者：Codex。

## 2026-08-01 桌面一键启动修复复核

本节覆盖前文关于桌面冷启动失败的历史描述；历史失败记录保留用于审计，当前状态以本节和 `evidence\startup-shortcut-fix-20260801.json` 为准。

- 根因已由真实冷启动复现：旧的项目 broker 残留在 `18790` 时，非提升上下文无法读取其命令行，安全身份门禁将其拒绝为未验证；服务恢复后，Manager 启动会更新 `config.toml` 的非供应商元数据，旧的全量哈希相等检查又把这次合法更新误判为失败。
- 修复 `scripts\Start-HeadroomForCodexPP.ps1`：保留 broker/Headroom/Gateway/route 的只读和身份门禁；Manager 启动后改为校验活动 provider 段、`base_url`、`wire_api`、`requires_openai_auth` 和 bearer-token 字段存在性不变，允许 Manager 自身更新 `service_tier`、`notify`、feature/marketplace 元数据；启动收据记录前后哈希和保护契约结果。
- 真实冷启动：`headroom-start-result.status=succeeded`、`stage=manager_and_client_launched`；桌面 `.lnk` 重复点击：`stage=already_managed`，未创建重复进程。
- 运行态：`18787/18788/18789/18790/57321/57865/57866` 全部监听；route `ready`、`route_scope=process`、`config_mutated=false`；Kompress `CPUExecutionProvider/onnx/ready`。
- 测试：Python `30/30`、startup-chain、managed-process、stale-route-keeper、route-keeper-identity、activation fixture、PowerShell AST `49` 文件 `0` 错误、`git diff --check` 均通过。重复点击收据：`evidence\startup-shortcut-fix-20260801.json`；最新冷启动收据：`evidence\startup-cold-start-20260801.json`。

作者：Codex。

## 2026-08-01 最终实施计划完成度审计

- 已交付：唯一入口/进程级路由、`main -> compress` 与 `spawned -> bypass`、只读配置校验、CPU ORT 1.28.0 Kompress、fail-open、SSE 终态保护、route heartbeat，以及 `50 main + 50 spawned` 最终验收（504/断流/解码/误分类均为 0）。
- 部分完成：C 盘 Headroom 资产迁移与源删除仍受受保护数据和 Manager metadata 入口限制；监控界面可用，但上游没有精确 usage token，token/cache 统计仍为不完整或估算。
- 未完成：DirectML 完整 Kompress 触发 device removal；NPU 条件不满足；MIGraphX/VitisAI/AMD plugin 未进入生产候选。生产后端继续保持 CPU。
- GitHub 发布已完成：普通 Git transport 失败后使用 Git Data API 发布，远端 62 个脱敏文件逐项校验一致；详见 `evidence/github-api-publish-20260801.json`。

结论：核心生产代理目标已完成，但“最终实施计划”整体仍为部分完成，未达到 GPU/NPU 与完整迁移的 100% 闭环。

作者：Codex。

作者：Codex。

## 2026-08-01 P27a/P27b 收口（Reasonix）

- P27a monitor 快照自愈已完成：monitor 新增 `Update-StaleManagedCodexState`（fail-closed：精确 2 进程集 + PID 变化才原子刷新，保留 source_hashes），`Get-ClientRouteObservation` 先自愈再判红；启动链对精确 2 进程集直接刷新快照不再强制重启。实测 `managed-codex-processes.json` 从旧 PID 22764/23592 刷新为实时 18408/15480，monitor route 转 green。测试：Python 30/30、PowerShell AST 50/50、startup-root 等全部 PASS。
- P27b 指示器已注册：新增 `scripts/Register-HeadroomUserScript.ps1`，`user_scripts.json` 的 scripts+market 双 section 注册 `user:headroom-status-indicator.js`（v1.0.0.10），js 复制到 loader 扫描目录，6 个非 headroom key 全保留，备份已建。
- 受控重启 Manager/Client 过程中发现 P26 遗留竞争：`codexpp-startup-gate.ps1` 的 `Invoke-RouteKeeper`（约 565-571 行）对 config.toml 做 before/after 全量哈希比较，Manager 启动时更新元数据（`13FD8185`→`854B063B`）与 wrapper route keeper 并发 → fail-closed；三轮启动失败后按规则停止。当前服务链健康、relay 57321 由 client 25448 持有，Manager 已退出、route watcher 缺位（monitor route red）。修复方向：route keeper 改为校验供应商受保护契约（provider/base_url/wire_api/auth 存在性）而非全量哈希，允许 Manager 元数据更新后重新发布。
- 用户需通过桌面入口 `D:\Desktop\Headroom for Codex++.lnk` 手动重启 Manager/Client；重启后验证 route green、monitor overall、顶栏指示器。
- 证据：`evidence/p27a-p27b-20260801.json`；本 Agent 未修改供应商/认证/模型/会话/二进制，未触碰 `D:\gpt-image2`。

作者：Reasonix。

## 2026-08-04 WebGPU + CPU 生产复核与隔离路由施工

本轮复核结论仍为 **NO-GO**。生产 `18788` monitor 无监听，PowerShell 完整身份采集超时并回退到 `netstat`，route-state heartbeat 过期；`18787/18789/18790` 健康且 Kompress 实际为 CPU ORT ready，但不足以满足生产放行。

隔离 `runtime/lab` 已补齐显式 `return_scores/final_scores` 协议、WebGPU 文本 provider、`cpu`/`webgpu_cpu` provider router 和 CPU fail-open；默认不加载 WebGPU。新增只读验证器：`scripts/Validate-ProductionCandidate.ps1`。它只写脱敏收据，退出码为 `0=GO`、`1=drift/unknown/NO-GO`、`2=malformed`。

证据：`evidence/accel-webgpu-text-router-v1.json`、`evidence/production-candidate-audit-20260804.json`（SHA-256 `ACB0A159C6433CED4AB37D53FB384020996B90D11BFA47BDB935A5888CE2409D`）。当前机器因既有 `0xC0000409/LiveKernelEvent 141` 风险不再启动硬件 session；真实 WebGPU 文本 `/compress`、长 SSE、独立环境和独立验收仍未完成。施工方案已更新为 `docs/PRODUCTION-WEBGPU-CPU-DEPLOYMENT-PLAN-20260803.md` v1.1。

最终复核：CPU 是 provider router 默认；WebGPU 需要显式 flag 和项目内隔离解释器，不借用生产 Python。默认导入未加载 WebGPU/ORT；主解释器加速测试 30（29 passed、1 skipped），隔离 lab venv 33/33 passed，生产审计仍为 `NO-GO`。

GPU 稳定性修复已增加 fail-closed preflight：当前项目带有 0409/141 收据时，guard 和真实文本验收 harness 都在 native provider 初始化前拒绝启动。收据为 `evidence/accel-webgpu-stability-preflight-v1.json`；当前真实 WebGPU 文本验收状态是 `blocked`，不是 `passed`。

作者：Codex。

作者：Codex。

## 2026-08-03 供应商配置恢复（Codex）

- 现场只读证据显示 `.codex-session-delete/settings.json` 曾只剩 1 个临时 `route-c-canary` profile；该文件的当前内容已先备份到项目根 `backups/supplier-recovery/`，没有输出或复制任何 Key/认证值到收据。
- 使用标记为“correct-backup”的 `C:\Users\ma dao\.codex-session-delete\settings.json.correct-backup-20260801` 原样恢复 6 个原供应商：`codex-ds v4`、`skyapi vip`、`skyapi 包月`、`skyapi 包月 副本`、`自有号池`、`自有号池 副本`。恢复源不含临时 `relay-aggregate-headroom`，也不带旧 route-A 的 `supports_websockets=false` 改写。
- 恢复后的 live SettingsStore SHA-256 与源文件一致：`DDB69F35535BD99DDBCFAA91C7F04CC664C1C89C902586B5FB059FC2BBACD999`；6 个 profile、活动 ID `relay-ms95lcei`、无聚合项，连续 2 秒观察稳定。
- 新增可回滚脚本 `scripts/Restore-CodexPlusPlusSuppliers.ps1`，支持 dry-run、项目根备份、原子替换、哈希回读和稳定性检查。脱敏收据：`evidence/supplier-recovery-dryrun-20260803.json`、`evidence/supplier-recovery-execute-20260803.json`。
- 恢复发生时 Manager/Client 仍在运行；本轮没有停止或重启它们，因此当前 UI 可能仍显示旧的内存态。用户手动重启 Codex++ Manager/Client 后，才可把界面列表和下一次 Relay 读取认定为已加载恢复配置。

作者：Codex。

## 2026-08-02 Route C native 施工进度（Codex）

- 用户提供的官方 `CodexPlusPlus-1.2.44.zip` 已作为源码基线；Route C 核心施工已落到该源码树：
  - `crates/codex-plus-core/src/route_c.rs`：模式合同、loopback/保留端口拒绝、内部 header 清理、SSE 缺失终态补 `response.failed`、fail-open 合同。
  - `crates/codex-plus-core/src/supervisor.rs`：脱敏 JSON lease、owner PID/start、generation、heartbeat、能力摘要、stale reclaim、原子写入和代际保护。
  - `crates/codex-plus-core/src/route_c_runtime.rs`：生产端口/隔离端口、loopback ingress client、请求头脱敏和 Route C 配置；默认模式为 `off`。
  - `launcher.rs`：显式 Route C 模式才启用 native ingress、57322 egress、SSE 终态保护和 5 秒 lease heartbeat；普通启动路径保持原行为。
  - launcher/Manager：支持 `--route-c-mode off|isolated|managed` 及隔离端口参数；Manager 默认仍传 `off`，不写供应商配置。
- 隔离运行验证：`tests/Invoke-IsolatedRuntimeSmoke.ps1` 通过；broker=`CPUExecutionProvider`，Headroom/Kompress=`healthy/onnx`，`tokens_before=3529`、`tokens_after=1521`、`tokens_saved=2008`。`Invoke-RouteCPoCPortSmoke.ps1` 通过，端口 `58322` readiness 和释放均通过；Python Route C PoC `11/11`，Gateway `30/30`。
- 管理器验证：Node `v22.23.2` 下 `npm run check`、`npm test`（36/36）和 `npm run vite:build` 均通过；PowerShell 启动链、可见启动器、route keeper identity、managed process、official dataplane fixture 均通过。
- Rust 静态验证：`cargo fmt --all -- --check`、`cargo metadata --offline --no-deps`、`git diff --check` 通过。完整 `cargo check/test/build` 尚未通过，当前阻塞是本机隔离 VS 18 缺失 `VC\Tools\MSVC\14.51.36231\include`（`vcruntime.h/stdarg.h`），不是已证实的源码错误；未安装系统组件。
- 运行边界：Route C 仍未激活到当前官方 ChatGPT/Codex 窗口，`official_dataplane` 仍为 `NOT_PROVEN/bypass`；没有停止生产进程、没有修改 `config.toml`/SettingsStore/auth/provider、没有触碰 Vortex 或 `D:\gpt-image2`。只有 Rust 完整构建、Canary 激活和用户手动窗口验收完成后，才能将 Route C 标记为生产可用。

作者：Codex（2026-08-02）。

## 2026-08-02 P46 Route C 前置收口（Codex）

- Route C native 施工**尚未开始**。计划要求的官方 Codex++ `v1.2.44` / commit `77091cc` 源码与隔离工具链必须先完成，不能使用本地无 Git 元数据的 `1.2.35` 快照替代。
- `git ls-remote` 已确认官方 tag `v1.2.44` 指向 `77091ccaee4423f35a1b2c51c4ecd703e6201092`；完整 clone 和一次官方浅克隆均在约 184 秒后超时。浅克隆 staging 只有正确 HEAD，没有 index，281 条 tracked 文件均未 checkout，不能用于构建或修改。
- 当前 Node 为 `v26.1.0`（计划要求 Node 22）；Rust stable MSVC manifest 缺失，`rustc` 不可执行；未运行 `npm ci`，未生成 `runtime/state/route-c-toolchain.json`。因此 P46 状态为 `UNKNOWN`，不是成功。
- 已追加独立官方 codeload 备用通道：归档下载约 210 秒超时，仅收到 `3,469,312` 字节；gzip 头有效，但 `tar -tzf` 报 `Truncated input file`，未解包、未核对 workspace version/commit，不能作为源码。
- 这次尝试没有触碰 `D:\program\Codex++`、供应商配置、凭据、会话、Vortex、`D:\gpt-image2` 或生产进程。保留不完整 clone 仅用于审计，不把它当作源码基线。
- 在 Reasonix/用户提供完整、可核验的官方源码树或恢复 GitHub 443 传输前，Route C 的 `57322` egress、native supervisor/lease、Canary 构建和真实验收均保持 `NOT_EXECUTED`；现有受管 Headroom 链与 `official_dataplane=bypass/not_proven` 不变。

证据：`evidence/p46-route-c-toolchain-prep-20260802.json`。作者：Codex。

## 2026-08-02 P47 Route C 源码恢复复核（Codex）

- 续作中官方 tag `v1.2.44` 的 `ls-remote` 出现间歇性成功，但 clone/fetch/filtered checkout 的 blob 传输仍无法完成。
- `runtime/src/CodexPlusPlus-v1.2.44.recovery/filtered` 可核对到 HEAD `77091cca...` 和 281 条 tree 记录，但本地 blob/工作文件为 0，不能用于构建；`runtime/state/route-c-source-recovery.json` 未生成。
- 已按精确 recovery 命令行停止隔离 Git 进程；未触碰生产 Codex++、配置、凭据、会话、Vortex、`D:\gpt-image2` 或生产端口。
- P47 状态为 `UNKNOWN`。在完整官方源码树或经用户/Reasonix批准的官方离线包到位前，Route C native supervisor/lease、57322 egress、工具链、Canary 和真实验收继续保持 `NOT_EXECUTED`。

证据：`evidence/p47-route-c-source-recovery-20260802.json`。作者：Codex。

## 2026-08-02 P48 Route C 隔离合同 PoC（Codex）

- 新增 `src/route_c_poc`：lease/generation、能力摘要、内部 header 剥离、自循环上游拒绝、SSE 终态补发和上游 5xx fail-open；不读取 SettingsStore，不保存原始 capability，不拥有生产端口。
- 标准库 `unittest` 通过 `11/11`，并与现有 Kompress broker 回归合计 `22/22`；包含 30 个 main + 30 个 spawned 合成流、网络异常 fail-open 和带空格 SSE 终态；`scripts/Invoke-RouteCPoCPortSmoke.ps1 -Port 58322` 通过，`127.0.0.1:58322/health` 返回 `ready=true,native=false,production=false`，精确 PID 已回收且端口释放。
- 该 PoC 证明隔离合同可行，不证明 Codex++ native 集成、官方窗口接入或生产 Route C 已完成；P46/P47 仍为 `UNKNOWN`，native implementation 仍 `NOT_EXECUTED`。

证据：`evidence/p48-route-c-isolated-poc-20260802.json`。作者：Codex。

## 2026-08-02 P44 Route C 架构冻结（Codex team / P44d）

### 冻结结论

本节是架构评估和迁移交接，不是功能实施收据。Route C 的结论为：**满足条件后可行**。纯 renderer/marketplace/user-script 插件不能满足数据面目标，因为 renderer 只能承载固定的 bridge/UI 内部消息补丁，不能拥有 native helper、协议代理、AppX 启动、CDP 注入或 restart 生命周期。

P43 的断流根因是独立 route-A 与受管 Codex++ 同时争抢同一 helper/client 的**双生命周期所有者**；不是 UI 注入失败，也不是 AppX 激活失败。P43 已证明 AppX 激活和首请求可以工作，但 Manager readiness-only 会停止受管 client/helper，随后 `57321` 消失。

### 用户截图与 renderer 边界

- 用户截图证明的现状是 renderer 层可以显示 Headroom 指示器、popup，并通过固定 bridge/UI 内部消息通道做界面补丁。
- 这类注入是控制面/展示面证据，不证明 renderer 拥有 `57321`、`57322`、Gateway、Headroom、app-server 或任何重启租约。
- P44a 本地源码回执进一步确认：Codex++ native Rust/Tauri launcher/helper 才拥有 helper、协议代理、AppX 激活、CDP 注入和 restart 生命周期；renderer user script 不是这些资源的所有者。
- 现有 UI 注入、indicator 和 popup 必须作为 Route C 的回归基线保留；本节尚未验证它们不会受新增 native supervisor/lease 影响。

### Route C 目标拓扑与所有权（未实施）

```text
官方 ChatGPT/Codex 单窗口
  -> 现有 Codex++ ingress helper 127.0.0.1:57321
  -> Gateway 127.0.0.1:18787
  -> Headroom 127.0.0.1:18789
  -> 新增 Codex++ egress relay 127.0.0.1:57322
  -> SettingsStore 当前选中的真实上游
```

- **Codex++ native supervisor/lease** 是 `57321`、`57322` 以及 Gateway/Headroom sidecars 的唯一生命周期所有者；同一 owner PID、启动时间、generation 和 heartbeat 必须覆盖整条链，避免 P43 的双所有者竞争。
- 官方单窗口仍由系统/官方应用拥有；Route C 只为其提供受支持的 app-server/config 进程级接入面，不能把 renderer 脚本当作官方窗口的网络 owner。
- renderer user scripts、Headroom indicator、popup 和既有管理弹窗继续只负责 UI/控制面；它们不得直接启动/停止 helper、写 provider/config、占用端口或接管 lease。
- Gateway 继续负责请求分类和内部 header 剥离；Headroom 继续负责 `main -> compress`、`spawned -> bypass`、fail-open 与原始 SSE 字节透传；57322 只负责把脱敏后的请求交给 SettingsStore 当前真实上游。
- egress relay 必须仅绑定 loopback；每个 generation 使用独立 capability，过期或 owner heartbeat 丢失即拒绝；拒绝所有本地上游和保留端口（至少 `18787/18789/57321/57322`）以防自循环；发送到真实上游前剥离内部路由、generation、调试和授权头。

### 保留功能清单

- 现有 Codex++ 管理弹窗、单窗口体验和用户脚本注册/bridge 行为。
- Headroom status indicator、popup、状态轮询和已有 UI 内部消息 patch。
- 受管 Codex++ 的 `57321` ingress、Gateway `18787`、Headroom `18789`、现有压缩/旁路策略和 SSE fail-open 契约。
- SettingsStore 作为供应商选择权威；Route C 不复制、迁移或改写供应商定义、Base URL、Key、认证、模型或会话。
- 现有 Route A 启动修复和失败收据仅作审计/回退资料，不再让第二个启动器拥有同一 helper。

### 不破坏迁移顺序

1. 先冻结现有受管链和 renderer UI 行为；只记录当前受保护契约、端口和脚本注册状态，不写运行态。
2. 在隔离环境实现并验证 supervisor/lease 和 `57322` egress 合同，使用本地假上游或 app-server fixture，不接生产上游。
3. 通过最小 PoC 闸门后，再以一个明确 owner 的 native launcher 绑定官方单窗口；不得复用 Route A 的第二生命周期所有者，也不得回退到旧的 `config.toml` 写入方案。
4. 先做单窗口、单 generation、单 SSE canary；连续观测 owner heartbeat、Gateway/Headroom/57321/57322 关联和标准 SSE 终态后，才讨论扩大范围。
5. 任一闸门未通过时保留当前受管链和 UI，Route C 标记 `NOT_PROVEN`，不报告生产成功。

### 最小 PoC 闸门

- **G1 进程/租约唯一性**：同一 supervisor 能启动并回收 57321、57322、Gateway、Headroom；第二 owner 不能获得 capability，lease 丢失时新 generation 请求被拒绝。
- **G2 egress 安全合同**：loopback 绑定、generation capability、内部 header 剥离、本地上游拒绝、上游异常 fail-open/标准错误终态均有可复核 fixture。
- **G3 官方接口绑定**：以官方支持的 `codex app-server` stdio、`CODEX_HOME` 或 `-c/config` 进程级覆盖完成一次隔离握手；不能把 `ActivateApplication` 单独当作 provider/environment 注入证据。
- **G4 单窗口连续流**：经 `57321 -> 18787 -> 18789 -> 57322` 完成真实授权的一次 SSE，Gateway correlation、Headroom 计数、57322 上游关联和 `response.completed`/标准失败终态全部对应同一 generation；Manager 不得停止 client/helper。
- **G5 脱敏与恢复**：日志只记录 profile/capability 哈希、PID/generation 和状态；无凭据、令牌、完整会话正文；正常退出、崩溃和超时均能撤销 lease 并恢复到原受管链。

以上闸门当前均为设计验收项，未执行，不能被现有 P43 激活/首请求证据替代。

### 失败回退

- 新 supervisor/lease 或 57322 任一闸门失败：撤销当前 generation capability，关闭/隔离由新 owner 创建的组件；保留当前已验证的 Codex++ 受管启动/UI/`57321` 直达所选上游能力和独立 Headroom sidecars，并保持 `official_dataplane=bypass/not_proven`，不宣称二者已串联。
- 不停止现有 Manager/Client，不修改 SettingsStore、供应商配置、`config.toml`、认证、模型或会话，不自动重试 Route A，不把本地端口当作真实上游。
- UI/状态页只显示 `Route C NOT_PROVEN` 及脱敏错误阶段；只有重新满足全部闸门后才允许新一轮 canary。

### 尚未实施边界与未知项

- 未新增 native supervisor、lease、57322 relay、app-server wrapper 或任何源代码；未启动 57322；未绑定官方 packaged ChatGPT；未做连续官方窗口到 Headroom 的 SSE 联测。
- 未知项 1：官方 packaged ChatGPT 是否能稳定绑定到独立 native launcher/app-server/provider。
- 未知项 2：Codex++ 是否愿意/能够新增覆盖 ingress、egress 和 sidecars 的 lifecycle lease。
- 未知项 3：真实官方窗口到 Headroom 的连续 SSE 是否能在不触碰 Vortex、供应商配置和系统代理的前提下复现。

脱敏架构收据：`evidence/p44-route-c-architecture-20260802.json`。

作者：Codex team / P44d。

## 2026-08-02 当前桌面客户端实时复核（Codex）

- 采样时间：`2026-08-02T03:31:29Z`。官方桌面 `codex.exe` 与 ChatGPT 子进程均连接 `127.0.0.1:7897`；连接 `57321/18787/18789` 均为 0。
- `7897` 由 `com.vortex.helper.exe` 监听；`57321` 由受管 `codex-plus-plus.exe` 监听。官方桌面和受管 Codex++ 是两条不同链路。
- 官方 `.codex\config.toml` 虽写有 `http://127.0.0.1:57321/v1`，但实时连接与配置不一致；Gateway 计数在采样窗口内无变化。当前桌面会话是否由 Vortex 继续转发到哪个远端，上游证据不足。
- 结论：不能宣称当前桌面会话已走 Headroom；最近实时证据更支持绕过本地 Headroom。受管 Codex++ 的 Headroom 健康不等于官方桌面会话经过 Headroom。

## 2026-08-02 PHASE-C 复核与压缩模式收口（Codex）

- 重启后的受管链已复核：Gateway `18787`、Monitor `18788`、Headroom `18789`、Kompress broker `18790`、Relay `57321`、Manager `57865`、Client `57866` 均监听；route-state 为 `ready/process/config_mutated=false`；Manager/Client 各一；配置受保护契约未变化。CDP `127.0.0.1:9229` 仍不可达，因此顶栏按钮和 popup 保持 `UNKNOWN`。
- PHASE-C 流量窗口的 50 个 main 全部 HTTP 200/SSE `response.completed`；50 个 spawned 中 43 个成功、7 个被 Headroom 原样记录为 `spawned_bypass` 后收到 Relay 上游 502/503。Headroom 日志明确写出 `Forwarding upstream streaming error ... url=http://127.0.0.1:57321/v1/responses`，且 `body_mutated=false`、`Responses passthrough reason=bypass_header`；Kompress broker 没有 timeout、worker restart、device removal 或 error。该窗口不能作为整体通过收据，根因暂记为 Relay/上游 5xx，不能归因于压缩层。
- 用户截图中的 `gpt-5.2 /v1/responses / python-httpx/0.28.1` 已通过本地请求窗口和代理日志核对为本轮验收/探针产生的真实上游流量，不是 Codex++ 桌面自然请求；该窗口为 `2026-08-02 10:58:53-11:06:28 (+08)`，后续验收必须先告知会产生真实中转站计量，再执行。
- 模式结论已校正：生产源码 `ensure-headroom.ps1` 与 `start-headroom.ps1` 当前仍设置 `HEADROOM_MODE='cache'`，`HEADROOM_FORCE_KOMPRESS_ALL` 未启用；生产 `/stats` 也报告 `summary.mode=cache`、`compression.requests_compressed=3`。`cache/token` 是压缩策略与 prefix-cache 行为选择，不等同于 Gateway 的 `main/compress`/`spawned/bypass` 分类，也不意味着每个 main 请求都必须发生字节变换。此前“生产已改为 token”的记录是文档漂移，已撤回。
- 隔离验证：备用端口 `18889` 的 token 模式实验曾启动成功，但该实验已停止，且 `evidence/phase-c-token-mode-smoke-20260802.json` 的 spawned bypass 检查未通过；不能把它当作生产配置或完整验收依据。生产进程未因本次核对被停止或重启。
- 本轮测试：`test-headroom-activation.ps1` PASS、Python Gateway `30/30`、`Test-HeadroomMigrationScripts.ps1` PASS；新增启动模式回归断言。

当前结论：PHASE-C 路由收据已通过；交通收据因 Relay 上游 5xx 失败，指示器 UI 因 CDP 不可达仍未完成；压缩模式修复已写入源码但等待用户手动重启后再做最终验收。

作者：Codex。

## 2026-08-02 测试流量来源核对（Codex）

- `evidence/phase-c-traffic-20260802.json` 的请求窗口是 `2026-08-02T02:58:53.948749Z` 至 `2026-08-02T03:06:28.123879Z`（北京时间 `10:58:53-11:06:28`），模型字段全部为 `gpt-5.2`：`50 main + 50 spawned`，共 `100` 条 `POST /v1/responses`。
- 代理日志在同一窗口统计到 `100` 条 `/v1/responses`，其中 `100/100` 的入站 User-Agent 为 `python-httpx/0.28.1`；另有 `51` 条同 UA 的 `/health` 探针。运行时锁文件 `runtime/wheelhouse/requirements-lock.txt` 固定 `httpx==0.28.1`，所以该 UA 与测试客户端一致。
- 这些请求的本地链路是 `http://127.0.0.1:18787/v1/responses` -> Headroom `18789` -> Relay `127.0.0.1:57321/v1/responses`。因此中转站看到一批 `gpt-5.2`、`python-httpx/0.28.1` 是测试直接造成的计量；本地证据不能读取中转站后台的计费明细，但时间、模型、数量、UA 和链路全部相符。
- 随后只读读取生产 `/stats`（2026-08-02T03:34:04.3181219Z）仍显示 `summary.mode=cache`、`force_kompress=false`、`requests.by_model.gpt-5.2=100`、`compression.requests_compressed=3`；该计数与 PHASE-C 窗口的 100 条模型请求相符。
- `/stats` 同时显示这 100 条 `gpt-5.2` 的 `tokens_saved=0`；它们是实际转发到上游的模型请求，但不等于 100 次 Kompress 字节压缩。生产 `cache` 策略会冻结前缀或直接透传，只有符合条件的内容才进入压缩。
- 这不是用户自然对话，也不是后台自行生成的模型流量。今后若不希望污染中转站统计，应在执行真实流量验收前单独确认，并优先使用隔离上游/本地假 helper；不能把本轮计量混入自然使用基线。

作者：Codex。

## 2026-08-01 23:23 路由复核（Codex）

- 实时快照：受管 Manager/Codex++、Gateway `18787`、Headroom `18789`、Relay `57321` 均在监听；route-state 为 `ready`、`route_scope=process`、`proxy=local-headroom`、`config_mutated=false`。
- 最小 Responses 探针发往 `http://127.0.0.1:18787/v1/responses`，返回 HTTP 200（约 7.2 秒）；Gateway 计数为 `206/206`，其中 `main/compress=104`、`spawned/bypass=102`，Headroom `/health=200`。
- 结论：受管 Codex++ 当前实际走 Headroom 链，不是直连；原始供应商 `base_url` 保持上游地址，路由由进程级覆盖实现。截图中的 HTTP API 黄色项只表示监控等待新的完成请求基线。
- 未修改供应商、Base URL、API key、认证、模型、会话或二进制。

## 2026-08-01 23:26 当前 Codex 桌面路由校正（Codex）

- 本轮目标是当前 Codex 桌面进程，而不是受管 Codex++ 客户端。官方 `codex.exe`（PID 4040）及其 code-mode host 不在受管 Codex++ 进程树内；监控绿色“客户端路由”只确认受管 Codex++，同时明确给出官方 Codex 旁路警告。
- 当前官方 `C:\Users\ma dao\.codex\config.toml` 的 `base_url` 为 `https://skyapi2026.com`；读取时未观察到官方 Codex 进程连接本地 `18787/18789`。因此当前 Codex 桌面会话不经过本地 Headroom，按配置走上游直连；系统级或上游内部代理未在本轮验证。
- 受管 Codex++ 仍是另一条链路，仍由进程级覆盖指向 `127.0.0.1:18787/v1`，不能与当前桌面会话混为一谈。
- 本轮未修改供应商、Base URL、API key、认证、模型、会话或二进制。

## 2026-08-01 23:49 当前桌面客户端代理复核（Codex）

- 当前目标为官方 Codex 桌面进程，不是 Codex++。`codex.exe` 的已建立连接指向本机 `127.0.0.1:7897`，没有连接 Headroom 的 `18787/18789`。
- `7897` 由 `C:\Users\ma dao\.config\com.vortex.helper\com.vortex.helper.exe`（PID 18272）监听；该进程有 37 个已建立连接，包含非回环出站连接和远端 443 连接。
- 结论：当前桌面 Codex 不经过 Headroom，也不是裸直连，而是经过 Vortex helper 这一独立本地代理；官方配置的上游仍为 `https://skyapi2026.com`。系统级或上游内部的更深层代理未验证。
- 受管 Codex++ 的 Headroom 链路是独立进程链路；本轮未修改任何配置、供应商、凭据、认证、模型、会话或二进制。

## 2026-08-01 当前 Codex 桌面路由复核（续）

- 当前官方 `codex.exe` 的 6 条已建立连接全部指向 `127.0.0.1:7897`；连接 Headroom `18787/18789` 和 Relay `57321` 均为 0。
- `7897` 监听者仍为 `com.vortex.helper.exe`；官方 `base_url` 仍为 `https://skyapi2026.com`。
- 结论保持不变：当前桌面 Codex 直连上游前先经过 Vortex helper，不走 Headroom；受管 Codex++ 的 Headroom 链路不适用于该桌面进程。

## 2026-08-01 当前桌面进程树复核（Codex）

- 当前 ChatGPT/Codex 桌面进程树共 32 个进程；实际有网络连接的 `ChatGPT.exe` 子进程和 `codex.exe` 均只连接 `127.0.0.1:7897`，到 Headroom `18787/18789` 和 Relay `57321` 均为 0。
- `7897` 的 Vortex helper 也无到 `18787/18789/57321` 的连接；P28 的受管 Relay 健康证据不能证明当前桌面会话使用该链路。
- 结论：当前桌面 Codex 绕过 Headroom，经过 Vortex helper 后访问配置的上游 `https://skyapi2026.com`；不是 Headroom 链路。系统级或上游内部代理仍未验证。

## 2026-08-01 当前客户端 Relay/Headroom 复核（续）

- 当前桌面 `codex.exe` 已建立到 `127.0.0.1:57321` 的连接，当前 `.codex\config.toml` 的 `base_url` 也为 `http://127.0.0.1:57321/v1`；因此它不是直接连接远端上游。
- 向 `57321/v1/responses` 发最小探针返回 HTTP 200，但 Gateway 计数保持 `220`，Relay 进程当时未显示到 `18787/18789` 的连接；现有证据不能证明该 Responses 请求经过 Headroom。
- 当前结论：客户端经过本地 Relay（并伴随 Vortex helper 连接），但本轮实际流量更像 Relay/Vortex 直达上游，Headroom 链路仍未被真实请求证实；route-state 的 `ready/local-headroom` 属控制面状态，不能单独替代流量证据。

## 2026-08-01 当前桌面实时快照（再测）

- 当前 ChatGPT/Codex 进程树没有到 `127.0.0.1:57321`、`18787`、`18789` 或 `7897` 的连接；`codex.exe` 只有远端 443 连接。
- 尽管 `.codex\config.toml` 仍写有 `http://127.0.0.1:57321/v1`，运行态未使用该本地 Relay。当前快照因此判定为绕过 Headroom/Relay 的外连路径；是否经过系统级或上游内部代理未验证。

## 2026-08-02 P28 收口（Reasonix）

- 桌面快捷方式 `D:\Desktop\Headroom for Codex++.lnk` 已设置 `SLDF_RUNAS_USER`（LinkFlags 0x000010F7），**普通双击即管理员启动**，无需右键；`Set-HeadroomDesktopEntry.ps1` 已固化该位并在重建时校验。
- Codex 直连 skyapi 问题已通过**聚合供应商**解决：`settings.json` 新增并激活 `relay-aggregate-headroom`（成员 = 全部 6 个 API 供应商），Codex++ 自动启动本地 helper `127.0.0.1:57321` → Headroom Gateway 18787，**无论切换哪个供应商都经 Headroom 压缩/转发**；原供应商配置未动。工具：`scripts/Set-HeadroomAggregateRelay.ps1`。
- 验证：受管链稳定（relay 57321、官方 Codex CDP 9229 在线），monitor overall=yellow（核心项全 green），`57321 /v1/models→200`，Gateway helper=True。
- 证据：`evidence/p28-shortcut-admin-and-relay-20260802.json`。

作者：Reasonix。

## 2026-08-02 P29 收口（Reasonix）

- **启动提速**：already_managed 快速路径（受管链已在时跳过服务 ensure/Test-Ready）+ `Test-Listener` 改用 `Test-NetConnection`（1.47s→0.02s/次）。受管链常驻时**双击快捷方式约 2 秒**（此前约 10 秒）。冷启动仍约 53 秒（Codex++ gate 安全契约，不可跳过）。
- **开机自启**：启动文件夹快捷方式 `...\Startup\Headroom for Codex++.lnk`（登录自动启动受管链）。登录后双击即 2 秒。
- 计时埋点写入 `runtime\logs\startup-timing.log`。
- 证据：`evidence/p29-startup-speed-and-autostart-20260802.json`。

作者：Reasonix。

## 2026-08-02 文档收口索引（Codex）

最新核对结果见上方“测试流量来源核对”：本轮产生了 `100` 条 `gpt-5.2` 测试 Responses 请求和 `51` 条 Python HTTPX 健康探针；生产压缩模式仍是 `cache`，隔离 `token` 实验不代表生产。脱敏收据：`evidence/phase-c-traffic-source-audit-20260802.json`。

作者：Codex。

## 2026-08-02 最终历史校正（Codex）

本文档中早于本节、且声称“当前官方桌面窗口已无条件经 Headroom”的段落属于历史记录，不能覆盖本节结论。当前可确认的是：受管 Codex++ 控制面/测试链健康；官方 ChatGPT/Codex 数据面通过 Vortex `7897`，Headroom 接入仍 `NOT_PROVEN`。旧方案曾改写官方配置并因此出现真实链路，但该方案已因配置铁律和自循环风险永久排除。详见 `evidence/historical-route-audit-20260802.json`。

作者：Codex。

## 2026-08-02 最终当前数据面更正（Codex）

最新只读快照 `2026-08-02T05:40:36.3135903Z` 已把当前官方 `codex.exe`/ChatGPT 网络子进程确认在 Vortex `7897`；官方 PID 到 `18787/18789/57321` 均为否。最终当前结论为 `official_dataplane=bypass`，受管链监听和健康不能替代官方窗口真实连接。收据：`evidence/current-window-route-audit-20260802-live2.json`。

作者：Codex。

## 2026-08-02 历史实现补充复核（Codex）

- 重新读取了 2026-07-26、2026-07-29 交接和旧 route keeper 备份。旧方案确实包含把官方 `config.toml` 的活动 provider 临时改到 `18787`、设置 `supports_websockets=false`、备份并 `File.Replace` 的代码；这解释了为什么历史上可能出现过短暂的官方配置接入，但该路径违反当前配置只读铁律，不能恢复。
- 2026-07-26 交接明确记载“当前官方 Codex 会话没有被证明经过 Headroom”；2026-07-29 交接把首次真实模型请求经过 `18787 -> 18789 -> 57321` 列为未通过，真实冷启动仍失败。因此，现有历史材料不能把“曾经看到 Headroom 请求”认定为稳定、可复现的官方桌面数据面成功。
- 2026-07-30 历史命令行明确包含 `--no-optimize --disable-kompress`，说明当时有完全转发窗口；它只能证明压缩开关状态，不能单独证明请求来自当前官方窗口。同期 504 记录和压缩关闭窗口中的 502 必须分开归因。
- 进一步核对 Codex++ 源码后，P28 聚合注入的实际拓扑被校正为 `Codex -> 57321 -> selected relay upstream`：`commands.rs:2651-2665` 写入的是 `127.0.0.1:57321/v1`，`protocol_proxy.rs:495-545,733-748` 按成员 `relay.base_url` 直接构造上游请求；源码没有自动追加 `18787`。因此 P28 的 relay/health 证据不能证明 Headroom 数据面，只有旧的直接 `config.toml -> 18787` 写入方案具备接入 Headroom 的可能。
- 本次补充审计收据：`evidence/historical-route-audit-supplement-20260802.json`。结论保持：受管 Codex++ 控制面已验证，官方桌面数据面仍为 `bypass/not_proven`；下一步必须先取得一种明确授权的官方接入机制。

作者：Codex。

## 2026-08-02 路线 A：官方窗口进程级接入准备（Codex）

- 已新增独立 CLI shim：`runtime\official-route\shim\codex-cli-headroom-shim.exe`。仅当命令包含 `app-server` 时注入 `headroom_runtime`、`18787/v1`、Responses、无 OpenAI 认证和禁用 WebSocket；其他参数原样透传，并有递归防护。
- 已新增启动入口：`scripts\Launch-OfficialCodexThroughHeadroom.vbs` -> `scripts\Start-OfficialCodexThroughHeadroom.ps1`。启动前检查 Gateway `18787`、Headroom `18789`、Relay `57321`，拒绝本地自循环上游；不写 `config.toml`、`auth.json`、SettingsStore 或 Vortex。
- 已新增脱敏收据：`runtime\state\official-route-a-start.json`、`scripts\Collect-OfficialRouteAReceipt.ps1`。收据只把 WindowsApps 官方 PID 的 TCP 连接计入数据面；当前 `-DryRun` 为 `dry_run_ready`，实时收据为 `bypass`（官方 `7897`），三份配置哈希保持不变；真实启动被延迟到用户手动退出后。
- 隔离测试：shim 参数/递归测试 PASS；Gateway Python `30/30`；official dataplane fixture `18 assertions`；startup-chain/root fixture PASS；构建 SHA-256 `991657B3E80F2F46E9A8B542E86E99B8A12ADDB5EEFFE91A2DE7B087757148A7`。
- 当前仍不能宣称官方窗口已接入 Headroom。用户手动退出现有 ChatGPT/Codex 后运行 `scripts\Launch-OfficialCodexThroughHeadroom.vbs`，再用收据验证官方 PID 到 `18787`、Gateway correlation、Headroom/Relay 上游和 SSE 终态。路线 A 失败后不会自动执行路线 B。

作者：Codex。

## 2026-08-02 P42 收口（Reasonix）

- 修复 4 项 Codex P42 分析定位的缺陷：①route-watch null-safe（Test-RouteStateReady 不再抛异常）；②进度探针降级（不吞启动结果）；③Official route 可见失败摘要；④monitor items 契约同步（official-dataplane 13 项，子序列匹配）——消除 `monitor_status_contract_invalid` 导致的 manager readiness 失败。
- 验证：真实双击启动成功（headroom-start-result succeeded、route ready/process/config_mutated=false、relay/manager/client 全监听）；PowerShell 全 PASS、Python 33/33。
- 证据：`evidence/p42-fixes-verified-20260802.json`。

作者：Reasonix。

## 2026-08-02 P43 收口（Reasonix）

- route-A 激活修复：`Start-OfficialCodexThroughHeadroom.ps1` 改用 `IApplicationActivationManager` 包激活 ChatGPT（替代 CreateProcess），消除 `Win32Exception(5)`；实测 ChatGPT 启动成功、codex.exe 合法派生、数据面走 `127.0.0.1:57321/v1/responses`。
- **架构限制（已记录）**：route-A 独立官方 Codex 路径与受管链（Codex++ 管理体系）在 Windows 上无法共存——Manager readiness-only 自检会停止 client 导致断流。用户决策：受管链为主，route-A 保留启动修复（供未来独立 helper 方案）。
- 证据：`evidence/p43-route-a-activation-fix-and-limit-20260802.json`。

作者：Reasonix。
## 2026-08-03 Route C 计划复核与 Reasonix 交接（Codex）

- Route C 计划已逐项复核。官方 v1.2.44 源码恢复/P47 和 Python 隔离 PoC/P48 有收据；P50 合同、P51 lease、P52 native dataplane 目前只有源码/静态或部分测试，完整 Rust 编译、可运行 Canary、真实官方窗口接入和 1+1→10+10→50+50 验收仍未完成。
- P53 已在 `launcher.rs` 加入 egress loopback `/health`/`/livez` 早处理，但当前 `runtime/canary/route-c/p53-build-target` 只有 Cargo 中间产物，没有 `codex-plus-launcher.exe` 或可读 P53 收据；生产 Route C 继续 `off`。
- 所有未完成、需要工具链补齐、用户手动退出/重启/UAC、真实官方窗口或独立验收的事项已交接到 `REASONIX-HANDOFF-20260803-ROUTEC.md`。缺少 `Activate-RouteCCanary.ps1`、`Rollback-RouteCCanary.ps1` 也已明确列为未完成，不以现有脚本名推断存在。
- CrashSender 只读审计收据 `evidence/crash-audit-20260803.json`：WER 1000/1001 记录 packaged `codex.exe` `0xc0000409`；桌面日志有 401、stdio stop、EPIPE 和 sampler 失败，未发现 Headroom correlation。归因保持 UNKNOWN，交由 Reasonix 做 dump/WER/版本关联和 A/B 复现。
- 供应商文件恢复已完成，但 Manager 启动时会重序列化 SettingsStore；运行态 UI 和内存态必须由用户手动重启后复核，不能把文件恢复收据当作当前窗口已加载证明。

作者：Codex。

## 2026-08-03 Route C 收口进展（Reasonix）

- **编译矩阵全闭环**：cargo check/test/clippy/build 全 PASS（vcvars64 + 隔离工具链解决 MSVC 障碍；clippy 按类别 allow 历史 lint，用户确认）。
- **Canary 二进制部署 + 隔离全链启动成功**（58321/58322/18887-18891 全监听）；canary 副本 manifest 改 asInvoker 免 UAC。
- **Python 链独立验证**：gateway→headroom→fake upstream 返回 response.completed。
- **未决**：canary SSE 全链 `route_c_lease_rejected`（egress 强校验的 header 传递链在 headroom 转发层缺口），需 header 透传专项或校验策略决策。
- 生产受管链未受影响；证据：`evidence/p57-route-c-progress-20260803.json`。

作者：Reasonix。

## 2026-08-03 Route C canary SSE 全链修复（Reasonix）

- **阻塞解除**：canary SSE 全链（official → 58321 → 18887 → 18889 → 58322 → fake_upstream:18891）status=ready
- 根因：loopback 上游禁令 + official normalize 清空 base_url + broker warm URL 错误 + synthetic_run_id redact
- 修复：HEADROOM_ROUTE_C_ALLOW_LOOPBACK_UPSTREAM env（canary 专用）+ pureApi profile + warm 修正 + 契约匹配
- 证据：evidence/route-c-sse-fix-20260803.json

## 2026-08-03 Reasonix 完工声明独立复核（Codex）

本节覆盖 Reasonix 收口段落中与独立证据冲突的部分，不能把旧的“cargo 全 PASS/Canary ready”自报当作最终交付：

- 已确认：P47 v1.2.44 源码恢复、P46 工具链前置、P48 Python 隔离 PoC，以及 P53 修复后的隔离传输/分类链。它们不等于 native Route C 生产可用。
- 最新独立 Canary `runtime/canary/route-c/20260803-133234405` 实际状态为 `failed`，错误为 `An error occurred while sending the request.`；隔离进程已按命令行核验并清理，生产端口未触碰。
- 早一轮 Canary 虽能得到 HTTP 200、`response.completed`、`main/compress` 和 `spawned/bypass`，但 Headroom `requests_compressed=0`、broker `total=0/compressed=0`。因此这些只是传输/分类证据，不是 Kompress 已执行证据。
- 既有 target 的 Cargo 复跑报 `E0463`，全新 target 报 Rust `0xc0000409 / STATUS_STACK_BUFFER_OVERRUN`；当前 exe 只能证明已有二进制可运行，不能证明干净源码构建可重复。
- 生产 Route C 继续 `off`；官方窗口全链 correlation、故障注入、1+1→10+10→50+50、UI/indicator、供应商切换、回滚、登录/注销和 24 小时自然样本仍未完成。

独立收据：`evidence/reasonix-completion-audit-20260803.json`。因此当前总评为：**部分完成，不能报告 Route C 已交付或生产生效。**

作者：Codex。
## 2026-08-03 WebGPU + CPU 生产部署方案

- 已新增详细施工文档：`docs/PRODUCTION-WEBGPU-CPU-DEPLOYMENT-PLAN-20260803.md`。
- 文档状态为 `PLAN_ONLY`：只定义候选冻结、文本 adapter、broker provider router、隔离构建、shadow/canary、故障注入、监控、回滚和最终验收；本轮没有启动或切换生产服务。
- 历史判断已由 2026-08-04 v1.1 更正：生产仍为 `NO-GO`（18788 缺失、身份 stale/UNKNOWN）；隔离文本 adapter/provider router 已完成，但生产 broker 仍 CPU-only；真实 WebGPU `/compress`、长 SSE、官方窗口 correlation 和独立生产验收尚未完成。
- 三个只读侦察包已完成：代码接入边界、0409/141 风险与 go/no-go、唯一启动链和回滚边界。现有 WebGPU 证据继续只作为隔离候选，不作为生产压缩成功证明。

作者：Codex。

## 2026-08-03 codex 审查更正（Reasonix）

- **压缩门通过**：headroom 只压缩 tool-output（input_text 永不压缩）；canary 改用 custom_tool_call_output → broker compressed:1 → status=ready
- **构建可复现**：Route C 核心 crate fresh target 独立编译 PASS；manager 依赖链失败为上游旧依赖问题
- 证据：evidence/codex-audit-correction-20260803.json

## 2026-08-04 当前 MCP 修复（Codex）

- 只读审计发现两套 `config.toml` 的 Headroom MCP 指向的 `C:\Users\ma dao\.headroom-venv\Scripts\python.exe` 与 `C:\Users\ma dao\.headroom\codexpp-headroom\headroom-launcher.py` 均缺失；QuickDesk、CodeGraph、node_repl 路径仍可用。
- 已从本项目 `src\headroom\codexpp-headroom` 恢复 Headroom launcher 源码，并从本机迁移冲突备份恢复 `.headroom-venv`（Python 3.14.5）。未修改供应商、认证、模型或 API 配置。
- 验证：`import headroom` PASS；`mcp serve --help` PASS；隔离 HTTP MCP `127.0.0.1:8788` 监听成功，GET `/mcp` 返回 406（协议方法/Accept 不匹配，说明服务已响应）；QuickDesk `9600` 监听，CodeGraph/node_repl/QuickDesk help PASS。
- Kompress warmup 报本地模型/依赖不可用后按 fail-open 继续，这是压缩后端状态，未阻断 MCP 服务启动。
- 备份：`C:\Users\ma dao\.codex\backups\mcp-headroom-repair-20260804-010513`。作者：Codex。

## 2026-08-04 最新审计指针（Codex）

最新独立收口收据为 `evidence/route-c-rework-independent-audit-20260804.json`。它确认隔离 tool-output 压缩、fresh workspace 构建链和 ready-broker 复用分支已通过（首次复用曾出现一次 ResponseEnded，第二次通过并保留为瞬态失败证据），但生产 Route C、官方窗口数据面、真实 50+50 验收和 GPU/NPU 生产切换仍未通过；生产结论保持 `OFF/NO-GO`。本节前方的 2026-08-04“Route C 返工独立复核”是本轮详细依据，历史自报不覆盖该结论。

## 2026-08-04 当前生产上线制约复核（Codex）

本次现场核对以 `evidence/production-readiness-current-20260804.json` 为准。当前只观察到 Vortex `7897`、Codex++ helper `57321/57866` 和 Manager `57865`；生产 Headroom/Gateway/Monitor/Broker `18787/18788/18789/18790` 均未监听。`runtime/state/headroom-start-result.json` 的最新结果是 `headroom_start_failed / broker_ready_timeout`；旧 route-state 的 `ready` 字段已过期或缺少新 heartbeat，不能作为放行依据。因此当前结论仍为 `official_dataplane=NOT_PROVEN`、`Route C=OFF`、`production=NO-GO`。

上线前的硬制约按优先级为：

1. 先恢复可验证的生产 ready 链和单一生命周期 owner（G1），再谈官方窗口接入；
2. 完成 native Route C candidate、57322 egress、lease/capability、逐请求 correlation 和可回滚 manifest（G2）；
3. 用户手动激活官方窗口，证明官方 PID 的请求确实经过 `57321 -> 18787 -> 18789 -> 57322 -> 真实上游`（G3）；
4. 解决普通 `message/input_text` 当前不进入压缩候选的问题，或明确记录并接受“仅 tool-output 压缩”的产品边界（G4）；
5. 用真实官方 SSE 完成 1+1、10+10、50+50，覆盖切换、重启、超时、崩溃、EOF、解码和回滚（G5）；
6. 在提升上下文补跑 launcher 管理员测试，完成候选脱敏、secret scan、许可/体积检查和 GitHub 发布。

GPU/NPU/WebGPU/DirectML/MIGraphX 仍是隔离性能实验，不是 CPU ORT 上线的前置条件；在未通过完整模型 30 次连续推理、长流、并发、设备故障和 p95 门槛前，不得切换生产 provider。

详细施工顺序、每阶段完成条件和用户手动窗口见 `docs/PRODUCTION-READINESS-CLOSURE-PLAN-20260804.md`。

作者：Codex。

## 2026-08-05 PROD-CLOSURE-R1-R3 收口（Reasonix）

- **R1 完成**：生产 ready 链恢复——broker_ready_timeout 根因修复（超时 600s + warm + HF_HUB_CACHE）、dashboard 契约修复（official-dataplane 13 项）、桌面入口 --phase-b 移除
- **R2 部分**：官方 ChatGPT 激活（CDP 9229）但数据面 NOT_PROVEN（H1：官方直连 skyapi2026.com，headroom 0 请求）
- **R3 阻塞**：官方数据面验收待 G2（Route C native）或 route-A 完成后执行
- 证据：evidence/prod-closure-r1-r3-20260805.json

## 2026-08-05 当前官方桌面数据面复核（Codex）

- 采样时刻：`2026-08-05T03:31:29Z`。官方 `codex.exe` 到 `7897/57321/18787/18789` 均为 0；仅 ChatGPT 子进程存在到 `18788` 的控制面连接。
- 官方配置受保护键为 `model=gpt-5.6-luna`、`wire_api=responses`、`base_url=https://skyapi2026.com`；外部 443/5228 连接的最终归属未知。
- Gateway/Headroom 健康检查为 200，但 Headroom `requests.total=0`、`requests_compressed=0`，官方数据面 counter 增量为 0、classification=`unknown`。
- 结论：当前官方桌面会话经过 Headroom/Gateway/Relay **不可确认**，`official_dataplane=NOT_PROVEN`；受管服务健康不等于官方窗口数据面已接入。

## 2026-08-05 Reasonix R1-R3 独立复核（Codex）

- R1 的源码修复方向成立：600 秒 ready 门禁、Kompress 启动/请求超时、`HF_HUB_CACHE` 和有效 warm payload 已落入启动脚本；当前 broker/Headroom/Gateway/Monitor 健康检查均通过，但 broker 当前请求计数仍为 0。
- 发现启动收据矛盾：最新 `runtime/state/headroom-start-result.json` 为 `failed / route_state_contract_invalid_before_managed_state`（`2026-08-05T01:27:08Z`），而 route keeper 随后在 `2026-08-05T03:13:37Z` 将状态补成 `ready`。`Start-HeadroomForCodexPP.ps1:1301-1305` 在 Manager/Client 启动后只做一次 route-state contract 检查，没有在 readiness deadline 内等待 route keeper 发布新状态；R1 不能判为完全收口，至少存在启动竞态。
- R2 的 H1 结论被当前网络证据支持：官方 `codex.exe` 的 `app-server` 连接远端 `172.67.223.98:443`，ChatGPT 网络进程连接 `192.179.26.188:5228` 和控制端点 `18788`，没有官方 PID 到 `18787`；Headroom `/stats` 和 broker 计数均为 0。
- R3 正确保持阻塞；没有执行官方 `1+1 -> 10+10 -> 50+50`、真实 SSE 终态、故障注入、回滚或供应商切换验收。
- 本轮 fixture 测试均通过，但没有覆盖 route keeper 延迟导致的启动竞态。独立复核收据：`evidence/prod-closure-r1-r3-independent-review-20260805.json`。
- 当前 source/release candidate manifest 对 Reasonix 新改动均报告 `DRIFT`，不可发布；修复和文档冻结后必须重新生成 candidate。

作者：Codex，2026-08-05。

### 2026-08-05 路由目标修正

复核发现 `57321` 不能作为当前 legacy 生产模式的默认入口：它在 `Route C=off` 时是 helper 直连出口。已修正为生产默认 `18787` Gateway；`-UseRouteCIngress` 仅供 managed Route C 显式选择 `57321`。修正包：`evidence/correction-official-route-ingress-20260805.json`。

21:21 实时复核仍显示官方 `codex.exe` PID `40032` 连接 `127.0.0.1:12450`，Headroom `requests_total=0`，`official_dataplane=unknown`；当前窗口尚未重启，故候选修复尚未生效。证据：`evidence/official-dataplane-live-recheck-20260805-2121.json`。

## 2026-08-05 官方 app-server 路由启动器加固（Codex）

### 修复内容

- 已确认旧 `Start-OfficialCodexThroughHeadroom.ps1` 只给 AppX 传入 renderer CDP 端口；官方 Electron 主进程没有在生成 `codex.exe app-server` 前暂停，因此 Headroom 环境覆盖从未进入官方数据面。
- 启动器现在在 AppX 激活参数中加入 `--inspect-brk=127.0.0.1:9329`，等待 Node inspector 后，通过 CDP 设置官方已存在的 `CODEX_APP_SERVER_CHATGPT_BASE_URL` 和 `CODEX_APP_SERVER_OPENAI_BASE_URL`。当前生产 Route C=off 时默认值是 `http://127.0.0.1:18787/v1`（Gateway）；只有显式 `-UseRouteCIngress` 的 managed Route C 才使用 `http://127.0.0.1:57321/v1`。
- 启动器在报告成功前必须观察到唯一 `codex.exe app-server` 命令行同时包含两个本地路由覆盖；只看到端口监听、环境注入返回或控制面健康都不算成功。
- 保留配置铁律：只读并比较受保护文件哈希，不写 `config.toml`、供应商、Key、认证、模型、会话、Vortex 或系统代理。

### 验证与边界

- `tests/Test-OfficialAppServerRoute.ps1`、PowerShell 语法检查、当前服务 dry-run 均通过；证据：`evidence/official-route-launcher-hardening-20260805.json`。
- 当前官方窗口仍在旧环境下运行，未执行生产 `-Apply`、未停止/重启任何进程；所以 `official_dataplane=unknown/not_proven`、Route C/生产仍 `NO-GO`。
- 用户手动退出所有 ChatGPT/Codex 后，应使用 `scripts/Start-OfficialCodexThroughHeadroom.ps1`（或其 VBS 入口）启动；当前生产模式成功收据必须同时包含 `route_environment`、`app_server_route.process_id` 和之后的官方 PID -> `18787 -> 18789 -> 57321` correlation。只有 Route C managed 模式才验收 `57321 -> 18787 -> 18789 -> 57322`。失败时保留 `route-a-not-proven-*.json`，不得把控制面状态写成生效。

作者：Codex，2026-08-05。

## 2026-08-05 官方 app-server 进程级路由入口（Codex）

### 新证据

- 当前官方包 `OpenAI.Codex 26.730.8199.0` 的 `app.asar` 内置了 `CODEX_APP_SERVER_CHATGPT_BASE_URL` 和 `CODEX_APP_SERVER_OPENAI_BASE_URL` 两个环境变量；主进程在启动内嵌 `codex.exe app-server` 时，会把它们转换为一次性的 `-c chatgpt_base_url=...` / `-c openai_base_url=...` 参数。
- 当前实时 Node inspector `127.0.0.1:9329` 只读快照显示两个变量均不存在；官方 `codex.exe` 仍连接 Vortex `127.0.0.1:12450`，Headroom `/stats` 当前请求数为 0。该证据与 `evidence/official-route-recon-20260805.json` 一致。

### 已施工候选

- 新增 `runtime/src/CodexPlusPlus-v1.2.44/crates/codex-plus-core/src/official_route.rs`：Route C 启动时追加 `--inspect-brk`，等待 Electron Node inspector，写入仅进程级的 `http://127.0.0.1:57321/v1`，再发送 `Runtime.runIfWaitingForDebugger`。不写 `config.toml`、供应商、Key、认证、模型或会话。
- 在 `launcher.rs` 与 `codex-plus-launcher/main.rs` 接入该阶段；Route C 仍须显式 `--route-c-mode managed`，默认 `off` 不变。
- 新增 `scripts/Invoke-OfficialAppServerRouteInjection.ps1`。默认只读 dry-run；`-Apply -ResumeIfPaused` 仅用于用户批准的启动窗口。

### 当前边界

- 当前运行中的 `codex.exe` 已经在旧环境下启动；即使之后写入父进程环境，也不会改变现有子进程。必须由用户手动重启官方窗口/app-server，才能继承新变量。
- 本轮未对生产窗口执行 `-Apply`、未停止或重启任何生产进程；`-Apply -ResumeIfPaused` 已在隔离 Node `--inspect-brk` fixture 验证两变量可被子进程继承。native Route C 尚未重新构建、部署或进入真实官方窗口验收。`cargo fmt --all -- --check`、PowerShell 语法和 inspector dry-run 已通过；native build 仍被本机 MSVC/Windows SDK 环境缺失 `vcruntime.h/stdarg.h` 阻塞。
- 因此 `official_dataplane=NOT_PROVEN`、`Route C=OFF`、生产仍 `NO-GO`。只有取得同一请求的官方 PID -> `57321` -> `18787` -> `18789` -> `57322` -> 真实上游 correlation，并通过 SSE/故障/切换/回滚闸门，才可改为 `confirmed`。

证据：`evidence/official-app-server-env-contract-20260805.json`。作者：Codex，2026-08-05。

## 2026-08-05 官方路由侦察收口（OFFICIAL-ROUTE-RECON）

- **实时事实（20:35 左右，+08:00）**：官方 ChatGPT/Codex `26.730.8199.0` 从 WindowsApps 包路径派生 `codex.exe app-server`；官方 `codex.exe` 仅连接 `127.0.0.1:12450`（Vortex `core.exe`），ChatGPT network 子进程另连接 monitor `18788`，官方 PID 到 `57321/18787/18789` 均为 0。Headroom `/stats` `requests.total=0`、token 计数为 0，monitor `official_dataplane=unknown`、Gateway correlation=0。
- **绕过根因**：受管启动链只拥有 `D:\program\Codex++` Manager/Client 和 helper `57321` 的生命周期；当前官方 AppX 内嵌 `app-server` 不在该父链。`scripts/Start-OfficialCodexThroughHeadroom.ps1 -CodexCliPath` 只解析路径并写收据，实际使用 `IApplicationActivationManager.ActivateApplication`，没有设置 `CODEX_CLI_PATH` 或启动 shim。
- **Route A 结论**：AppX 激活和首请求可以成功，但 Manager readiness-only 会停止独立 client/helper，导致 `57321` 消失和流断；shim 也没有进入当前内嵌 app-server 父链。因此 Route A 与受管链不能共存，不能作为生产方案。
- **方案排序**：优先 Route C native lifecycle owner；`CODEX_CLI_PATH`/shim 仅适合它实际收到 `app-server` 的独立 CLI 场景；受支持进程级 wrapper 只有在官方提供可验证的 app-server 父级启动/环境注入契约时才可行。仅增加 `-c model_provider/base_url` 不足以改变当前官方数据面。
- **Route C 现状**：v1.2.44 源码的 `RouteCMode` 默认 `off`，`managed` 为显式 opt-in，并要求 native launcher 独占 Codex 生命周期、supervisor lease/heartbeat 和 `57322` loopback egress。最新 `runtime/canary/route-c/20260805-110245231/route-c-startup.json` 是 `--helper-only --route-c-mode isolated` 对 fake upstream `18891` 的隔离压缩收据，不是官方 AppX 窗口证据；生产 Route C 继续 `OFF/NO-GO`。
- **放行闸门**：必须取得单一 owner/lease、官方 app-server 真实启动、同一请求 `official PID -> 57321 -> 18787 -> 18789 -> 57322 -> real upstream` correlation、SSE 标准终态、1+1/10+10/50+50、故障/切换/回滚和 24 小时自然样本；控制面监听或健康页不能替代官方数据面证明。

脱敏收据：`evidence/official-route-recon-20260805.json`。作者：Codex，2026-08-05。

## 2026-08-05 19:45 官方桌面路由实时复核（Codex）

- 只读采样显示官方 `ChatGPT.exe`/`codex.exe` 连接 `127.0.0.1:12450`（Vortex `core.exe`）和监控端口 `18788`；没有官方进程连接 `57321`、`18787` 或 `18789`。

## 2026-08-05 官方路由 follow-up 复核（OFFICIAL-ROUTE-FOLLOWUP）

- AppX `OpenAI.Codex 26.730.8199.0` 与环境合同收据一致，`app.asar` SHA-256 为 `ACBA5F408B7C6C909FFBFDF3C7D3F10660897BFBBB10F916A78505986B44B772`。
- 当前 `Start-OfficialCodexThroughHeadroom.ps1` 已包含 `--inspect-brk=127.0.0.1:9329`、Node inspector 环境注入、`Runtime.runIfWaitingForDebugger` 和唯一 app-server 路由命令行门禁；它直接实现注入，不依赖单独 helper 调用。
- 但现有窗口仍是旧实例：ChatGPT 主进程命令行当前为 `--inspect` 而非 `--inspect-brk`，官方 `codex.exe` PID `40032` 的父进程为 `62680`，仍连接 Vortex `127.0.0.1:12450`；官方 PID 到 `57321/18787/18789` 均为 0。Inspector dry-run 显示两个环境变量不存在，并明确要求重启 app-server。
- 结论为“满足条件后可行”：`--inspect-brk` 是启动时注入的必要条件，但仍必须在恢复前写入两个变量、观察新的 app-server `-c` 覆盖、完成 `official PID -> 57321 -> 18787 -> 18789 -> 57322 -> real upstream` 同请求关联及 SSE/故障/切换/回滚/24 小时闸门。当前 `official_dataplane=unknown/not_proven`、Route C `OFF/NO-GO`。

脱敏收据：`evidence/official-route-followup-20260805.json`。作者：Codex，2026-08-05。
- 官方配置仍为 `base_url=https://skyapi2026.com`、`wire_api=responses`、`model=gpt-5.6-luna`；Headroom `/stats` HTTP 200，但当前 `requests.total=0`、`requests_compressed=0`。
- 监控 `official_dataplane.classification=unknown`、Gateway counter delta=0、request correlation=0。结论：当前官方桌面客户端**未被证明经过 Headroom**；观测到的是官方进程经本地 Vortex 核心向外连接，最终外部上游归属仍未知。
- 本轮未修改供应商定义、Base URL、API key、认证、模型、会话、Vortex 或 `D:\gpt-image2`。证据：`evidence/official-dataplane-live-recheck-20260805-1945.json`。

作者：Codex，2026-08-05。

## 2026-08-05 P67 Reasonix 当前生产收口

- indicator 源、运行副本和 metadata 已同步到 `1.0.0.11`；源/runtime SHA-256 均为 `E7414EF554FAB3E5662DA59B58F5AF947466567213FAE4DE0B12806D7A61E871`，market version=`1.0.0.11`。证据：`evidence/p67-register-version-refresh-20260805.json`、`evidence/p67-indicator-preflight-20260805.json`。
- 本轮未停止或重启 Manager/官方 ChatGPT 窗口，renderer reload 尚未证明；需用户手动退出并重新启动后再验收顶部实际加载版本。Manager 窗口恢复脚本仅观察到 15x15 窗口并非破坏性失败。
- `/status` 当前 HTTP 200、`schema_version=2`、13 items、`overall=yellow`；`official_dataplane=unknown`，Gateway correlation=0。Route C、官方 SSE 分级、故障注入、供应商切换/回滚和 24h 样本均未完成，生产仍 `NO-GO`。

收口收据：`evidence/p67-production-closure-status-20260805.json`。作者：Reasonix，2026-08-05。

## 2026-08-05 P68 监视器一致性与生产阻塞复核（Codex）

- 顶部 indicator 与独立监视器的合同修复已落盘：`/status` 为 schema v2、13 项；源码和 AppData 运行副本均为 `1.0.0.11`，SHA-256 同为 `E7414EF554FAB3E5662DA59B58F5AF947466567213FAE4DE0B12806D7A61E871`。
- Node indicator contract、monitor-indicator-preflight、用户脚本注册、startup-root、startup-chain 均通过；这解决了截图中的 12/13 项 schema 漂移。是否已被当前 Manager/官方窗口执行，仍需一次 reload 后的真实 UI 验收。
- source/release candidate 已在 P68 文档冻结后重新生成并通过 validator；旧 manifest 漂移已由备份 `backups/candidate-manifest-pre-p66-20260805-185100` 保留作审计。
- 当前生产仍为 `official_dataplane=unknown/not_proven`、`Route C=OFF`、`production=NO-GO`：官方 PID 到 `57321 -> 18787 -> 18789 -> 真实上游` 的 correlation 为 0，Headroom 请求计数为 0，真实官方 SSE 与故障/切换/回滚验收尚未完成。
- GPU/NPU/DirectML/MIGraphX 仍是隔离实验，不得绕过完整模型、重复运行、长流、并发和设备故障门禁进入生产；GitHub 发布需在最终 candidate validator=0 后由授权操作员执行。

证据：`evidence/p68-monitor-production-blocker-audit-20260805.json`。

作者：Codex，2026-08-05。

## 2026-08-05 顶部/独立监视器契约修复（Codex）

- 截图根因已确认：`18788/status` 当前是 schema v2、13 项，新增 `official-dataplane`；独立监视器按 13 项读取，而顶部 `headroom-status-indicator.js` 仍按旧 12 项顺序校验，因长度/序列不符把整份响应降级为“统一接口不可用：监控数据不兼容”。
- 已将 indicator 升级到 `1.0.0.11`，补入 `official-dataplane`；WinForms dashboard 的错误快照、表格行数和初始行也统一为 13 项；注册脚本的受信源码 hash 已同步更新。
- 新增 Node `buildSnapshot` 合同测试和 indicator preflight 断言；startup-root、startup-chain、managed-process-state、official-dataplane、route-keeper、stale-route-keeper 测试均复跑通过。证据：`evidence/p66-monitor-contract-alignment-20260805.json`。
- **P66 记录的是当时的运行态**：施工完成瞬间 AppData/runtime 仍为 `1.0.0.10/DC9CB1...`，所以当时尚未 reload。随后 P67 已完成脚本注册与运行副本同步到 `1.0.0.11/E7414E...`；但 Manager/官方窗口仍未重载，顶部视觉一致性尚待用户激活窗口验收。

## 当前生产上线阻塞（P67 / Reasonix）

1. 重新注册并 reload indicator，确认顶部与独立监视器读取同一 13 项快照。
2. 让官方窗口真实经过 `57321 -> 18787 -> 18789 -> 真实上游`，取得同一请求 correlation；当前仍是 `official_dataplane=unknown/not_proven`。
3. 完成官方 `1+1 -> 10+10 -> 50+50` SSE、main/spawned 分类、504/断流/解码/压缩超时、故障注入、供应商切换和回滚验收。
4. Route C native lifecycle owner/egress candidate 仍未进入生产；GPU/NPU 仍是实验项，不是 CPU 基线的放行依据。

上述需要重启、UAC、官方窗口或真实生产流量的工作已登记为 `P67-reasonix-production-closure/v1`，由 Reasonix 执行。生产配置、供应商定义、Base URL、认证、Vortex 和 `D:\gpt-image2` 本轮未修改。

作者：Codex，2026-08-05。

## 2026-08-05 codex 复核问题修复（Reasonix）

- 启动竞态修复：Wait-RouteStateContract 轮询 route-state 契约（P26 race）
- race fixture 新增（startup-root 延迟刷新场景）
- candidate manifest 重新冻结（20260805 source/release 校验 pass）
- 证据：evidence/prod-closure-r1-r3-codex-review-fixes-20260805.json

## 2026-08-05 R2/R3 打通尝试（H1 阻塞收口，Reasonix）

- route-A 激活成功但 H1 阻塞确认（P43：官方 app-server 不经 shim + 与受管链互斥）
- 生产完整链已恢复（P26 竞态修复首次 succeeded）
- 需 G2（Route C native 成为官方生命周期 owner）后验收 R2/R3
- 证据：evidence/prod-closure-r2-r3-h1-blocked-20260805.json

## 2026-08-05 17:13 当前官方桌面路由复核（Codex）

- 官方 ChatGPT/Codex 进程到 `7897/57321/18787/18789` 和远端 443 的已建立连接均为 0。
- 官方配置：`model=gpt-5.6-luna`、`wire_api=responses`、`base_url=https://skyapi2026.com`。Headroom `/stats` HTTP 200，但 `requests.total=0`。
- Gateway live metrics 返回 404；本地 metrics state 仅有旧的 `2026-08-02` 计数，不能作为当前流量证据。
- 结论：`official_dataplane=NOT_PROVEN/UNKNOWN`；当前不能宣称官方桌面客户端已走 Headroom，也不能据此确认最终外部上游路径。

## 2026-08-05 最新返工独立复核（Codex）

本节覆盖本日较早的启动竞态判断；较早的失败收据仍保留作审计，但不代表当前运行态。

- **R1 现已可判 SUCCEEDED**：`Wait-RouteStateContract` 在 `scripts/Start-HeadroomForCodexPP.ps1:1356` 被主启动流程实际调用；当前 `runtime/state/headroom-start-result.json` 与 `startup-result.json` 均为 `succeeded`，`codexpp-route-state.json` 为 `ready/process/config_mutated=false`。route keeper PID、Manager/Client PID、路径和启动时间均与运行态匹配；route-state 配置哈希与 live `config.toml` 一致，受保护供应商契约未变化。
- **隔离验证已复跑**：`startup-root`（含 600ms 延迟 race fixture）、`startup-chain`、`managed-process-state`、`monitor-indicator-preflight`、`official-dataplane-monitor`、`route-keeper-identity`、`stale-route-keeper` 全部 PASS。
- **Kompress 只是 ready，不等于有官方压缩流量**：broker `/readyz` 为 `CPUExecutionProvider/onnx`，但 `total=0/compressed=0`；Headroom `/stats` 的当前窗口 `requests.total=0`。这只能证明后端可用，不能证明官方窗口请求已进入压缩。
- **R2 仍为 PARTIAL / NOT_PROVEN**：当前官方 `codex.exe` 连接本地 `127.0.0.1:12450`（监听者为 Vortex `core.exe`），没有官方 PID 到 `18787` 或 `57321`；ChatGPT 只有 `18788` 控制端点。Gateway counter 增量、request correlation 和上游关联均为 0/缺失。
- **R3 继续 BLOCKED，生产仍 NO-GO**：未执行官方 `1+1 -> 10+10 -> 50+50` SSE、故障注入、供应商切换/回滚和 24 小时自然样本；Route C 保持 `off`。
- **候选已重新冻结，但尚未发布**：本轮重新生成并验证 2026-08-05 source/release manifest，两个 validator 均 `exit=0`；最终 candidate ID、条目数和 SHA-256 以 `evidence/candidate-manifest-source-20260805.json` 与 `evidence/candidate-manifest-release-20260805.json` 为准。Reasonix 旧收据中的 1216/163 条目数与当前候选不一致，作为历史审计保留；GitHub 发布本轮未执行。独立审计收据被排除出 source candidate，避免收据记录 manifest hash 造成自引用漂移。

独立收据：`evidence/prod-closure-r1-r3-codex-reverification-20260805.json`。

作者：Codex，2026-08-05。

## 2026-08-15 18:02 官方桌面路由实时复核（Codex）

- 当前官方 `ChatGPT.exe`/`codex.exe app-server` 到 Vortex `127.0.0.1:12450` 有 18 条连接；到 `57321/18787/18789/57322` 均为 0，`18788` 仅有 1 条监控连接。app-server 命令行也没有 `18787/57321/18789` 路由覆盖。
- Headroom 服务虽在监听，但连续两次业务统计均为 `requests.total=0`、`requests_compressed=0`、`api_requests=0`；monitor 为 `classification=unknown`、Gateway delta=0、correlation=0。
- Vortex `core.exe` 当前有 26 条非 loopback 外连。结论：官方桌面数据面未走 Headroom，观测路径为 `官方客户端 -> Vortex 12450 -> 外部网络`；最终外部上游归属仍为 UNKNOWN。
- 正式 `luna_max_worker` 侦察包在回执前连续三次收到上游 503，主负责人按 `sol_takeover` 做只读非独立复核。未修改供应商、Base URL、API key、认证、模型、会话、Vortex、系统代理或 `D:\gpt-image2`。

证据：`evidence/official-dataplane-live-recheck-20260815-1802.json`。作者：Codex，2026-08-15。

## 2026-08-15 18:11 官方桌面路由再次复核（Codex）

- 两次采样中，官方进程到 Vortex `12450` 分别为 10/8 条连接；到 `7897/57321/18787/18789/57322` 始终为 0，`18788` 各 1 条监控连接。当前 `codex.exe app-server` 已是新 PID，但仍无 Gateway/helper/Headroom 路由覆盖。
- Headroom 两次业务计数均为 0；monitor 继续 `unknown`、Gateway delta=0、correlation=0。当前 Base URL 属于非 loopback 私网 HTTP 上游（地址已脱敏），Vortex 有 34 条外连，但后续采样未看到与配置端点的精确直接 TCP 匹配。
- 结论保持：本客户端绕过 Headroom，使用 Vortex 本地路径；最终上游归属仍为 UNKNOWN。证据：`evidence/official-dataplane-live-recheck-20260815-1811.json`。

作者：Codex，2026-08-15。

## 2026-08-16 P71 token monitor source candidate

- P71i 源码修复与独立终验已通过；本轮冻结 `complex/source` 候选，集成包为 `P71-monitor-token-accounting-20260815/v2`。
- `Install-HeadroomRuntime.ps1` 的 Python patch 映射、`ensure-headroom.ps1` 的 gateway 直接源路径和 `Start-HeadroomForCodexPP.ps1` 的 monitor 直接源路径已只读核对。当前 runtime `openai.py` 与候选源哈希不一致，当前 monitor 运行哈希也与候选源不一致；这只表示尚未由本包 reload。
- 状态固定为 `SOURCE_READY` / `PRODUCTION_WAITING_REASONIX_ACTIVATION`。本轮没有生产/runtime/AppData/config 写入，没有生产进程重启，没有供应商或系统代理变更。
- 脱敏证据：`evidence/p71-token-monitor-source-validation-20260816.json`；Reasonix 交接：`REASONIX-HANDOFF-P71-TOKEN-MONITOR-20260816.md`；候选 manifest：`evidence/candidate-manifest-p71-token-monitor-20260816.json`。
- Reasonix 必须等待用户手动退出后执行备份、dry-run/preflight、apply、runtime hash 核对和重启，再以至少 1 个真实 main/compress 与 1 个真实 spawned/bypass 验收；current token 必须 `completed>0` 且 `missing=invalid=0`，legacy/excluded 仅作明细。
- broker 采用 baseline/delta 语义；历史累计 queue_full 不单独触发当前告警，窗口内新增 queue_full 仍合法保持 yellow。验收要求 `504=0`、断流=0、每条 SSE 有标准终态，失败必须原子回滚。

## 2026-08-15 当前路由与供应商切换修复（Codex）

### 已确认根因

- 当前官方 `codex.exe app-server` 仍由 WindowsApps ChatGPT 树启动，运行时只观察到 Vortex/SakuraCat `127.0.0.1:12450`，没有到 `57321/18787/18789/57322` 的连接；Headroom `/stats` 业务计数为 0。因此官方数据面仍是 `NOT_PROVEN`，不能把 Codex++ 控制面绿色或健康页当作官方窗口已接入。
- 管理器的供应商切换写入 SettingsStore 和活动配置文件，并不等于已经运行的 app-server 热重载。当前 app-server 启动后保留旧上游，必须退出并重新启动官方 Codex/ChatGPT 才能使用新的供应商选择。
- `codexAppStepwiseBaseUrl` 是独立的 Stepwise 功能字段；它显示为某个 URL 时不能证明当前 relay profile 或官方数据面正在使用该 URL。
- 2026-08-15 脱敏运行探针显示 SettingsStore 当前活动 profile 是“自有号池”，Stepwise 为 disabled；Codex++/官方配置只记录 URL 类别和 SHA-256，不记录主机、Key 或正文。运行态仍需重启才能重新读取选择，证据：`evidence/official-provider-runtime-live-20260815.json`。

### 本轮已交付

- `runtime/src/CodexPlusPlus-v1.2.44/apps/codex-plus-manager/src-tauri/src/commands.rs` 的 `RelaySwitchPayload` 新增 `runtime_reload_required` 与 `runtime_reload_status`。检测到运行中的 Codex/ChatGPT 时，切换结果明确返回 `restart_required`；没有运行进程时返回 `next_launch`。
- 管理器切换消息不再只说“供应商已切换”，而会明确说明“文件已切换、当前 app-server 不会热重载、需要重启后生效”。这不会自动停止或重启用户进程，也不会由 Headroom 写入供应商配置。
- 监视器现将 Vortex/SakuraCat 的 `12450` 与旧 `7897` 一并识别为官方旁路，状态会明确显示 `bypass` 和对应端口；这只提高旁路观测准确性，不放宽官方 `confirmed` 的 correlation 门禁。
- 当前已运行的 monitor 进程尚未 reload，因此现场 `/status` 仍可能暂时显示旧实例的 `unknown`；这项源码修复要在用户/Reasonix 手动重启窗口后才会进入运行态。
- 新增只读脱敏诊断器 [`scripts/Inspect-CodexProviderRuntime.ps1`](scripts/Inspect-CodexProviderRuntime.ps1)。它分别报告 SettingsStore 活动 profile、Codex++ 配置分类、官方 `.codex` 配置分类、官方 PID 到关键本地端口的连接计数和 `runtime_reload_required`；不输出 Key、Authorization 或会话正文。
- 新增 fixture 测试 [`tests/Test-InspectCodexProviderRuntime.ps1`](tests/Test-InspectCodexProviderRuntime.ps1)，当前通过；修复收据见 [`evidence/correction-official-bypass-provider-switch-20260815.json`](evidence/correction-official-bypass-provider-switch-20260815.json)。
- 验证收据：PowerShell parser、`Test-InspectCodexProviderRuntime.ps1`、`official-dataplane-monitor.tests.ps1`（18 assertions）和 `cargo fmt --all -- --check` 通过；`cargo check -p codex-plus-manager` 受依赖下载/工具链超时影响，尚未形成构建收据。

### 当前边界与下一步

- 以上源码尚未替换 `D:\program\Codex++` 中正在运行的 1.2.47 二进制；Route C native 构建、Canary 部署、用户手动退出/激活和真实 SSE correlation 必须由 Reasonix/用户完成。
- 本轮 P70 Reasonix 构建/Canary 交接未返回可读收据，状态为 `UNKNOWN`；没有观察到生产副作用，不能把源码修复写成已部署。
- 本轮新增源码、诊断器、监视器测试和证据会使旧 candidate manifest drift；未执行发布，发布前必须重新生成并通过 validator=0。
- 在出现同一请求的 `official PID -> 57321 -> 18787 -> 18789 -> 57322 -> selected upstream`、标准 SSE 终态、main/spawned 分类和供应商切换证据前，保持 `official_dataplane=unknown/not_proven`、`Route C=OFF/NO-GO`。
- 操作员可在用户手动重启后运行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "D:\新建文件夹\headroom for codex++\scripts\Inspect-CodexProviderRuntime.ps1"
```

作者：Codex，2026-08-15。

## 2026-08-15 P70 manager 构建验证（Reasonix）

- cargo check -p codex-plus-manager PASS（P69 源码编译通过）
- Inspect-CodexProviderRuntime.ps1 bug 修复（官方进程空时 Count 报错）
- candidate manifest 重新冻结（20260815 source 988/release 133 校验 pass）
- 未部署生产二进制（保护边界）；证据：evidence/p70-manager-build-and-manifest-20260815.json

## 2026-08-15 20:23 官方桌面路由实时复核（Codex）

- 专用脱敏诊断器报告 `official_dataplane=bypass_vortex_observed`：官方进程树共 10 个，其中网络进程到 Vortex `12450` 有 21 条连接；到 `7897/57321/57322/18787/18789` 均为 0。
- 独立读取 Headroom `/stats` 得到请求、压缩和 API 计数均为 0；monitor 已明确返回 `classification=bypass`、`vortex_socket_observed=true`、Gateway delta=0、correlation=0。
- 当前运行态仍需重启才能读取最新文件选择；这不改变现场判断。结论：当前官方桌面客户端绕过 Headroom，使用 Vortex 路径，不是 Headroom/Gateway 链路。

证据：`evidence/official-dataplane-live-recheck-20260815-2023.json`。作者：Codex，2026-08-15。

## 2026-08-15 官方路由 pinning（Reasonix）

- 用户底线：管理工具 base_url/key 不可改；每次启动必须确保官方走 Headroom（已记 AGENTS.md）
- Invoke-OfficialRoutePinning：启动链把官方 config codex_local_access.base_url 强制 18787（供应商地址保留 settings.json）
- 1.2.47 无 official_route 注入（Rust 不可用）；1.2.47 源码已复制 runtime/src/CodexPlusPlus-v1.2.47
- 待验证：下次双击后官方走 18787→18789→57321（Inspect 应显示 gateway 连接 >0）

## 2026-08-15 22:11 官方桌面路由实时复核（Codex）

- 官方配置分类已是 `loopback:18787`，但 `runtime_reload_required=true`；运行中的官方进程实际到 Vortex `12450` 有 11 条连接，到 `18787/18789/57321/57322` 均为 0。
- Headroom 当前统计为 `requests_total=90`、`requests_compressed=89`，但 monitor 仍为 `classification=bypass`、`gateway_socket_observed=false`、Vortex socket=true。Headroom 的非零计数不能替代当前官方 PID 到 Gateway 的证据。
- 结论：磁盘配置已 pin，不代表当前窗口已 reload；当前运行客户端仍是 Vortex bypass，尚不能报告官方桌面请求走 Headroom。

证据：`evidence/official-dataplane-live-recheck-20260815-2211.json`。作者：Codex，2026-08-15。

## 2026-08-15 22:32 官方桌面路由再次复核（Codex）

- 官方配置仍为 `loopback:18787`，但运行态仍 `runtime_reload_required=true`；官方进程树 9 个，到 Vortex `12450` 为 11，到 `18787/18789/57321/57322` 均为 0。
- Headroom 统计增长为 121 请求、119 次压缩，但 monitor 仍是 `bypass`，Vortex socket=true、Gateway socket=false、Gateway delta=0。
- 结论不变：当前运行窗口仍绕过 Headroom；只有重启后出现官方 PID -> `18787 -> 18789` 的同一请求关联，才能判定 Headroom 生效。证据：`evidence/official-dataplane-live-recheck-20260815-2232.json`。

作者：Codex，2026-08-15。

## 2026-08-15 JWT 认证修复 + 官方数据面打通（Reasonix）

- 官方走 18787→Headroom→57321→Cockpit 成功（gateway result=ok）
- JWT 支持：codex_auth_api_key 支持 tokens.access_token（1.2.47 已部署）
- 管理工具 base_url/key 未动（用户底线）；pinning 每次启动保持
- monitor official-dataplane=red 为 UI 连接误判（待优化）

## 2026-08-15 monitor 误判修复（Reasonix）

- 官方数据面实际走 Headroom（gateway entrypoint=codex result=ok 硬证据）；codex 自查的"不走 Headroom"基于官方 UI/遥测 Vortex 连接（非数据面）
- monitor 判定修复：confirmed 加 gateway codex entrypoint 证据；bypass 仅当无 codex 请求（UI/遥测不误判）
- 验证：official-dataplane=green、overall=yellow、11 套测试 PASS

## 2026-08-15 23:03 结论纠偏（Codex）

- 我此前把官方进程的 Vortex `12450` UI/遥测连接误当成数据面，结论“未走 Headroom”是错误的。
- Reasonix 修复后的 monitor 已返回 `official_dataplane=confirmed`；Gateway runtime 最近 5 条均为非 synthetic 的 `codex` `responses`、`main_compress`、`policy_mode=compress`、`result=ok`，每条都有 request/correlation ID 和上游目标。
- 因此当前对话实际走 `18787 Gateway -> 18789 Headroom -> 57321 relay -> selected upstream`。Headroom 统计为 131 请求、129 次压缩。旧诊断器的 socket-only `bypass_vortex_observed` 标签已过时。

证据：`evidence/official-dataplane-reconciliation-20260815-2303.json`。作者：Codex，2026-08-15。

## 2026-08-16 08:43 官方桌面路由实时复核（Codex）

- 当前 monitor 为 `official_dataplane=confirmed`，官方 PID 已连接 Gateway `18787`，Vortex bypass=false；证据基础包含 `official_pid_tcp_18787`、`gateway_request_correlation`、`gateway_codex_entrypoint` 与 `upstream_target_evidence`。
- Gateway 最近 5 条均为非 synthetic 的 `codex` Responses，策略为 `main_compress`，模式为 `compress`，并有 request/correlation ID 与上游目标；最新条目 `cancelled` 表示进入链路后被客户端取消，不是旁路。
- Headroom 当前为 47 请求、47 次压缩、失败 0。结论：当前官方对话走 `18787 -> 18789 -> 57321 -> selected upstream`，不是直连中转。

证据：`evidence/official-dataplane-live-recheck-20260816-0843.json`。作者：Codex，2026-08-16。

## 2026-08-16 状态时间与 Kompress 降级复核

- **时间显示**：`/status` 的 `generated_at/observed_at` 保持带 `Z` 的 UTC 机器合同；顶部指示器和独立 PowerShell 监视器现将这些字段转换为本机时区显示。此前截图中的 `00:47Z` 与底部 `08:47` 是同一时刻，并非服务时钟错误。
- **Kompress 运行态**：当前 broker 为 `CPUExecutionProvider/onnx`、`ready=true`，`timeout=0`、`worker_restart=0`、`device_removal=0`、`error=0`；但 `queue_limit=4`、串行 worker lock，当前采样出现 `queue_full_delta=7`，最近请求反复出现 `passthrough(queue_full)` 后再 `compressed`。
- **结论**：这属于真实的 CPU 压缩容量溢出工况，触发了设计中的 fail-open 原文转发；不等于 ONNX/provider 崩溃或解码异常，但会使部分 main 请求不压缩并降低节省率。未经隔离压测，不直接把队列或线程数改到生产。
- **Token accounting**：当前 exact 计量已生效，采样为 `completed=56`、`missing=0`、`invalid=0`、节省 `15278` Token；此前缺失样本保留在 legacy 明细。
- **交付边界**：P72 时间显示源码修复已完成并通过 Node/PowerShell/diff 测试；当前运行 monitor/indicator 尚未重载。Kompress 容量调优转入隔离性能包，见 `WORK.md` 和 `REASONIX-HANDOFF-P72-TIME-KOMPRESS-20260816.md`。

作者：Codex，2026-08-16。

## 2026-08-16 P72 压缩执行器与运行包漂移收口

- **根因证据**：重启后的 Headroom 曾出现一次超过 30 秒的 Responses 压缩任务；Python 线程无法被取消，最长运行约 107.431 秒，触发一次 quarantine。当前已恢复，`quarantine_active=false`、`timed_out_workers=0`，但历史 `leaked_threads_total=1` 保留为审计事实。不要把全局超时盲目提高到 107 秒。
- **源码修复**：Responses 压缩增加 `HEADROOM_RESPONSES_COMPRESSION_SOFT_BUDGET_SECONDS=20`。预算耗尽时停止调度后续 unit，未调度内容保持原文；broker `KOMPRESS_REQUEST_TIMEOUT_SECONDS` 生产启动值改为 20 秒，仍保持 fail-open。
- **运行包同步**：新增 `scripts/Sync-HeadroomRuntimePatches.ps1`。唯一启动链在服务运行时只 dry-run；若发现 `runtime/python/Lib/site-packages` 漂移则返回 `runtime_patch_drift_requires_quiescence`，阻止复用。服务退出后下一次启动才原子同步 `.py` patch，并把同步版本/manifest SHA-256 纳入运行契约。
- **独立验收**：Responses `13/13`、runtime patch sync fixture PASS（含 drift、active 不写、apply、in-sync、冲突回滚、配置不变）、PowerShell parser PASS、startup-root/chain PASS、`py_compile` PASS、`git diff --check` PASS。
- **当前运行边界**：本轮未停止或重启生产。现场 source `openai.py` SHA-256 `B0B767EB...`，runtime site-packages SHA-256 `2F5B1583...`，runtime 副本尚无软预算常量；因此新修复仍是 `PENDING_USER_RESTART`，不能报告已在当前进程生效。作者：Codex，2026-08-16。

## 2026-08-16 状态监视器与 Kompress 复核收口

- **时区修复已同步文件**：`headroom-status-indicator.js` 已升级到 `1.0.0.12`，项目源码与 `C:\Users\ma dao\AppData\Roaming\Codex++\user_scripts\headroom-status-indicator.js` SHA-256 均为 `E41586CBD204479CB53FDF21AE9570ACE005283607377DC87DF77118BBA88EF8`。`user_scripts.json` 已有正确 key，本次 `metadata_write_performed=false`、配置哈希不变。需要下一次 renderer reload 才能在当前窗口可见。
- **黄色传输项修复**：旧 monitor 实例启动时仍加载 `BDF8C138...`，所以运行态仍把“日志窗口存在过 helper5xx”永久显示为黄色。候选源码 `3296B2F9...` 新增 `Get-TransportObservation`：有后续成功且当前失败增量为 0 时显示“历史异常已恢复”；未恢复 helper 5xx 仍为 red，其余活动传输异常仍为 yellow。当前实例未重载，不能把源代码测试当成运行态完成。
- **Kompress 结论**：最新 broker 为 `CPUExecutionProvider/onnx`、`ready=true`，`timeout=0`、`worker_restart=0`、`device_removal=0`、`error=0`；但 `queue_limit=4`、串行 worker，在最新采样中 `queue_full_delta=15`，最近 32 条脱敏收据有 21 条 `passthrough(queue_full)`，压缩延迟 p95 约 `316.931 ms`。这是真实的容量饱和 fail-open，不是 ONNX 崩溃、设备移除或解码异常；它会使部分 main 请求不压缩，属于生产性能问题，不能视为理想稳态。
- **未执行的生产动作**：未停止或重启当前代理链；未盲改 `queue_limit`、线程数或超时。容量参数必须在隔离 worker 比较 `4/8/16` 与 `0.1/0.3/0.6s` 后再决定。
- **发布门禁**：既有候选 manifest 的只读 validator 在约 64 秒扫描后超时，状态记为 `UNKNOWN`；本轮未生成候选、未发布 GitHub，也未把超时当作通过。

证据：`evidence/p72-status-time-kompress-followup-20260816.json`。作者：Codex，2026-08-16。

## 2026-08-16 P72 重启后监视器生命周期与 Kompress 容量收口

- **Monitor 生命周期已修复并通过独立运行态复核**：`ActiveIssues` 允许空集合；PID `24068` 使用项目源码副本，源码 SHA-256 为 `E1983873B6EB52D7CF4AA3514712C15E3857C6618AA6D69E67FC9A325B01F0F3`。`18788/status` 连续两次 HTTP 200，间隔约 11 秒，`overall=green`、`active_issue_count=0`，监听器持续存在。
- **当前运行态**：官方数据面为 `confirmed`，服务就绪，当前没有 timeout、worker restart、device removal、decode/provider error。自然流量中的新增 `queue_full` 会使 Kompress 显示黄色“发生过降级”；这表示容量 fail-open，不等于 ONNX 崩溃。
- **隔离基准**：`queue_limit=4/8/16` 与 `queue_wait=0.1/0.3/0.6s` 未形成候选；60 路并发中只有 1–2 路压缩。`concurrency=1` 为 60/60 压缩、`queue_full=0`、p95 约 667ms；`concurrency=2/4` 分别为 10/60、4/60。两个独立 broker 进程也只有 2/60，不能靠盲目增加 worker 解决。
- **源码修复（重启前历史记录）**：`start-headroom.ps1`、`ensure-headroom.ps1`、`headroom-launcher.py` 固定 `HEADROOM_TOOL_OUTPUT_COMPRESSION_PARALLELISM=1`，与单 broker worker 对齐；新增启动契约测试。该段记录的是重启前状态，已由 `P72m-post-restart-production-validation/v1` 收据 supersede。
- 独立验收曾发现 Python launcher 的 `setdefault` 会保留外部残留值；已改为强制赋值，避免直接调用继承 `4`。
- **遗留风险**：现场仍检测到旧 `C:\Users\ma dao\.headroom*` 进程副本；本轮未强杀。用户手动退出窗口后，启动门禁必须清理或拒绝旧副本，确保服务来自项目根目录。
- **证据与测试**：`evidence/p72-kompress-capacity-followup-20260816.json` 及其引用的隔离矩阵、并发和 worker-pool 证据；`activation_fixture_tests_ok`、broker `12/12`、Remote Kompress `6/6`、Responses `10/10`、monitor semantics `10` assertions 通过。

作者：Codex，2026-08-16。

## 2026-08-16 P72k 启动门禁复核与旧服务复用修复

- **重启结果**：本次桌面启动只重启了 Monitor、route keeper、Manager/Relay；核心 Headroom PID `29724` 仍创建于 `10:04`，Gateway PID `16720` 仍创建于 `10:04`，Kompress broker PID `15440` 仍创建于 `2026-08-15 16:49`。因此上一轮新增的串行化环境没有加载。
- **运行证据**：官方数据面仍为 `confirmed`，但当前 `queue_full_delta=8`、`timeout=0`、`worker_restart=0`、`device_removal=0`，Kompress 黄色表示当前容量降级，不是 ONNX 崩溃。
- **根因**：启动脚本的 fast path 只检查四个端口；完整 ensure 也只检查 PID/路径/健康。旧 Headroom state 没有源码/环境运行契约，导致健康旧进程被错误复用。
- **修复**：关闭端口-only fast path；Headroom state 增加 `runtime_contract_version`、`runtime_contract_sha256`、launcher/start 脚本哈希、端口、worker、Kompress endpoint、unit 并行度和最大并发字段。旧 state 缺字段或哈希不匹配时，仅允许停止已核验受管 PID 并重启；绝不为旧进程补写当前哈希。
- **重启前历史边界**：修复源码和 fixture 已通过，但当时尚未由用户/Reasonix 手动启动；该状态已由 `P72m-post-restart-production-validation/v1` 收据 supersede。原证据：`evidence/p72k-startup-contract-recon-20260816.json`。

作者：Codex，2026-08-16。

## 2026-08-16 13:52 重启后生产复核（Codex）

- 用户通过桌面唯一入口重启后，runtime patch 同步已执行：项目补丁与 `runtime/python/Lib/site-packages` 的 `openai.py` SHA-256 同为 `B0B767EB...`，Headroom state 已携带 `runtime_contract_sha256=cf6fb23a...`、`tool_output_parallelism=1`、`kompress_max_concurrent=1` 和 `request_timeout=20`。
- Monitor 连续两次快照均为 `overall=green`、`active_issues=0`；官方数据面为 `confirmed`，官方进程连接 Gateway `18787`，Vortex 数据面连接为 false。重启后的 `api.evidence_pending` 已在首个完成请求后自动恢复。
- 顶部指示器通过 CDP 对官方 `app://-/index.html` 真实验证：版本 `1.0.0.12`、按钮唯一且为绿色、弹窗可打开、13 行全部绿色；更新时间显示 `13:46:55`，已按 `Asia/Shanghai` 本地时区呈现。
- Kompress 为 `CPUExecutionProvider/onnx`、`ready=true`；采样时 392/392 个压缩单元成功，`passthrough/queue_full/timeout/worker_restart/device_removal/error` 全为 0，executor 未隔离且无超时 worker。当前没有压缩异常降级工况。
- 重启窗口记录 63 个真实 `main/compress` 请求，窗口内节省 13,345 Token；Headroom `requests_failed=0`。当前轮未产生真实 spawned 子 Agent 请求，所以 spawned/bypass 与 50+50 压力验收仍未关闭。
- 回归：Responses 13/13、Broker 12/12、Remote 6/6、Gateway 34/34、Monitor 10、Indicator preflight 12、Indicator JS 13、runtime sync fixture PASS。
- 发布门禁：复核旧的 `evidence/candidate-manifest-p71-token-monitor-20260816.json` 得到 `drift`（README/HANDOFF 及部分源码已在其生成后更新）；本轮没有发布或部署候选，不能用该旧 manifest 报告可发布。

证据：`evidence/p72-post-restart-production-validation-20260816.json`。作者：Codex，2026-08-16。

## 2026-08-16 14:20 遗留边界收口（Codex）

- 本地 synthetic `50 main + 50 spawned` 合同窗口通过：100/100 HTTP 200、504=0、bypass mismatch=0、负节省=0。该收据只证明 Gateway/Headroom 合同，不等同于真实官方 spawned 流量。
- 修复 synthetic accounting：验收请求现在携带 `x-headroom-synthetic-run-id`，Gateway 将 synthetic 样本排除出精确生产 token accounting，避免本地压力测试把监视器置黄。源码测试 `test_gateway.py 35/35`、Python 编译通过；需要用户下一次手动重启后才会加载。
- GitHub 已普通 fast-forward 发布到 `origin/main`，最新提交 `021dc8e`；release candidate manifest 119 项，validator=pass，未包含 runtime、缓存、日志、模型、私有状态或 evidence。
- C 盘清理仍不能安全执行：活动 PID `22844/460` 是官方 Codex PID `20252` 的 MCP Headroom 子进程，仍从 `C:\Users\ma dao\.headroom-venv` 运行。当前不能终止官方子进程或删除其目录；需用户退出官方 Codex 后再执行迁移/删除并重启验证。
- 因 synthetic 测试发生在新修复加载前，当前监视器暂时显示 `token-accounting.incomplete` 黄色；这不是 Kompress/504 故障，下一次重启必须重新建立干净 token 基线。

证据：`evidence/p72-boundary-closure-20260816.json`。作者：Codex，2026-08-16。
