# Headroom for Codex++ 生产上线收口计划

日期：2026-08-04
作者：Codex
依据：`evidence/route-c-rework-independent-audit-20260804.json`、`evidence/production-candidate-audit-20260804.json`、当前监听器快照和项目规则 `AGENTS.md`

## 当前结论

当前项目是“隔离 Route C 和 CPU Kompress 已具备验证基础，生产数据面尚未上线”。不能把 `57321`、健康页、route-state 或 Codex++ Manager 状态单独当作 Headroom 生效证据。

当前现场：

- `57321/57865/57866` 和 Vortex `7897` 可见；`18787/18788/18789/18790` 当前未监听。
- 官方 Codex/ChatGPT 数据面仍未证明进入 `57321 -> Gateway -> Headroom -> upstream`。
- 隔离 Canary 已证明 CPU Kompress tool-output 路径可执行；普通 Responses `message/input_text` 当前不会压缩。
- fresh `cargo check/build/clippy` 已通过；完整 workspace 测试还缺少允许 `requireAdministrator` 测试二进制启动的提升上下文。
- WebGPU/NPU/DirectML/MIGraphX 仍是实验路径，不作为当前生产后端。

## 上线阻塞因素

### H1. 官方窗口没有可靠进入 Headroom 数据面（硬阻塞）

官方窗口当前仍可能由 Vortex `7897` 处理；没有同一请求的官方 PID、`57321`、Gateway correlation、Headroom、egress 和真实上游证据。Route C native 源码和隔离 Canary 不等于官方窗口已接入。

**必须解决：** Codex++ native supervisor 必须成为官方 app-server 的真实启动/生命周期 owner，或通过已验证的进程级启动协议让官方进程连接 `57321`；不得改写供应商定义、`config.toml`、Key、认证、模型、会话或 Vortex。

### H2. 生产 Headroom/Gateway/Monitor/Broker 当前未形成 ready 链（硬阻塞）

生产 `18787/18788/18789/18790` 当前无监听，历史 `headroom-start-result` 曾为 `broker_ready_timeout`，route heartbeat 和 managed state 不能直接复用。只要 monitor `18788` 不可达或 listener 的 PID/path/hash 未知，就必须拒绝放行官方窗口。

**必须解决：** 冷启动、重复启动、旧 PID、端口占用、broker 冷加载、monitor 启动顺序、route heartbeat 和 stale lease 都要有确定的 fail-closed 结果；失败时不启动客户端撞 504。

### H3. Native Route C 还没有生产候选和受控切换（硬阻塞）

当前源码工作树包含 Route C 改动，但生产安装目录没有被替换，隔离 `current` 二进制也没有完整的候选 manifest、源码 commit、依赖锁、二进制 SHA-256 和回滚包绑定收据。

**必须解决：** 先冻结 candidate manifest，再在隔离目录构建；生产只允许通过用户手动激活窗口进入 canary。未通过前不得覆盖 `D:\program\Codex++`，不得创建隐式 C 盘副本。

### H4. “main/compress” 与实际压缩范围不一致（功能阻塞）

当前 Responses 实现只压缩 `custom_tool_call_output`、`function_call_output`、`local_shell_call_output`、`apply_patch_call_output`。普通 `message/input_text` 位于缓存前缀，不会进入 Kompress。因此主请求可以标为 `compress`，但实际压缩收益为零。

**必须解决：** 在不破坏缓存前缀、工具调用、CCR/marker 和最近上下文的前提下，实现 cache-aware 的历史消息压缩；或者明确把“只压缩 tool-output”作为产品边界并接受其有限收益。若目标是正常使用中持续降低上下文，前者是上线必需项。

### H5. 端到端 correlation 和计量还不够（硬阻塞）

当前 broker 只提供累计 counters；即使新增请求前后 delta，也不能把具体 Gateway `correlation_id` 与某个压缩事件逐请求关联。`main/compress`、`spawned/bypass` 和健康页只能证明控制流，不足以证明每条官方流真正经过压缩。

**必须解决：** Gateway 生成脱敏 request/correlation ID，并在 Headroom、broker、egress、fake/真实上游和 SSE 终态收据中保持同一 ID；日志只保存哈希、类别、延迟、状态和错误码，不保存正文/凭据。

### H6. 压缩冷启动、延迟和复用稳定性不足（稳定性阻塞）

broker 首次加载可能需要数分钟；ready broker 复用第一次曾出现 `ResponseEnded`，第二次才通过。当前 CPU worker 串行，必须证明真实负载下不会制造 504、静默断流或读取超时。

**必须解决：** 启动预热、单 worker/队列上限、连接/读取/总预算、超时 fail-open、worker 重启和电路隔离都要有压力证据。压缩失败必须返回原请求继续发送，不能重放非幂等请求。

### H7. 真实最终验收尚未执行（硬阻塞）

尚未完成官方窗口的 `1+1 -> 10+10 -> 50+50` 分级流量、长 SSE、供应商切换、Manager 重启、broker 崩溃、ONNX malformed output、设备移除、非 UTF-8、上游 EOF 和回滚验收。

**必须解决：** 每一级都要证明 504=0、静默断流=0、缺失标准终态=0、spawned 误压缩=0、main 有真实压缩样本、配置受保护契约不变。

### H8. 自动化测试矩阵仍缺一个权限门（交付阻塞）

`cargo check/build/clippy --workspace` 和 core/data tests 已通过；完整 workspace test 在启动带 `requireAdministrator` 清单的 launcher 测试二进制时返回 Windows `os error 740`。这不是代码断言失败，但不能报告完整矩阵全绿。

**必须解决：** 提供明确的提升测试入口，或把需要管理员的 launcher smoke 从普通单元测试中分离为独立 operator gate；不得改断言、去掉 manifest 或全局忽略测试。

### H9. 生产监控和旁路判据仍可能误导（硬阻塞）

受管 Codex++ 状态不能代表官方窗口状态；`api.pending_completion`、历史 token 计数、Vortex 旁路和 monitor stale 状态必须分开显示。官方窗口只有在真实连接和上游终态可关联时才允许 `official_dataplane=confirmed`。

**必须解决：** monitor 使用统一 snapshot，明确 `confirmed/bypass/unknown`，缺少精确 token accounting 只能黄色；历史样本不能伪造 pending 或压缩成功。

### H10. GPU/NPU 加速未达到生产门槛（性能风险，不阻塞 CPU 上线）

当前机器 WebGPU 有 `0xC0000409/LiveKernelEvent 141` 安全阻断；DirectML/MIGraphX/VitisAI/NPU 没有通过完整 Kompress 模型、重复运行、长流和故障注入。CPU ORT 是目前唯一可接受后端。

**必须解决：** 若要切换加速后端，必须在隔离 worker 中满足 30 次完整模型连续推理、动态长度/静态 bucket、并发和长 SSE、无 device removal/解码异常/超时，并且 p95 至少比 CPU 快 20%；否则保持 CPU，不影响 CPU 生产放行。

### H11. 发布候选与仓库脱敏未收口（发布阻塞）

项目源码树包含运行时、缓存、日志、模型和历史 evidence；GitHub 只能发布源码和脱敏清单，不能发布凭据、会话正文、认证数据库、私有运行状态或未经 LFS/许可核验的模型。

**必须解决：** 发布前生成 allowlist candidate manifest，运行 validator、secret scan、体积/许可检查和 diff freeze；普通 push 前不得强推或覆盖远端。

## 开发与修复顺序

### Phase 0：冻结基线（Codex，可立即完成）

1. 读取 README/HANDOFF/WORK/AGENTS，记录当前生产 PID、端口、配置受保护契约和 Vortex 旁路。
2. 固定官方 v1.2.44 commit、Cargo.lock、Python/ONNX 版本和当前 Route C 源码 hash。
3. 生成 Candidate Manifest v1；候选只来自项目根，runtime/cache/log/model/private 排除在发布候选之外。
4. 运行 PowerShell/Python/Rust 静态 validator；发现 drift 立即停止写入。

**G0 通过条件：** 配置 hash 未变化、生产 Route C=off、候选 manifest 无 drift、无 secret-like 文件。

### Phase 1：修复生产启动和监控（Codex）

1. 修复 `Start-HeadroomForCodexPP.ps1`、startup gate、route keeper 和 monitor 的顺序：broker ready -> Headroom -> Gateway -> monitor -> route lease -> Manager/Client。
2. 将 broker `/readyz`、Headroom `/health`、Gateway `/livez`、Monitor `/status` 和 listener identity 统一为 ready 合同。
3. 加入 stale PID/端口占用/重复点击/旧 route-state 清理的隔离测试；失败只生成结构化 receipt，不放行官方窗口。
4. 为所有 native/helper 进程写入路径、PID、启动时间、模块 hash 和 generation；停止时只终止完全匹配的进程。

**G1 通过条件：** 在备用端口完成冷启动、重复启动、旧 PID、broker 重启和 monitor 重启；生产端口不触碰。

### Phase 2：封装并验证 native Route C candidate（Codex）

1. 完成 ingress `57321`、egress `57322`、lease/capability/heartbeat 的隔离实现和回滚脚本。
2. 确认 Headroom 透传/剥离 `x-route-c-*`、capability、generation、owner 和 correlation header；禁止自循环上游。
3. broker/Headroom/Gateway/egress 每个 hop 返回脱敏 correlation receipt；响应按原始 SSE 字节透传，EOF 缺终态时补发一次 `response.failed`。
4. 使用新的 counter delta 门禁和 native stdout/stderr 收据跑 fresh canary；保留首次失败，不用历史累计计数替代。

**G2 通过条件：** 30 次完整模型压缩无超时/解码/device removal，30 次 spawned bypass 无误压缩；顺序、并发、长 SSE 和故障注入全部通过。

### Phase 3：解决官方窗口真实接入（Codex + 用户手动激活）

1. 在 Codex++ native launcher 中实现官方 app-server 的进程级路由注入；不要依赖 Windows AppX 继承外部环境这一未证明假设。
2. 启动前验证 `18790/18789/18787/18788/57321/57322`，启动后验证官方 PID/TCP、Vortex `7897` 是否消失、Gateway 增量和上游 correlation。
3. 用户手动退出 ChatGPT/Codex/Codex++ 后，双击唯一入口；Agent 不自行停止或重启生产进程。
4. 失败立即执行只针对当前 generation 的 rollback，恢复原入口和配置选择；不修改供应商定义。

**G3 通过条件：** 官方进程连接 `57321`，同一请求完整经过 Gateway/Headroom/egress/真实上游，并收到 `response.completed` 或标准 `response.failed`。

### Phase 4：补齐压缩语义和性能（Codex）

1. 设计 cache-aware 历史 `input_text` 压缩：保护缓存前缀、最近 turn、工具调用和 CCR；压缩结果可逆旁路，失败原文继续发送。
2. 对 tool-output、历史 input_text、空内容、Unicode、代码、URL、超长 payload 和 malformed output 做单元/集成测试。
3. 采集 CPU p50/p95、队列等待、推理、总延迟和 fallback；以真实负载选择 workers、intra/inter-op threads、队列和预算。
4. GPU/NPU 只在独立 worker 闸门中作为 shadow candidate；失败自动 CPU，不改变生产 provider。

**G4 通过条件：** 真实 main 请求有可复核压缩节省；keep/drop 一致率 >=99%，无压缩超时导致的 504，CPU fallback 可用。

### Phase 5：最终验收和发布（Codex + 用户手动窗口）

1. 清理旧日志/计数并保留清理收据；执行 50 main + 50 spawned 官方 SSE 请求，另行标记 synthetic 流量。
2. 至少两次供应商切换、Manager 重启、broker 崩溃、Headroom 超时、上游 EOF 和非 UTF-8 故障注入。
3. 未参与施工的验收员复核进程身份、配置 hash、route lease、monitor 状态、日志脱敏、快捷方式和失败路径。
4. 生成发布 allowlist、manifest hash、源码 commit、二进制 hash、测试收据和回滚说明；通过 secret scan 后再推送 GitHub。

**G5 生产放行条件：** 504=0、`stream disconnected before response.completed`=0、缺失终态=0、spawned 误压缩=0、main 有真实压缩、官方 correlation 完整、配置受保护契约不变、所有失败路径可回滚。

## 明确不作为当前硬门禁的事项

- GPU/NPU 未成功不阻塞 CPU ORT 生产基线，但阻塞“GPU/NPU 加速已交付”的声明。
- GitHub 发布不应先于本地 candidate manifest、脱敏检查和生产验收；发布失败不应通过强推解决。
- 历史 token 账单、健康页绿色、Codex++ Manager 状态和单次 synthetic 200 响应都不能替代官方窗口全链证据。
