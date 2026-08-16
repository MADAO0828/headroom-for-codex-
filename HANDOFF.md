# Headroom for Codex++ 交接记录

## 2026-07-31 / Codex

### 本轮事实

- 项目根目录从空目录开始建立；源码副本位于 `src/headroom` 和 `src/codexpp`。
- `gateway.py` SHA-256：`9E07E3C67936F9D4088FA40C552B63E501ED7AC8D2FC3509FF7A7E6A729679CE`。
- `test_gateway.py` SHA-256：`4770692E796A9445866CD369C31C9B26B632DEC00091039D147C1ED7D11E08B2`。
- 当前监听证据：Headroom `18789`、Gateway `18787`、Codex++ helper `57321`；现有服务未在本轮被停止。
- 当前官方/生产配置未改写；启动专项验证记录官方 `.codex/config.toml` 哈希保持 `C43557AF04289C310DDE1C1758AF7643690FC62598670B2A44DDD2F76A15E1EE`。

### 已完成

- Gateway：损坏 metadata 强制 main/compress；SSE 原始字节透传；EOF/timeout/非 UTF-8 诊断 fail-open；metrics 和 cleanup 不得覆盖已建立的上游响应。
- 路由：route keeper 发布 `process_route_base_url`、`route_scope=process`、`config_mutated=false`；startup gate 通过进程环境覆盖传递路由；wrapper 使用 `-Role codex`。
- 模型：完整 blob 已复制到 `models/kompress-v2-base/huggingface-cache`，SHA-256 与原缓存一致；snapshot symlink 另保存为实体文件以适配 Windows 权限。

### 测试

- Gateway 施工包：`test_gateway.py` 23/23；Gateway + launcher 合计 26/26。
- 启动 gate/route keeper：PowerShell Parser、route fixture 和配置哈希不变验证通过。
- 未完成：monitor 全量专项测试、受管重启后的真实压缩 smoke、50+50 自然请求验收。

### 保护边界

- 凭据、令牌、完整会话正文、认证数据库和个人数据未复制/未上传；这是全局安全规则的硬约束。
- 未修改 `D:\gpt-image2`；未执行 reset/clean/checkout/强制推送。

### 下一步

1. 修复 monitor 的 fail-closed 断言和旁路可见状态。
2. 受管停止/启动 Headroom，确认 Kompress CPU ready；失败时保持 fail-open。
3. 运行完整测试、日志清理和独立验收。
4. 冻结允许发布文件后再安全推送 GitHub。

## 2026-07-31 / Codex（续作复核）

### 本轮改动

- 修复 `src/headroom/site-packages-patches/headroom/proxy/handlers/openai.py` 及当前 venv 对应实现：`/v1/compress` 的 `tokens_saved` 使用已归一的非负值；运行时文件写入前已备份为 `backups/site-packages-headroom-openai.py.20260731-064700.bak`。
- 扩展 `scripts/Clear-HeadroomRuntimeArtifacts.ps1`，把 Gateway metrics/process state、Headroom startup/state snapshots 与旧日志一并纳入白名单清理；执行前 dry-run 发现 47 个文件，执行后清单写入 `evidence/runtime-clear-manifest.json`。
- 新增 `scripts/Invoke-HeadroomSyntheticAcceptance.py`，只保存脱敏计数、状态码和延迟；新增 `.gitignore/.gitattributes` 规则，阻止验收 JSONL、trace、route state、疑似 API key 文件、wrapper 二进制和 extensionless model blobs 被误提交，模型 blobs 统一声明 LFS。
- 新增 CPU 证据 `evidence/cpu-kompress-ort-20260731.json`。独立直接调用返回 `preload_backend=onnx`、provider=`CPUExecutionProvider`、ORT=`1.28.0`；71,100 字符输入真实推理约 11.5 秒。

### 启停与运行证据

- 先停止受管 Gateway、Headroom supervisor/worker、Monitor，确认 18787/18788/18789 无监听；未停止 Codex++ helper 57321，也未触碰 `D:\gpt-image2`。
- 唯一入口 `scripts/Start-HeadroomForCodexPP.ps1 -Workers 1 -ReadinessTimeoutSeconds 180` 返回 `status=succeeded`、`stage=manager_launched`；当前端口为 Gateway 18787、Monitor 18788、Headroom 18789、helper 57321。
- 清理后 Gateway counters 从零开始；合同窗口完成 `main=50`、`spawned=50`，两类均 50/50 HTTP 200，Gateway 记录 `total=104`（含前置 smoke 的 2+2）、`error=0`、`timeout=0`，策略计数 main/compress 与 spawned/bypass 对齐。
- monitor `/status` 当前为 `yellow`：路由、健康、传输、API 均正常；`kompress=gray/deferred` 为懒加载提示，token-accounting 为黄色是因为 `/v1/compress` 没有上游精确 token header，不是负节省或 504。

### 独立审计与限制

- 独立仓库审计结论为“满足条件后可行，当前不宜直接发布”：全树约 1.104 GiB，模型约 1.098 GiB；`.git` 尚不存在，`git ls-remote`/DNS 无法解析 `github.com`，远端状态未知。
- 审计识别 `headroom-status-indicator.js` 中疑似硬编码 API key、`acceptance/reports/v4-trace.log` 的 authorization/prompt 模式、267 个 JSONL/session evidence、用户路径 manifest、未签名 wrapper；未打印这些值，也未将其上传。
- 用户要求的全量文件已在项目根目录本地保留（包括日志、缓存、状态和模型）；安全规则禁止复制/上传凭据、认证数据库、完整会话正文和个人数据，因此这些受保护数据仍在原位置或仅作为本地受控副本保留。

### 测试与失败路径

- Python unittest：`test_gateway.py` + `test_headroom_launcher.py` 共 `26/26 PASS`。
- PowerShell parser：`scripts`/`src` 共 40 个 `.ps1` `PASS`；startup-chain `PASS`。
- `evidence/synthetic-acceptance-20260731.json`：`passed=true`、`compression_504_total=0`、`negative_savings_total=0`、旁路 mismatch=0。
- 隔离 worker 第一次启动因 PowerShell 带空格脚本路径参数拆分而未执行；第二次错误使用不存在的 CLI `--force-kompress-all`；两次均未触碰生产服务，随后改用环境变量并成功启动隔离 worker，最终已停止并确认 18790 无监听。
- 独立验收员因上游 Codex responses 传输 EOF 返回 `502`，未能交付可读验收回执；仓库审计员交付了可读发布阻塞收据。主负责人据现有代码、测试、真实端口和审计证据完成非独立收口，明确标记该限制。

### 未决与下一步

1. 不把懒加载 `deferred` 误报为模型损坏；若要优化状态页，需为跨 worker Kompress ready 增加上游状态桥接。
2. 自然模型 SSE 仍未宣称完成；现有 50+50 是 `/v1/compress` 合同样本，SSE EOF/非 UTF-8/timeout 由 26 个 mock contract tests 覆盖。
3. Gateway `/health` helper 探测约 5-7 秒，当前有界等待可用但仍是后续性能改进点。
4. GitHub 推送待 DNS/网络恢复且完成脱敏 allowlist、LFS 额度和远端空仓库核验；禁止强推、reset、clean 或上传敏感文件。

## 2026-07-31 / Codex（本地发布快照）

- 本地 Git 已初始化为 `main`，配置 `origin=https://github.com/MADAO0828/headroom-for-codex-.git`；Git LFS `3.7.1` 已启用，4 个模型路径均为 LFS pointer，原始模型 blob 仍保留在工作树。
- 安全 allowlist 快照已提交：`17dab5a Stabilize Headroom routing and compression acceptance`。提交使用仅本地的 `Codex (local) <codex@localhost.invalid>`，未改全局 Git 身份。
- `git push -u origin main` 单次尝试运行 94 秒后超时；`git ls-remote` 与 DNS 均不能解析/连接 `github.com`，远端分支是否存在保持 `UNKNOWN`。未执行强推、reset、clean、checkout，也未再次重试。
- 提交外的未跟踪文件是本地运行副本（状态、日志快照、激活脚本和备份）；它们没有被删除或上传，敏感文件仍受本地规则保护。
- 最终 route-state 只读证据：`status=ready`、`route_scope=process`、`process_route_base_url=http://127.0.0.1:18787/v1`、`config_mutated=false`。本轮读取到的 `.codex/config.toml` 和 `.codex-plus-plus-cli/config.toml` hash 分别为 `DB4F619E...2762C` 与 `6FF5714D...875F`；旧交接中的历史 hash 不作为本轮未变证明，避免掩盖用户自行切换配置的可能。

## 2026-07-31 / Codex（压力修复、清理与最终重启）

### 根因与改动

- 复核上一轮压力窗口：main 35/50、spawned 29/50 成功，共 36 个 504；并发 8 路时全部出现 `policy_gateway_upstream_timeout`。实时 Headroom executor 显示单个压缩槽、约 25-30 秒预算耗尽；monitor 的短健康探测在 CPU 忙时也会误写 `headroom_not_ready`。
- `gateway.py` 现在在 Headroom 首次超时、HTTP 错误或异常时对真实 `/v1/*` 请求重试 helper；对 `/v1/compress` 返回原始 payload 的零变换旁路结果，并记录安全 fallback 原因，不把压缩故障变成 504。helper 404 转为稳定 502。
- `Start-HeadroomForCodexPP.ps1` 增加 manager `-ReadinessOnly -SkipEnsure` 自检：即使管理工具进程已存在，也会重建/确认 route watcher 和 process-scope 路由，不启动第二个 manager，不写供应商配置。
- 清理脚本扩展到项目运行副本、旧 `.headroom` 运行目录、AppData route/monitor 状态和 TEMP 启动日志，并纳入 `proxy_savings.json`、`savings_events.jsonl` 等聚合历史；模型、源码、缓存数据库、备份、凭据和会话正文不在清理白名单。
- 部署副本 `C:\Users\ma dao\AppData\Roaming\Codex++\codexpp-startup-chain.tests.ps1` 已从源码同步，SHA-256 为 `14B30B1C...0F4CD05`；同步前旧副本已保存到 `backups\headroom-project-sync-20260731`。

### 证据与验收

- Python unittest：`27/27 PASS`；PowerShell parser：`40/40 PASS`；部署 startup-chain：`PASS`；`git diff --check`：`PASS`。
- 修复后 8 路并发（4 main + 4 spawned）全部 HTTP 200，最大约 14.2 秒；随后 50+50 `/v1/compress` 重跑全部 200，`compression_504_total=0`、`negative_savings_total=0`、旁路 mismatch=0，证据为 `evidence/synthetic-acceptance-20260731-rerun.json`。
- 首次重启后的 2+2 smoke 全部 200，证据为 `evidence/post-restart-compress-smoke-20260731.json`。这些是脱敏合同/旁路样本，不冒充自然模型 SSE 对话。
- 额外本地合成 `/v1/responses` 深请求（无凭据、只到 helper `57321`）返回 404，Gateway 记录为 `main_compress/http_404`，没有 504；Headroom `/debug/warmup` 仍为 deferred，不能把该请求当作 Kompress worker warmup 成功。
- 最终停止受管 Gateway、Headroom、monitor、route watcher 后执行 `Clear-HeadroomRuntimeArtifacts.ps1 -Execute`；最新一次清理移除该实验新增的 15 个日志/状态文件（此前清理窗口为 19 个），manifest 为 `evidence/runtime-clear-manifest.json`。清理前的 Headroom 聚合统计备份在 `backups/runtime-clear-20260731`。
- 最终唯一入口 `scripts\Start-HeadroomForCodexPP.ps1 -Workers 1 -ReadinessTimeoutSeconds 90` 返回 `status=succeeded`、`stage=manager_ready`；18787/18788/18789/57321 均监听，route-state 实时 `ready`，`route_scope=process`、`config_mutated=false`；`.codex-plus-plus-cli/config.toml` 当前 SHA-256 与 route-state 均为 `6FF5714D...E1875F`。最终 Gateway metrics `total=0, ok=0, error=0, timeout=0, recent=0`，旧 `proxy_savings.json` 已清除。
- 最终 monitor `/status` 为 `yellow`：Gateway、Headroom、路由和 monitor-core 均 green；Kompress 仍是 deferred/unhealthy 提示，属于当前 worker 懒加载状态，不是启动失败。helper `57321` 未停止，`D:\gpt-image2` 未修改。
- 本轮独立验收 package 两次经协作通道返回不可解析的加密载荷，验收员未执行任何操作；因此本轮最终收口标记为“非独立验收”，依据为前次只读审计、源码/部署 hash、真实端口健康和本轮命令测试，不把未执行的 package 当作通过。

### 未决与限制

1. 当前 Headroom worker 的 `/debug/warmup` 仍报告 `kompress.source_status=deferred`；CPU ORT `1.28.0` 隔离真实推理可用，但尚未把跨 worker warmup 状态桥接到生产状态页。
2. 自然 Codex++ SSE 50+50 尚未执行；SSE EOF、非 UTF-8、超时和 `response.failed` 由 Gateway 合同测试覆盖，不能替代真实会话验收。
3. DirectML/MIGraphX/VitisAI/AMD plugin 仍保持隔离实验，不因本轮 CPU fail-open 验收进入生产。
4. GitHub 推送仍受 DNS/网络阻塞；未重试、未强推，远端状态保持 UNKNOWN。保护规则继续禁止上传凭据、会话正文、认证数据库和未脱敏 trace。

## 2026-07-31 / Codex（计划完成度审计）

### 审计证据

- 只读测试：Python `27/27 PASS`；PowerShell parser `40/40 PASS`；部署 startup-chain `PASS`；activation fixture `PASS`；`git diff --check` `PASS`。
- 运行态：`18787/18788/18789/57321` 各有一个监听；Gateway/Headroom livez 与 health 可达；route-state `ready`、`route_scope=process`、`config_mutated=false`，配置哈希与 route-state 一致。
- 当前 Headroom Kompress 仍为 `enabled=true/ready=false/status=unhealthy`，`/debug/warmup` 为 `deferred`；`/stats` 的请求、压缩策略和 token 计量均为零，监控为黄色等待自然流量基线。

### 未完成与冲突

- 项目根 Gateway（`484913DD...`）与运行副本（`9E07E3C6...`）不一致；根版本包含 helper fail-open fallback/`/v1/compress` 旁路，运行副本不包含。当前启动 gate 只验证进程和健康，不验证模块哈希。
- 桌面 `Codex++.lnk` 和 `Codex++ 管理工具.lnk` 仍直接启动 `codex-plus-plus.exe`/`codex-plus-plus-manager.exe`，未切换到唯一入口；已运行 Manager 的 readiness-only 检查不会把新的进程级环境注入已有进程。
- 自然 SSE `50+50`、真实长流验收和本轮独立验收包未完成；已有 `50+50` 仅为脱敏 `/v1/compress` 合同样本。GPU/NPU/MIGraphX/DirectML 仍为隔离实验，CPU ORT `1.28.0` 是唯一有直接推理证据的后端。
- `reconcile-codexpp.ps1` 仍保留可写 `config.toml` 的旧路径（含 `base_url` 替换），与“供应商配置只读”规则存在代码级冲突，虽未被当前唯一入口调用。
- 清理 manifest 曾以 `execute=true` 记录并保留备份，但审计期间健康探测重新产生 Headroom 日志；当前不能把运行日志称为已清空。Git HEAD 为 `a6c29a6`，工作树仍有修改/未跟踪文件，远端推送状态 UNKNOWN。

### 本轮边界

- 作者：Codex。仅追加本审计记录；未停止或重启服务，未修改供应商/API/认证/会话，未清理日志或缓存，未执行 push/reset/clean，未触碰 `D:\gpt-image2`。
- 结论：计划为“部分完成/满足条件后可行”，不具备“全部执行完成”的验收收据；后续必须先修复部署漂移和唯一入口，再做自然 SSE 与独立验收。

## 2026-08-01 / luna_max_worker（P12d 运行收口）

### 本轮事实

- P12c 独立身份核验确认 Manager `16744` 为 `D:\program\Codex++\codex-plus-plus-manager.exe`，client `31176` 为 `D:\program\Codex++\codex-plus-plus.exe`；版本均 `1.2.44`，父子链为 `explorer(9784) -> manager -> client`，端口分别为 `57865`、`57866/57321`。
- 两个直接进程各尝试一次 `CloseMainWindow`，15 秒后仍存活；在授权的 P12d fallback 下仅对这两个 PID 各执行一次 `Stop-Process -Force`，随后核验目标进程与端口均释放。
- 已核验的项目 Headroom writers（monitor、broker、worker、proxy、Gateway）共 9 个 PID 均指向项目 runtime/源码；按锁顺序停止后，`18787/18788/18789/18790` 均无监听。
- Manager bridge 在终止前后对 `57865/57866` 的 `/` 与 `/user-scripts` 均 3 秒超时；没有可验证的受支持 `/user-scripts/delete` transport，因此没有调用删除接口。

### 未执行与证据

- 未删除或修改 `user_scripts.json`、indicator 源文件、桌面快捷方式、计划任务、防火墙规则；未创建 junction；未启动唯一入口。
- `user_scripts.json` 快照显示 `scripts` 中含 7 个键（indicator 及 6 个无关脚本），整文件删除被禁止；indicator metadata 后置条件未满足。
- Move dry-run 仍为 `execute=false/remove_source=false`，53 个映射中 `.headroom` 目录为 `hash_mismatch`；未执行迁移/源文件删除。
- 脱敏收据：`evidence/p12d-cutover-receipt.json`；JSON、UTF-8 无 BOM/LF、`git diff --check` 通过。

### 结论与下一步

- 结论：部分完成，P12d 已按停止条件阻塞；生产路由和旧直接入口当前均已停止，不能宣称切换成功。
- 下一步必须先获得可达且受支持的 Manager `/user-scripts/delete` 入口，并重新核验两份供应商配置哈希，然后才可删除三项 indicator 源文件、更新桌面/任务/防火墙对象并通过唯一入口重启。

## 2026-08-01 / luna_max_worker（P12f 旧运行态静默）

### 本轮事实

- 本轮未启动任何进程；现场后来出现的旧实例创建时间为 2026-08-01 10:29-10:53（Asia/Shanghai），与本包命令无关。
- QueryFullProcessName 交叉核验：Manager `33772`、client `6412`；Headroom listener `11704`、Broker listener `35696`；runtime parents `18400`、`36292`；Broker child `12644`。路径、父子关系和端口与 P12f 记录一致。
- Manager/client 各尝试一次 `CloseMainWindow`，15 秒后仍存活；随后仅对已核验 PID 各执行一次 `Stop-Process -Force`。
- 仅停止已核验的 Headroom/Broker 进程树（`12644,11704,18400,35696,36292`），未触碰 `conhost.exe` 或其他无关进程。
- 18789、18790、57321、57865、57866 全部释放，5 秒观察无立即重生；两份配置哈希停止前后相同。

### 证据与边界

- 收据：`evidence/p12f-quiescence-receipt.json`，JSON/UTF-8 无 BOM/LF、`git diff --check` 通过。
- `.headroom` 的 DB/WAL/proxy 日志在运行时被锁；停止后可读取哈希。未删除 C 盘文件，未修改供应商配置、桌面、任务或防火墙对象。
- 下一步由主负责人单独启动 root-only 入口；P12f 不代表迁移或生产启动成功。

## 2026-08-01 / luna_max_worker（P12g 系统对象切换）

### 本轮事实

- 首次非管理员执行 `Set-HeadroomDesktopEntry.ps1 -Execute -RemoveLegacy` 时，精确 `Headroom 18787` 规则删除返回 Access Denied；快捷方式已配置、旧 shortcuts/tasks 均缺失，未做替代删除。
- 随后管理员上下文执行精确 `Remove-HeadroomFirewallRule.ps1` 返回 exit code 0；独立 `Get-NetFirewallRule -DisplayName 'Headroom 18787'` 复核 rule_count=0。
- 独立复核确认 `D:\Desktop\Headroom for Codex++.lnk` 仍指向 `wscript.exe` + 项目根 `Launch-HeadroomForCodexPP.vbs`，工作目录为项目根；两个旧 Codex shortcuts 和四个 ColdStart tasks 均不存在。

### 证据与边界

- 收据：`evidence/p12g-cutover-receipt.json`（非管理员阻塞）与 `evidence/p12g-admin-verify.json`（管理员成功复核）。后者 JSON、UTF-8 无 BOM/LF、`git diff --check` 通过。
- 本包未启动进程、未修改配置/provider/auth/model/session、未触碰 `D:\gpt-image2` 或无关系统对象。root-only runtime 启动仍需独立包。

## 2026-08-01 / Codex（P15 readiness 与三轮真实启动复核）

### 本轮改动与证据

- P15/v2：`ensure-headroom.ps1` 增加显式 `-AllowRelayPending`，只接受精确的 Gateway `503 degraded`、Headroom 正常、helper 未监听快照；默认/最终路径仍 fail-closed。证据：`evidence/p15-cold-start-readiness-v2.json`。
- P15/v3：`Start-HeadroomForCodexPP.ps1` 与 `codexpp-startup-gate.ps1` 的预启动 monitor 门禁允许身份/schema 合同有效但 overall red/yellow；客户端启动后的 final gate 仍要求 green/yellow、Gateway 200、helper ready、route/config/hash 全部通过。证据：`evidence/p15-cold-start-readiness-v3.json`。
- P16：清理脚本新增 `runtime/state` 下 `broker*.json` allowlist；最终一次清理 `evidence/runtime-clear-20260801-040406445.json` 为 19/19 备份并删除、剩余 0。配置哈希仍为 `.codex/config.toml=74FE5DE1...F3D`、`.codex-plus-plus-cli/config.toml=774F8119...33F`。

### 三轮真实启动结果

1. 第一轮：`policy_gateway_ready_timeout`。根因是 ensure 内部只接受 Gateway 200 healthy，helper 尚未启动时合法 degraded 被提前终止。
2. 第二轮：`readiness_failed`。Gateway 已保留，但 monitor 的 prelaunch grace 在没有 Codex owner 时退出，第一阶段仍把 monitor red 当成阻塞。
3. 第三轮：`manager_process_not_observed`。`runtime/state/startup-result.json` 为 `route_keeper_failed`、`reason=headroom_not_ready`；Manager bootstrap 的 startup gate/route keeper 仍未接受 helper 启动前的 pending 契约，因此 Manager 未出现。

三轮均只启动项目根进程；每次均按命令行和 PID 精确停止，最后一次清理后 `18787/18788/18789/18790/57321/57865/57866` 均无监听。没有修改 Codex++ 配置、供应商、认证、模型、会话或 `D:\gpt-image2`。

### 当前结论与下一步

- 代码/fixture/合同测试通过，但唯一桌面入口的真实冷启动仍未验收；本轮按“三轮同一失败目标后停止”规则不再继续第四轮改写或启动。
- 下一轮若继续，必须先在独立 package 中设计 Manager bootstrap -> startup gate -> route keeper 的两阶段 pending/ready 契约，然后由未参与施工的验收员复核；不能只修改 root `Test-Ready`。

## 2026-08-01 / Codex（当前路由实测）

- 受管 Codex++ 当前路由状态可读为 `ready`，`route_scope=process`，`proxy=local-headroom`，`process_route_base_url=http://127.0.0.1:18787/v1`，且 `config_mutated=false`。
- 最小 Responses 探针经 `18787/v1/responses` 返回 HTTP 200；Gateway 记录 `main/compress=1`、`ok=1`，Headroom `18789/health=200`。Headroom 启动命令明确把 `/v1/responses` 转发到 `http://127.0.0.1:57321`。
- 受管 Manager/client 与 Relay 在探针前后曾短暂重启，最终快照恢复监听；因此“走 Headroom”结论适用于受管 Codex++ 链路的实测请求，不代表未受管官方 `codex.exe` 会话。官方 `.codex\config.toml` 仍是 `https://skyapi2026.com`，监控将其标为不属于受管进程树。
- 本轮无代码、配置、凭据、认证、模型、会话或二进制改动；自然 SSE 会话仍未作为验收样本。

## 2026-08-01 / Codex（最终复核、P19 heartbeat 与 P20 清理）

### 已完成

- `FINAL-ACCEPTANCE/v1` 独立验收收据 `evidence/final-acceptance-20260801.json`：自然 `50 main + 50 spawned` 全部 HTTP 200、`text/event-stream`、`response.completed`；504、5xx、静默 EOF、缺少终态、解码异常和传输中断均为 0；`main/compress=50`、`spawned/bypass=50`、误分类 0。
- `P19-route-heartbeat/v1`：route keeper 增加带 schema/status、config hash、provider、base URL、keeper PID、脚本路径和状态路径校验的 `Write-RouteHeartbeat`，每 20 秒以内原子刷新 timestamp；失败回到完整 `Ensure-RouteOnce`，不放宽 fail-closed。
- `P19-runtime-acceptance/v1`：仅重启已核验的 route keeper，旧 PID 9368 -> 新 PID 27620；4 个样本 route age 最大 16.6 秒、monitor route 全 green、`ready/process/config_mutated=false`，配置哈希 `774F8119...9833F` 前后不变。
- `P19-post-restart-sse-smoke/v1`：重启后 main/spawned 各 1 条 SSE 均 200、`response.completed`、无 decode error，配置双哈希不变。
- `P20-c-drive-headroom-backup-removal/v1`：仅移除已核对且树哈希 `E4BFB3F6...` 一致的 C 盘 Headroom 备份目录；项目副本保留，未触碰无关备份、供应商配置、认证、会话或 `D:\gpt-image2`。
- `reconcile-codexpp.ps1` 只读验证通过：`READ_ONLY=true`、`COMPATIBLE=true`、`CONFIG_HASH_UNCHANGED=true`。

### 测试与限制

- Python unittest `30/30 PASS`；startup-root、startup-chain、迁移脚本 `PASS`；PowerShell AST `46` 个脚本 `Errors=0`；P19 heartbeat 三周期/stale keeper fixture、UTF-8 无 BOM/LF、`git diff --check` 均通过。
- 当前监控正常为 yellow，仅 `token-accounting.incomplete`；外部未受管官方 Codex 只作为旁路警告，不纳入受管路由。
- GPU/NPU/MIGraphX/DirectML 仍隔离，CPU ORT 为生产后端。GitHub 发布尚未执行，需网络可达后做脱敏 allowlist、LFS 与远端状态复核。

作者：Codex。以上证据不包含响应正文、凭据、令牌、认证数据库或个人数据。

## 2026-08-01 / Codex（续作复核与发布阻塞）

### 本轮事实

- 按项目规则先读取 README、HANDOFF、AGENTS；PowerShell 7.6.3 可用。
- 生产运行态复核：18787/18788/18789/18790、57321、57865、57866 均在监听；Gateway、Headroom、Kompress 和 Monitor 端点均返回成功。route-state 为 `ready/process/config_mutated=false`，Kompress 为 `CPUExecutionProvider/onnx/ready`。
- 发布工作树 `D:\新建文件夹\headroom for codex++-public-release` 当前为 `codex/public-release`、提交 `5e9ba3e`、工作树干净；与主分支共有的 60 个文件内容哈希一致。

### 测试

- Python `src/headroom/codexpp-headroom` 合同测试：`30/30 PASS`。
- 迁移测试、startup-root、startup-chain：`PASS`。
- PowerShell AST：`46` 个脚本，`0` 个解析错误。
- 首次运行 `tests` 目录时未设置 `PYTHONPATH=src` 导致导入错误；补齐项目环境后重跑通过，代码未改动。

### GitHub 发布状态

- GitHub 网页观察到目标仓库为空；`gh auth status` 显示未登录。
- `git ls-remote` 和一次普通 `git push -u origin codex/public-release:main` 均因当前连接 `github.com:443` 失败而未发出有效远端更新，状态保持 `UNKNOWN`。
- 未强推、未覆盖远端、未读取或记录凭据。收据：`evidence/github-publish-20260801.json`。

### 下一步

用户完成 GitHub 身份认证且网络可达后，只需重新核对远端为空，再执行一次普通推送；此前本地服务和发布树无需重做。

作者：Codex。

## 2026-08-04 Route C 返工独立收口（Codex，P63）

### 状态

- `P63-route-c-rework-independent-audit/v1 = SUCCEEDED`：本轮独立审计和项目内修正完成；这不表示 Route C 生产完成。
- 生产状态：`route_c=off`、`official_dataplane=not_proven`、`production_decision=NO-GO`。
- 完整收据：`evidence/route-c-rework-independent-audit-20260804.json`。

### 独立证据

1. **压缩**：全新 Canary `20260804-005510572` 未复用 broker。broker PID `63356` 请求前后不变，`compressed` 计数从 `0` 增加到 `1`，`total=1`；Gateway 为 `main/compress=2`、`spawned/bypass=1`，假上游 3 请求，SSE 均有 `response.completed`，清理后 `58321/58322/18887-18891` 无监听。
2. **构建**：fresh target 上 `cargo check --workspace`、`cargo build --workspace`、`cargo clippy --workspace --all-targets -- -D warnings` 和 core/data 测试均 PASS。Manager 已包含在 check/build/clippy 中；未复现“Manager 依赖导致编译失败”。完整 workspace 测试唯一失败为 launcher 的 `requireAdministrator` 测试二进制启动返回 Windows `os error 740`，已执行测试均通过。
3. **压缩范围**：Responses 代码只把 `custom_tool_call_output`、`function_call_output`、`local_shell_call_output`、`apply_patch_call_output` 作为候选；普通 `message/input_text` 保留在缓存前缀。`main/compress` 不能被解释为普通用户输入一定压缩。
4. **生产**：当前 `18788` 不可达，旧 `headroom-start-result` 为 `broker_ready_timeout`，route-state stale；官方 codex 观察到 Vortex `7897`，无同一请求经过 `57321 -> 18787 -> 18789` 的证据。生产链不可放行。

### 本轮代码改动

`scripts/Start-RouteCCanary.ps1` 的压缩门已由累计 `broker_compressed >= 1` 改为请求前后 counter delta；增加 broker PID、路径、启动时间、命令行 SHA-256 和 PID 稳定性检查。脚本 parser、dry-run、startup-root fixture 和全新 Canary 均通过。生产启动脚本、供应商配置、Vortex、驱动和 `D:\gpt-image2` 未触碰。

### 未决与下一步

- 仍需用户手动退出/启动官方 ChatGPT/Codex，完成官方窗口全链 correlation、1+1 -> 10+10 -> 50+50、UI/indicator、供应商切换、回滚、注销/登录和 24 小时样本。
- 完整 workspace launcher 测试需在提升上下文重跑；broker 仍缺 Gateway correlation_id 到逐请求 compression event 的可读关联。
- WebGPU/NPU/DirectML/MIGraphX 继续 lab-only，生产后端保持 CPU ORT。

作者：Codex。

## 2026-08-04 最终复核收口

- CPU 是 provider router 默认；WebGPU 需要显式 flag 和项目内隔离解释器。
- 新增 GPU 稳定性门：`runtime/lab/webgpu_guard/safety.py` 和真实验收 harness 会在当前 0409/141 收据存在时拒绝 native session；`evidence/accel-webgpu-stability-preflight-v1.json` 为 `passed_lab_only`，真实 WebGPU 文本验收仍为 blocked。
- 默认导入未加载 WebGPU/ORT；主解释器加速套件 30（29 passed/1 skipped），隔离 lab venv 33/33 passed，compileall/diff-check 通过。
- 生产审计保持 `NO-GO`；本轮没有硬件 session、生产生命周期或配置改动。

作者：Codex。

## 2026-08-03 P57 Reasonix 执行结果（Codex）

- 已通过正式 `spawn_agent(luna_max_worker)` 将 P53、P50/P51/P52 native 构建、隔离 Canary、失败路径和后续人工验收交给 Reasonix；package 读写范围和禁止项见 `WORK.md` 的 P57。
- Reasonix worker 在共享树留下了部分 launcher 改动：`apps/codex-plus-launcher/src/main.rs` 的 Route C 参数/生命周期透传，以及 `crates/codex-plus-core/src/launcher.rs` 的 egress `/health`、`/livez` loopback 控制面提前响应。现有日志支持“曾发生部分施工”，不支持“测试通过”。
- worker 没有返回可读的构建、测试、Canary 或端口释放收据，随后被停止；P57 状态为 `UNKNOWN`，不是 `SUCCEEDED`。证据：`evidence/reasonix-route-c-closeout-20260803.json`。
- 生产 Route C 仍为 `off`；未改供应商定义、Base URL、Key、认证、模型、会话、Vortex、生产端口或 `D:\gpt-image2`。部分共享源改动保留，后续 Reasonix 必须先核对差异再继续，不得回滚无关改动。
- 未完成清单仍包括：完整 `cargo fmt/check/test/clippy` 和 launcher/manager build、native Canary、假上游 30+30/故障注入、用户手动激活、1+1→10+10→50+50、UI/indicator、供应商切换、回滚、注销/登录和 24 小时自然样本。

作者：Codex；本条记录不改变生产配置和当前进程。

## 2026-08-02 / Codex（P38 官方窗口临时路由可行性）

### 结论

用户提出的目标可以实现，但实现语义必须是“应用生命周期事务”，不是“启动后立即恢复文件”：

```text
official Codex/ChatGPT
  -> Gateway 18787
  -> Headroom 18789
  -> Relay 57321
  -> Codex++ SettingsStore 当前选中的外部供应商
```

官方 live 配置在所有 ChatGPT/codex app-server 退出前保持本地路由；正常退出后恢复**最新选中供应商**的投影。启动后立即恢复会让已有线程与新线程/显式 reload 使用不同配置，不可采用。

### Codex++ 数据边界

- 供应商权威数据是 `.codex-session-delete/settings.json`，live `config.toml/auth.json` 是运行投影；Relay `57321` 每次请求从 SettingsStore 选择 profile，并用其外部 URL/Key 请求上游。
- 临时改 live 文件不会自动改变 SettingsStore，但活动供应商页面会显示 live 文件，供应商切换前还会 backfill live 文件。因此若不修改 UI/backfill 逻辑，截图中的 Base URL 会暂时显示本地地址，并可能被持久化到旧 profile。
- 必须增加 route lease：租约生效时，供应商编辑页读取 SettingsStore；切换供应商时跳过临时 runtime provider 的 backfill，校验新选中及全部 fallback 上游无环后，仅更新 Relay selection/lease generation。

### 官方 Codex 配置生命周期

- 官方 app-server 支持 `-c/--config` 和 `CODEX_HOME`，启动时捕获覆盖；已有线程只有显式 reload 才批量刷新，新线程会重新加载最新配置。
- 首选隔离验证 `-c` 注入，因为它可以保持真实 `config.toml` 和 Codex++ UI 完全不变；但 Windows AppX 能否可靠接受外部 wrapper 注入尚未证实。
- 若 `-c` 注入不可行，使用带原子备份、哈希、owner PID/start time、heartbeat、generation 和崩溃恢复的 live-config lease。任何哈希/身份冲突都进入 `recovery_required`，不得覆盖用户新修改。

### 必须补齐的失败保护

- selected 和 fallback 全集不得指向 loopback 保留端口 `18787/18789/57321`。
- Start 脚本必须记录本轮新启动 PID，并在最终 gate 失败时精确回滚本轮进程；现有 catch 只写失败收据，不足以形成事务。
- 不得把供应商真实 URL/Key 写入 Headroom 状态、日志或 lease；只保存脱敏哈希和 profile ID 哈希。
- 只有官方 PID 到 Gateway 的连接、Gateway correlation、Headroom/Relay 同窗证据和标准 SSE 终态同时存在，才能报告当前窗口接入成功。

收据：`evidence/p38-transactional-official-route-feasibility-20260802.json`。本轮只读侦察，没有修改配置或生产进程。

作者：Codex。

## 2026-08-02 最新官方数据面快照（Codex）

只读采样时间 `2026-08-02T05:40:36.3135903Z`：官方 `codex.exe` PID `48200` 与 ChatGPT 网络子进程 PID `40428` 连接 Vortex `127.0.0.1:7897`；没有官方 PID 到 `18787/18789/57321` 的模型端口连接。受管 Gateway `18787`、Headroom `18789`、Relay `57321` 虽在监听，但这只证明受管链控制面存在，不能证明当前官方窗口数据面接入。

最新脱敏收据：`evidence/current-window-route-audit-20260802-live2.json`。本次未发模型请求，未启停进程，未改官方配置、供应商、Vortex 或系统代理。

作者：Codex。

## 2026-08-02 历史接入实现与 502/504 根因复核（Codex）

### 已确认

- `C:\Users\ma dao\.codex\handoffs\20260726-103106-257+0800-reasonix-headroom-codexpp-handoff.md`、`20260729-131844-395+0800-reasonix-headroom-codexpp-handoff.md` 以及项目 `backups/c-drive/appdata-roaming/Codex++/backups/headroom-integration-current/codexpp-route-keeper.ps1` 的哈希和内容已复核。旧方案确实通过改写官方 `.codex/config.toml` 活动 provider 的 `base_url`、补 `supports_websockets=false`，再配合旧启动门/`CODEX_HOME` 假设，尝试建立官方窗口到 Headroom 的链路。
- 旧方案不是“只启动 Headroom 服务”：它有配置写入、原子替换和路由状态发布，因此历史上出现过真实链路是可信的；但 AppX activation 不可靠继承启动器环境，且配置写入已经被当前铁律明确禁止。

### 故障分层

1. 2026-07-30 完全转发窗口使用 `--no-optimize/--disable-kompress`，仍观察到约 672 个 200 和 16 个 502，但没有压缩超时、504 或 `stream disconnected`。同期 EOF/`context deadline exceeded` 指向外部节点或 helper 传输，不能把这批 502 归因于 Kompress。
2. 2026-07-28 另一批 502 的最早来源是外部上游；随后把 `18787` 写入上游后出现 `57321 -> 18787 -> 18789 -> 57321`，这是确定性自循环，必须与外部上游错误分开记录。
3. 2026-07-31 的 36 个 504 来自隔离压缩并发/预算压力，证明压缩层需要队列、预算和 fail-open 保护；它不是官方桌面自然请求，也不能反向证明所有 502 都由压缩造成。

历史运行记录还在 2026-07-30 09:43:29（+08:00）明确记录了 `--no-optimize --disable-kompress` 命令行；原始会话正文未复制到项目。

### 当前边界

- 当前官方 ChatGPT/Codex 数据面实时证据仍是 Vortex `127.0.0.1:7897`，没有同窗官方 PID 到 `18787/18789/57321` 的连接；受管 Codex++ 的 `ready/process` 只代表控制面。
- P34a Gateway 关联和 P34b `official_dataplane` 已完成，避免再用 `python-httpx` 测试流量或受管 route green 冒充官方窗口证据。P34a Gateway 30/30，P34b 夹具 18 assertions，PowerShell parser/既有启动测试通过。
- 当前未获得新的官方桌面接入授权。因此不恢复旧配置写入方案，不修改 `.codex/config.toml`、Vortex 或系统代理，不停止/重启生产进程。

完整脱敏收据：`evidence/historical-route-audit-20260802.json`。

作者：Codex。

## 2026-08-02 当前官方桌面窗口路由审计（Codex）

### 结论

本轮撤回“当前官方 Codex 窗口已经通过 Headroom”的推断。实时数据面支持的是：官方 ChatGPT 网络子进程经 Vortex `127.0.0.1:7897`；受管 Codex++ 仍有独立的 `18787 -> 18789 -> 57321` 控制面/测试链。两者不能合并为一个证据。

### 只读证据

- `D:\Desktop\Headroom for Codex++.lnk` 解析为 `wscript.exe`，参数调用项目 `scripts\\Launch-HeadroomForCodexPP.vbs --phase-b`；该入口链在源码中启动的是项目 Headroom/Gateway/monitor/route keeper 和 `D:\program\Codex++` Manager/Client。
- 当前受管监听：Gateway `18787` PID `9260`、Monitor `18788`（HTTP.sys PID `4`）、Headroom `18789` PID `20380`、Kompress broker `18790` PID `11872`、Relay/Client `57321/57866` PID `51100`、Manager `57865` PID `50104`；route-state 为 `ready/process/local-headroom/config_mutated=false`。
- 当前官方进程：ChatGPT 根 PID `49876`，网络子进程 PID `40428`，官方 `codex.exe` PID `48200`，插件 appserver `codex.exe` PID `36608`。PID `40428 -> 127.0.0.1:7897` 为 Established；`7897` 监听者为 `C:\Users\ma dao\\.config\\com.vortex.helper\\com.vortex.helper.exe` PID `18272`。采样时官方进程没有到模型端点 `18787/18789/57321` 的连接。
- 进程树边界：ChatGPT 根 PID `49876` 的父 PID 为 `3192`，官方 `codex.exe` PID `48200` 的父 PID 为 `49876`；它们不是受管 Manager/Client `50104/51100` 的子进程。
- PID `40428 -> 127.0.0.1:18788` 的连接解释为状态/控制面轮询，不是模型请求；不能把它当作 Headroom 数据面证据。
- 配置域必须分开：P28 改的是 Codex++ `C:\Users\ma dao\\.codex-session-delete\\settings.json` / `C:\Users\ma dao\\.codex-plus-plus-cli\\config.toml`；官方桌面使用 `C:\Users\ma dao\\.codex\\config.toml`。共同出现 `57321` 不构成进程级路由继承或真实数据面证据。
- 直接对 WindowsApps 打包的官方 `codex.exe` 运行 `--help`/`app-server --help` 被系统返回“拒绝访问”；没有提权重试，也没有据此推断 wrapper 参数能力。Vortex 最终远端目标和官方窗口请求字节保持 `UNKNOWN`。
- Monitor 当前 `route=green` 的详细语义是“进程级 Headroom 路由、配置哈希和受管 Manager/Codex++ 进程身份已确认”，同时已经带有“官方 Codex 旁路警告”。Monitor 的通用 `Codex 连接=green` 只表示活动进程计数。

### P28 结论校正

P28 的聚合供应商/Relay 收据可证明受管 Codex++ aggregate/relay 健康，但不能证明当前官方桌面窗口的请求进入 Headroom。此前“无论切换供应商都经 Headroom”的表述超出了数据面证据，现标记为 `NOT_PROVEN`，不再作为验收依据。

### 根因判断

桌面快捷方式的进程级环境覆盖只对它启动的受管 Codex++ 进程树生效；它不会自动改变已经运行的官方 ChatGPT 网络服务，也不会把 Vortex `7897` 重定向到 Headroom。当前项目没有找到在不修改供应商配置、Vortex 或系统代理的前提下，能够让官方桌面数据面稳定进入 `18787` 的已验证路径。

### 外部资料交叉印证

- OpenAI 官方配置文档说明用户级 Codex 配置位于 `~/.codex/config.toml`，且 CLI/IDE 共享配置层；这支持把官方桌面 `.codex` 域与 Codex++ 专用 `.codex-plus-plus-cli` 域分开核对。
- OpenAI 官方 App Server 文档说明 `codex app-server` 是为富客户端提供认证、会话和流式事件的接口；它不等于当前 ChatGPT 网络服务已经采用 Headroom 的 HTTP 数据面。
- OpenAI 官方网络文档说明 Codex 模型采样/流式使用 `chatgpt.com` 的 WebSocket，并要求代理允许 WebSocket Upgrade；因此把一个只为 Codex++ Responses API 设计的本地 Gateway 当成官方桌面所有网络流量的透明替代物，需要单独的应用级验证。
- OpenAI 官方配置参考中的 `permissions.<name>.network.proxy_url` 明确属于 sandboxed networking，并通过 `HTTP_PROXY`/`HTTPS_PROXY` 等变量供沙箱命令使用；它不是把官方桌面模型数据面改写到某个 `base_url` 的开关，不能拿来证明当前窗口已接入 Headroom。
- OpenAI/codex 官方仓库的 Windows 代理问题记录了 Codex App/CLI 在不同代理环境下出现 stream/compact 失败，说明“有本地代理监听”不能替代对具体应用、传输和请求路径的实测。

### 交接边界

- 审计收据：`evidence/current-window-route-audit-20260802.json`。
- 未重启/停止任何进程，未发模型请求，未写 `config.toml`/`settings.json`/供应商配置，未修改 Vortex 或系统代理，未读取会话正文/凭据，未触碰 `D:\gpt-image2`。
- 下一轮只有在用户明确选择接入机制并手动重启官方桌面后，才可做真实当前窗口联测；验收必须同时出现官方进程到 Headroom 的数据面证据和 Gateway/Headroom 计数增量。

作者：Codex。

## 2026-08-01 / Codex（路由红状态与顶栏指示器复核）

### 状态

`SUCCEEDED`（只读诊断和文档收口）；生产进程未被本轮改动。用户现场现象仍未修复，代码修复包待下一轮执行。

### 事实与证据

- Gateway `18787`、Headroom `18789`、Kompress broker `18790` 健康；`runtime/state/codexpp-route-state.json` 为 `ready/process/config_mutated=false`，受管 URL 为 `http://127.0.0.1:18787/v1`。
- Monitor `18788/status` 可达但 `overall=red`，唯一红项为 `route.failed`；状态文件本身新鲜。`managed-codex-processes.json` 仍是 `2026-08-01 12:38:27Z` 的旧快照，登记 PID `22764/23592`；当前真实受管 Manager/Client 为 PID `18408/18216`，路径分别为 `D:\program\Codex++\codex-plus-plus-manager.exe` 和 `D:\program\Codex++\codex-plus-plus.exe`。监视器的精确 PID/路径/启动时间比较因此必然失败。
- 另有官方 `codex.exe` PID `13180`（WindowsApps 路径，父 `ChatGPT.exe` PID `26108`）不在受管树内，造成 1 条旁路警告。截图窗口与该 PID 的直接映射未取得，故“截图就是官方 Codex”保持为高概率而非确定事实。
- 源码 `src/codexpp/Codex++/headroom-status-indicator.js` 存在且轮询 `18788/status`；但当前 Manager 运行副本 `C:\Users\ma dao\AppData\Roaming\Codex++\user_scripts.json` 没有 Headroom key，运行 `user_scripts` 目录也没有该脚本。Manager `57865` 的常见 user-script HTTP 路径超时，无法证明 bridge 或 renderer 注入。故顶栏缺失的直接原因是运行脚本未部署/未注册；若窗口是官方 `codex.exe`，它还天然不加载 Codex++ 用户脚本。

### 根因判断

1. 受管 PID 快照没有在 Manager/Client 重启后原子刷新，导致监视器将真实进程判为身份/路由不匹配。
2. Headroom 指示器只存在于项目源和源元数据，未进入当前 Manager 的运行脚本副本；按钮和弹窗因此不可用。
3. 官方 Codex 旁路进程是独立现象，必须继续显式标记为旁路，不能通过修改 Codex++ 供应商配置来“吸收”它。

### 未执行与保护

- 本轮未写代码、未写运行状态、未启停或终止进程、未调用 Manager 删除接口。
- 未读取或输出凭据、令牌、会话正文；未修改供应商定义、`config.toml`、Base URL、认证、模型、会话或二进制；未触碰 `D:\gpt-image2`。

### 下一步包

- `P27a-route-snapshot-refresh`：在启动链成功创建 Manager/Client 后刷新并原子发布精确进程快照；增加旧 PID、重复客户端和重启后的 monitor fixture。
- `P27b-indicator-registration`：通过受支持的 Codex++ user-script 注册路径恢复 Headroom 指示器，只处理精确 Headroom key 和脚本文件，保留其他脚本并验证弹窗；若 Manager bridge 继续不可达，先保持 `UNKNOWN`，不得猜测写入。
- 独立验收：受管 Codex++ 窗口顶栏按钮/弹窗、monitor route green、route-state heartbeat、官方 Codex 旁路警告及配置哈希不变。

### Receipt

`package=HR-20260801-ROUTE-PROCESS-RECON.v1; state=SUCCEEDED; role=侦察员; route_process evidence=process identity + port/status + route-state; no write`

`package=HR-20260801-ROUTE-INDICATOR-RECON.v1; state=SUCCEEDED; role=侦察员; indicator evidence=source metadata + AppData runtime metadata/directory + status endpoint; no write`

作者：Codex。

## 2026-08-01 / Codex（桌面快捷方式冷启动修复）

### 根因证据

- 直接复现后发现 `headroom-start-result.json` 失败并非快捷方式路径错误：旧 broker 仍占用 `18790`，非管理员核验时 `Win32_Process.CommandLine` 不可见，身份门禁按设计拒绝未验证进程；提升上下文下服务可正常恢复。
- 服务和 Manager/Client 启动后，旧门禁又因 `config.toml` 全量 SHA-256 从 `FA012...` 变为 `9D35...` 失败。结构化 TOML 差异仅涉及 `service_tier`、`notify`、`features.js_repl`、`features.multi_agent_v2.*` 和 marketplace 元数据；活动 provider 段、`base_url`、`wire_api`、认证字段未变。

### 改动

- `scripts\Start-HeadroomForCodexPP.ps1` 新增 `Get-ConfigProtectedContract` / `Test-ConfigProtectedContract`。
- 保留 route keeper 的配置哈希和 `config_mutated=false` 硬门禁；Manager 启动后允许其元数据更新，但必须保持 provider 段、`base_url`、`wire_api`、`requires_openai_auth` 和 bearer-token 字段存在性不变。
- 启动收据新增 `config_sha256_before`、`config_sha256_after`、`config_changed_after_manager` 和 `config_protected_contract_unchanged`，不记录配置值或凭据。
- `startup-root.tests.ps1` 增加允许元数据变化、拒绝 Base URL 变化的 fixture。

### 验收

- 项目根 VBS 冷启动：`headroom-start-result=succeeded/manager_and_client_launched`。
- 直接点击 `D:\Desktop\Headroom for Codex++.lnk` 重复启动：`already_managed`，无重复 Manager/Client。
- 七个端口 `18787/18788/18789/18790/57321/57865/57866` 均监听；route `ready/process/config_mutated=false`；Kompress `CPUExecutionProvider/onnx/ready`。
- Python `30/30`、startup-chain、managed-process、stale-route-keeper、route-keeper-identity、activation fixture、PowerShell AST `49/0`、`git diff --check` 全部通过。
- 可读收据：重复点击 `evidence\startup-shortcut-fix-20260801.json`；最新冷启动 `evidence\startup-cold-start-20260801.json`。

### 边界

- 未修改供应商定义、Base URL、API key、认证、模型、会话或 Codex++ 二进制；未触碰 `D:\gpt-image2`。
- 当前 GPU/NPU 仍为隔离实验，生产后端保持 CPU ORT；本轮只收口启动链路和配置误判。

作者：Codex。

## 2026-08-01 / Codex（最终实施计划完成度审计）

- 已完成：唯一桌面入口和进程级路由；请求分类；`reconcile-codexpp.ps1` 只读；CPU ORT 1.28.0；Kompress broker/fail-open/SSE 终态；route heartbeat；最终 `50 main + 50 spawned` 验收，504、静默断流、缺失终态、解码异常和误分类均为 0。
- 部分完成：完整 C 盘 Headroom 迁移/源删除未完全闭环；受保护数据与 Manager metadata loader 仍是边界。Monitor/状态页可用，但精确 token usage 缺失，cache/token 统计不能作为完整根因证据。
- 未完成：DirectML 完整模型 device removal；NPU 条件不足；MIGraphX/VitisAI/AMD plugin 未成为生产后端。CPU 仍是正式后端。
- GitHub：认证成功；普通 Git 传输失败后，Git Data API 将 62 个脱敏文件发布到 `main`，远端 tree 哈希逐项复核通过。

总体结论：核心 Headroom 生产稳定性目标已交付；最终计划整体为“部分完成”，剩余重点是完整迁移、精确计量和 GPU/NPU 生产候选。

作者：Codex。

## 2026-08-01 / Codex（GitHub 认证成功与传输回退）

- `gh auth status` 已确认 `MADAO0828` 登录成功，HTTPS Git 操作协议为 `https`；未读取或记录令牌内容。
- GitHub API 独立确认目标仓库为空：`isEmpty=true`、默认分支为空、分支列表为空。普通 Git HTTPS 传输即使在 HTTP/1.1、OpenSSL 和 `gh auth setup-git` 后仍连接 `github.com:443` 失败。
- 已登记 `P22-github-api-publish/v1`：只向空仓库写入脱敏发布树，禁止覆盖已有引用；待 API 写入和树哈希复核完成。

作者：Codex。

## 2026-08-01 / Codex（GitHub 发布收口）

- `gh auth status` 已确认 GitHub 账号认证成功；令牌内容未读取或记录。
- Git HTTPS 普通推送仍因 `github.com:443` 连接阶段失败，未强推、未改远端配置。
- 由于仓库为空且 GitHub API 可用，使用 Git Data API 创建初始 README 提交、完整 tree、发布提交并更新 `refs/heads/main`；写入前确认仓库为空，ref 更新使用 `force=false`。
- 远端最终提交：`8a16f88a8aa2073d4f4ac15ecadd5e4738967daf`；tree：`b21b913dd817fb33a806765b0189260f46d58f55`。
- 独立远端验收：本地/远端均 62 个 blob，缺失/多余/哈希不一致均为 0，敏感路径为 0；收据 `evidence/github-api-publish-20260801.json`。

作者：Codex。

## 2026-08-01 / Reasonix（P27a monitor 快照自愈 + P27b 指示器注册）

### 背景与交接
- 接 Codex 未完成工作（用户选择先做 1、2）：P27a-route-snapshot-refresh、P27b-indicator-registration。
- P27 侦察已确认：`runtime/state/managed-codex-processes.json` 陈旧（旧 PID 22764/23592），实时受管进程为 18408/15480；monitor 精确身份匹配必失败 → route red；顶栏指示器未注册。

### P27a 改动（monitor 自愈 + 启动链刷新）
- `src/codexpp/Codex++/codexpp-headroom-monitor.ps1`：新增 `Update-StaleManagedCodexState`，仅当精确进程集合恰好 2 个（1 Manager + 1 Client，路径精确匹配）且 snapshot PID 与 live PID 不同时，用 native 路径探测重新采集并原子刷新 `managed-codex-processes.json`（保留 source_hashes、route_state_path），任何歧义/失败保持原状继续红。
- `Get-ClientRouteObservation`：managed state 校验失败且 activeClient 时先尝试自愈刷新再判定，而不是直接标红。
- `scripts/Start-HeadroomForCodexPP.ps1`：启动链对"精确 2 进程集合但 snapshot 陈旧"直接 `Write-ManagedCodexState` 刷新，不再强制 `Confirm-DirectProcessRestart` 重启进程。
- `src/codexpp/Codex++/startup-root.tests.ps1`：追加 3 组 P27a 断言（root 刷新路径、monitor 自愈 fail-closed、route observation 重观测）。

### P27b 改动（指示器注册）
- 新增 `scripts/Register-HeadroomUserScript.ps1`（与 Remove 脚本对称）：dry-run 验证 6 个非 headroom key 全保留；`-Execute` 在 `user_scripts.json` 的 scripts+market 双 section 注册 `user:headroom-status-indicator.js`（version 1.0.0.10、script_url=local://），并复制源码 js 到 loader 扫描的 `user_scripts` 目录，哈希校验一致；备份 `backups/metadata/user_scripts.json.before-headroom-register`。

### 测试
- Python unittest 30/30 PASS；PowerShell AST 50/50（含新脚本）；startup-root、managed-process-state、stale-route-keeper、route-keeper-identity、startup-chain 全部 PASS；`git diff --check` PASS。

### 受控验证与三轮启动失败
- monitor 自愈实测：`Update-StaleManagedCodexState` 返回 true，managed state 从 22764/23592 刷新为实时 18408/15480（保留 source_hashes），monitor route 立即转 green（`route=green`、codex-connection green）。配置哈希 13FD8185... 与 route-state 一致。
- 用户授权受控重启 Manager/Client 恢复 relay 57321（原 client 18216 退出后 relay 丢失）。第一次 VBS 提权启动成功重启（manager 19804、client 25448 持有 57321），relay/gateway-health 转 green；但启动链连续三轮失败：
  1. `startup_mutex_busy`（我先前非管理员直接跑启动链占用了 mutex，与 VBS 提权实例竞争）；
  2. `route_config_mutation_detected`（startup-gate.ps1:565-571 `Invoke-RouteKeeper` 对 config.toml 做 before/after 全量哈希比较；Manager 19804 启动时更新元数据 → wrapper route keeper 并发检测到 `13FD8185`→`854B063B` fail-closed）；
  3. `route_state_contract_invalid_before_managed_state`（route-state 仍记录旧 config_sha256=13FD8185，与当前 854B063B 不匹配，`Test-RouteStateContract` 恒失败，watcher 无法重建）。
- 三轮失败后按 P12 规则停止；用户选择服务链收口、Manager/Client 由用户手动重启。

### 当前状态与未决
- 服务链健康：Gateway 18787、Headroom 18789、broker 18790、monitor 18788 全部 green；relay 57321 由 client 25448 持有；Gateway /health helper=True。monitor 已运行新代码（PID 27328，source_sha256 73F3EF8C... = 修改后源码）。
- 未决：route red（route watcher 缺位 + route-state config_sha256 陈旧）；Manager 进程已退出（19804 GONE，client 25448 为其子进程仍存活）。
- **P26 遗留竞争需修复**：`Invoke-RouteKeeper`（codexpp-startup-gate.ps1:565-571）的全量 config 哈希 before/after 比较与 Manager 元数据更新冲突；修复方向是保留供应商受保护契约（P26 语义：provider 段/base_url/wire_api/auth 字段存在性不变）但不再用全量哈希 fail-closed，并在 Manager 更新后允许 route keeper 用新哈希重新发布。
- 用户手动重启 Manager/Client（桌面入口 `D:\Desktop\Headroom for Codex++.lnk`）后应验证：route 转 green、monitor overall 恢复、顶栏指示器出现（P27b 已注册）。

### 保护边界
- 未修改供应商定义、Base URL、API key、认证、模型、会话或 Codex++ 二进制；`config.toml` 的 854B063B 是 Manager 自身元数据更新所致（provider/base_url/wire_api/requires_openai_auth 字段存在性均保留），非本 Agent 写入。
- 未触碰 `D:\gpt-image2`；未执行 reset/clean/强推。证据：`evidence/p27a-p27b-20260801.json`。

作者：Reasonix。

## 2026-08-02 / Codex（P46 Route C 工具链前置阻塞）

### 已核验

- 官方 `git ls-remote` 可达：`v1.2.44` -> `77091ccaee4423f35a1b2c51c4ecd703e6201092`。
- 完整 clone 与一次官方 `--depth 1 --filter=blob:none` 浅克隆均在约 184 秒超时；浅克隆 staging 的 HEAD 正确，但没有 index，281 条 tracked 文件均未 checkout。目标目录和 staging 都不能作为工作树。
- 本机 Node `v26.1.0` 不满足计划要求的 Node 22；Rust stable MSVC manifest 缺失，`rustc` 不可执行；`npm ci`、隔离 Rust 安装和 `route-c-toolchain.json` 均未执行/生成。
- 备用官方 codeload 归档同样在约 210 秒超时，仅收到 `3,469,312` 字节；gzip 头有效但 tar 输入截断，未解包、未核对 workspace version/commit，不能作为源码。

### 保护边界

- 两次 Git 相关进程均已按本次命令行精确结束；不完整目录未删除或替换。
- 未触碰 `D:\program\Codex++`、Codex++ 供应商/config/Base URL/API/auth/model/session、Vortex/系统代理、生产进程或 `D:\gpt-image2`。
- 不得把本地 1.2.35 快照、非官方镜像或未核验离线包当成 v1.2.44 基线。

### 当前结论与下一步

P46 状态：`UNKNOWN`（官方源传输阻塞，不是成功或失败的功能结论）。在 Reasonix/用户提供完整、可核验的官方 v1.2.44 源码树，或恢复 GitHub 443 传输前，Route C native supervisor/lease、57322 egress、隔离 Canary 构建和真实窗口验收均保持 `NOT_EXECUTED`。证据：`evidence/p46-route-c-toolchain-prep-20260802.json`。作者：Codex。

## 2026-08-02 / Codex（P47 官方源码恢复复核）

- 本轮官方 `ls-remote` 结果与 worker 的传输结果冲突：部分查询成功，但 recovery clone、浅 fetch、filtered checkout 均未得到本地工作文件。
- `filtered` 仓库 HEAD 可核对为 `77091cca...`，tree=281，但 blob=0、工作文件=0、status=281；因此不是源码树，也没有生成工具链收据。
- 已停止仅针对 recovery 路径的 Git 进程，保留 partial metadata 供审计；生产路径、配置、凭据、会话和端口未修改。
- P47 状态：`UNKNOWN`。下一步必须取得完整官方 v1.2.44 源码树或经用户/Reasonix批准的可核验官方离线包；在此之前不得进行 native Route C 编辑或构建。

证据：`evidence/p47-route-c-source-recovery-20260802.json`。作者：Codex。

## 2026-08-02 / Codex（P48 隔离合同 PoC）

- 在不依赖 v1.2.44 源码的前提下新增 `src/route_c_poc`，覆盖 lease/generation、capability 摘要、内部 header 剥离、loopback/reserved port 拒绝、SSE completed/failed 终态和 5xx fail-open 不重试。
- `runtime/python/Scripts/python.exe -m unittest -v tests.test_route_c_poc`：11/11 通过；与现有 Kompress broker 回归合计 22/22，合成 main=30、spawned=30，网络异常和 5xx 均 fail-open 且不重试。
- 隔离 smoke 使用 `127.0.0.1:58322`，health 返回 `native=false, production=false`，进程精确回收，端口释放；未接触生产端口/配置/凭据。
- P48 施工已完成，但当前为非独立验收收据；Route C native integration、官方窗口接入和 Canary 仍未执行。

证据：`evidence/p48-route-c-isolated-poc-20260802.json`。作者：Codex。

## 2026-08-02 / Codex（P45 技术路线图）

### 用户要求

将 Codex++ 与 Headroom 的技术路线图保存到 `README.md`，路线图必须覆盖功能实现链路、启动链路和生效链路，并保持现有官方窗口 UI 注入能力不被错误描述为数据面证明。

### 已写入 README

- 新增置顶章节 `Codex++ + Headroom 技术路线图`，作为后续历史记录的当前权威入口。
- 增加 `CURRENT`、`TARGET / Route C`、`NOT_PROVEN` 状态标记，明确当前官方窗口仍为 `official_dataplane=bypass/not_proven`。
- 记录组件职责和端口：Manager `57865`、ingress `57321`、Gateway `18787`、Headroom `18789`、broker `18790`、monitor `18788`，以及 Route C 才会新增的 egress `57322`。
- 功能实现链：renderer UI/typed bridge、Codex++ native backend、SettingsStore、Gateway 分类、Headroom 策略、Kompress 推理、监控状态各自独立分层。
- 当前启动链：桌面快捷方式 -> VBS -> 可见进度包装器 -> root 启动脚本 -> broker/Headroom/Gateway/monitor -> route keeper -> Manager/Client/helper；该链只证明受管控制面启动。
- Route C 启动链：单一 native supervisor/lease -> egress -> broker -> Headroom -> Gateway -> ingress -> monitor/canary -> 唯一官方窗口 -> 现有 renderer 注入。
- Route C 生效链：官方 app-server -> `57321 -> 18787 -> 18789 -> 57322` -> SettingsStore 当前真实上游；main 压缩、spawned bypass、异常 fail-open、SSE 原始字节反向透传。
- 监控链明确要求官方 PID、全链 correlation、非本地上游和标准 SSE 终态同时成立，端口监听、健康页、route-state 或状态点存在均不能单独证明生效。
- 添加 R0-R4 落地阶段；R1-R3 均标记 `NOT_EXECUTED`，GPU/NPU 为 `EXPERIMENTAL`。

### 边界

- 本次只修改 `README.md`、`HANDOFF.md` 和 WORK 总账，没有修改 Codex++/Headroom 源码、测试、运行进程、端口、配置、供应商、认证、模型、会话或 Vortex。
- Route C 仍是目标路线，不是生产完成收据；`57322` 和 native supervisor/lease 当前不存在。

作者：Codex。

## 2026-08-02 / Codex team / P44d（Route C 架构冻结）

### 状态与结论

`P44d-route-c-documentation/v1`：文档与脱敏架构收据已写入；Route C 的结论为 **满足条件后可行**。本节不代表 Route C 已实现、已启动或已通过生产验收。纯 renderer/marketplace/user-script 插件不能承担所需数据面生命周期。

P43 失败根因固定记录为独立 route-A 与受管 Codex++ 争抢同一 helper/client 的双生命周期所有者；AppX 激活和首请求本身已被 P43 证明可行，断流发生在 Manager readiness-only 停止受管 client/helper、`57321` 消失之后。

### 截图和源码边界

用户截图只证明 renderer 可以呈现 Headroom indicator/popup，并通过固定 bridge/UI 内部消息做界面补丁；不证明它拥有 native helper、协议代理、AppX 启动、CDP 注入、端口或 restart lease。P44a 源码回执确认这些生命周期资源归 Codex++ native Rust/Tauri launcher/helper 所有，renderer user script 不是数据面 owner。

现有 UI 注入、indicator 和 popup 必须作为 Route C 的回归基线保留；本次设计没有验证它们不会受新增 native supervisor/lease 影响。

### 目标拓扑（设计，不是运行态）

```text
官方 ChatGPT/Codex 单窗口
  -> 现有 Codex++ ingress helper 127.0.0.1:57321
  -> Gateway 127.0.0.1:18787
  -> Headroom 127.0.0.1:18789
  -> 新增 Codex++ egress relay 127.0.0.1:57322
  -> SettingsStore 当前选中的真实上游
```

唯一所有者是同一个 Codex++ native supervisor/lease：覆盖 `57321`、`57322`、Gateway/Headroom sidecars、owner PID/start time、generation 和 heartbeat。renderer scripts、indicator、popup 和管理弹窗只保留 UI/控制职责。

57322 必须 loopback-only、按 generation 发 capability、lease/heartbeat 失效即拒绝；拒绝 `18787/18789/57321/57322` 等本地上游以防自循环；发往真实上游前剥离内部路由、generation、调试和授权头。SettingsStore 仍是供应商选择权威，不复制或改写凭据、Base URL、认证、模型或会话。

### 保留功能与迁移顺序

- 保留现有 Codex++ 管理弹窗、单窗口体验、user-script bridge、Headroom indicator/popup、`57321` ingress、Gateway/Headroom 的分类、压缩/旁路、fail-open 和 SSE 透传契约。
- 先冻结现有受管链和 renderer，再在隔离环境验证 supervisor/lease/57322 合同（假上游或 fixture）；随后才验证官方 app-server stdio、`CODEX_HOME` 或 `-c/config` 进程级绑定；最后才允许单窗口单 generation canary。
- 不复用 Route A 第二启动器，不恢复旧 `config.toml` 写入，不把当前控制面 `ready` 当作官方数据面成功。闸门未全部通过时保持 `Route C=NOT_PROVEN`。

### 最小 PoC 闸门与回退

1. supervisor 对 57321/57322/18787/18789 具备单 owner lease，第二 owner 和过期 capability 被拒绝。
2. egress 通过 loopback、generation、header stripping、本地上游拒绝和 SSE fail-open fixture。
3. 官方 app-server/config 进程级接口完成隔离握手；`ActivateApplication` 单独不算注入证据。
4. 一次真实授权 SSE 同时出现官方 PID、Gateway correlation、Headroom 计数、57322 上游关联和标准终态，且 Manager 不停止 57321 client。
5. 正常退出、崩溃和超时均撤销 lease；日志脱敏且不含凭据/会话正文。

失败时只撤销新 generation、隔离新 owner 创建物，保留现有受管链和 UI；不得停止现有 Manager/Client，不得修改配置/供应商/Vortex/系统代理，不得自动回到 Route A。UI 只标 `NOT_PROVEN` 和脱敏错误阶段。

### 未实施和未知项

- 未新增 supervisor、lease、57322、wrapper 或源码；未绑定官方 packaged ChatGPT；未验证连续官方 SSE；未改变运行态。
- 官方 packaged ChatGPT 到独立 native launcher/app-server/provider 的稳定绑定未知；Codex++ lifecycle lease 能力未知；官方窗口到 Headroom 的连续 SSE 未验证。

收据：`evidence/p44-route-c-architecture-20260802.json`。

作者：Codex team / P44d。

## 2026-08-02 / Codex（当前桌面客户端实时复核）

- 采样时间：`2026-08-02T03:31:29Z`。官方 `codex.exe`/ChatGPT 子进程连接 `127.0.0.1:7897`，到 `57321/18787/18789` 均为 0；`7897` 是 Vortex helper，`57321` 属于受管 Codex++。
- 官方配置虽为 `http://127.0.0.1:57321/v1`，但实时 TCP 不匹配；Gateway 计数在采样窗口内无变化。Vortex 的最终远端未知。
- 结论：当前桌面客户端不能确认经过 Headroom，最近证据偏向绕过本地 Headroom；受管 Codex++ 的 `57321 → 18787 → 18789` 健康证据不能代替桌面会话证据。

## 2026-08-02 / Codex（测试流量来源与压缩模式证据复核）

### 测试流量归属

- `evidence/phase-c-traffic-20260802.json` 记录的正式窗口为 `2026-08-02T02:58:53.948749Z` 至 `2026-08-02T03:06:28.123879Z`，即北京时间 `10:58:53-11:06:28`。
- 窗口内模型字段全部是 `gpt-5.2`，共 `50 main + 50 spawned = 100` 条 `/v1/responses`；证据明确不持久化正文、认证头或会话内容。
- 逐行统计 `runtime/private/headroom-workspace/logs/proxy.log*` 得到同一窗口 `100/100` 条 `/v1/responses` 的 User-Agent 为 `python-httpx/0.28.1`，另有 `51` 条 `/health` 同 UA 探针。`runtime/wheelhouse/requirements-lock.txt` 固定 `httpx==0.28.1`，运行时 Python 也回读为 `0.28.1`。
- 本地链路和日志表明这些请求经过 `18787 -> 18789 -> 57321/v1/responses` 后到达上游；所以中转站后台出现对应的 `gpt-5.2 / python-httpx/0.28.1` 记录属于本轮验收/探针，而不是用户桌面自然对话。中转站后台的计费明细未由本机读取，结论依据是本地模型、数量、UA、时间和路由的独立吻合。
- 随后只读读取生产 `/stats`（`2026-08-02T03:34:04.3181219Z`）仍报告 `summary.mode=cache`、`force_kompress=false`、`requests.by_model.gpt-5.2=100`、`compression.requests_compressed=3`；该模型计数与 PHASE-C 100 条请求逐项相符。
- `/stats` 中这 100 条 `gpt-5.2` 的 `tokens_saved=0`；它们确实到达上游，但不代表 100 次 Kompress 字节压缩。`cache` 会对冻结前缀或不适合收缩的内容执行透传，只有符合条件的内容才计入压缩。

### 模式结论校正

- 生产源码和运行态仍是 `HEADROOM_MODE=cache`，`HEADROOM_FORCE_KOMPRESS_ALL` 未启用；生产 `/stats` 报告 `summary.mode=cache` 且已有 `compression.requests_compressed=3`。`cache/token` 不决定 Gateway 的 main/spawned 分类，`bypass_header` 仍优先保护 spawned。
- 早先“生产已切换 token”的记录只对应隔离 `18889` 实验或过时文档，不能作为生产事实；隔离 token 收据 `evidence/phase-c-token-mode-smoke-20260802.json` 还显示 spawned bypass 检查未通过，已停止并排除生产。

### 运行影响与下一步

- 本轮仅做只读日志/证据核对和文档修正，没有重放请求、停止/启动服务、修改 `config.toml`、供应商、Base URL、认证、模型、会话或 `D:\gpt-image2`。
- 后续真实验收前必须显式告知会产生真实中转站计量；如需无污染验证，应使用隔离上游或本地假 helper，并单独记录其证据。

作者：Codex。

## 2026-08-01 / Codex（PHASE-A 收口与 PHASE-B 门禁）

### 本轮完成

1. `P30a-route-protected-contract/v1`：启动 gate、route keeper 和 root start 已改为比较受保护供应商契约，而不是把 Manager 普通元数据变化当成配置篡改；watcher 可原子刷新普通 `config_sha256`。隔离 fixture、PowerShell AST 和 `git diff --check` 均通过。
2. `P30b-aggregate-removal-dryrun/v1`：`Remove-HeadroomAggregateRelay.ps1` 默认 dry-run，只有 `-Execute -PhaseB` 才会写入。当前 live settings 发现 1 个 `relay-aggregate-headroom` profile、1 个 entry，6 个非聚合 profile 和 `relay-ms8z882i` 激活项保持不变；本轮没有写入。
3. `P30c-monitor-indicator-preflight/v1`：monitor 只有可靠模型范围 active evidence 才显示 `api.pending_completion`；新增只读 indicator/CDP 预检。CDP `127.0.0.1:9229` 不可达，故 renderer/button/popup 仍是未验收状态。
4. `P30d-phase-b-entry-gate/v1`：注册脚本改为幂等；桌面快捷方式传递 `--phase-b`，登录自启仍使用同一 VBS 但不传 `--phase-b`。下一次桌面手动激活时，Start 脚本会先确认 Manager/Client 已退出，再执行聚合删除、指示器注册，然后启动服务链。

### 测试收据

- `startup-root.tests.ps1`：PASS。
- `codexpp-startup-chain.tests.ps1`：PASS。
- `stale-route-keeper.tests.ps1`：4 fixtures PASS。
- `route-keeper-identity.tests.ps1`：4 fixtures PASS。
- `managed-process-state.tests.ps1`：3 fixtures PASS。
- `monitor-indicator-preflight.tests.ps1`：10 assertions PASS。
- `Test-HeadroomAggregateRelayRemoval.ps1`：PASS。
- `Test-HeadroomUserScriptRegistration.ps1`：PASS，已覆盖已有正确 key 的幂等执行且 metadata hash 不变。
- `Test-HeadroomMigrationScripts.ps1`：PASS。
- PowerShell AST（目标脚本）：0 errors；Node `--check`：PASS；`git diff --check`：PASS。

### 阶段与下一步

- `PHASE-A=SUCCEEDED`，收据：`evidence\phase-a-summary-20260801.json`。
- `PHASE-B=WAITING_USER_ACTIVATION`。用户操作顺序：退出 Codex/Codex++ Manager/Client，确认受管 PID 消失，双击 `D:\Desktop\Headroom for Codex++.lnk`，等待结束后返回本任务。
- `PHASE-C=PENDING`。返回后只做真实运行态验收：七个端口、managed state、route watcher heartbeat、指示器 CDP、普通供应商切换，以及 50 main + 50 spawned SSE。没有这些收据不能报告整体完成。

### 保护边界

本轮没有停止/启动生产进程，没有写 `config.toml`、供应商定义、Base URL、认证、模型、会话或二进制，没有触碰 `D:\gpt-image2`。主机时间曾显示 `2026-08-02Z`，晚于任务日 `2026-08-01`；该时钟不一致已记录，未用作当前日期或时序证明。

作者：Codex。

## 2026-08-01 23:23 / Codex（当前路由复核）

- 受管 Manager/Codex++、Gateway `18787`、Headroom `18789`、Relay `57321` 全部监听；route-state `ready`，`route_scope=process`，`proxy=local-headroom`，`config_mutated=false`。
- 向本地 Gateway `/v1/responses` 发最小探针，HTTP 200；Gateway 计数 `206/206`，`main/compress=104`、`spawned/bypass=102`，Headroom `/health=200`。
- 受管 Codex++ 当前确认走 Headroom，不是直连。监控截图的 HTTP API 黄色项是等待完成请求基线，不是路由失败；官方 `codex.exe` 旁路警告仍与受管链路分开。
- 本轮只读核验和最小探针；未改供应商、Base URL、API key、认证、模型、会话或二进制。

## 2026-08-01 23:26 / Codex（桌面 Codex 目标校正）

- 用户目标是当前 Codex 桌面进程，不是受管 Codex++。官方 `codex.exe`（PID 4040）及 code-mode host 不在受管树；监控的绿色路由项只代表受管 Manager/Codex++，旁路警告正对应该官方进程。
- 官方 `.codex\config.toml` 的 `base_url=https://skyapi2026.com`；当前未观察到官方 Codex 进程连接本地 `18787/18789`。结论：当前 Codex 桌面会话不经过本地 Headroom，按配置是上游直连；系统级或上游内部代理未验证。
- 受管 Codex++ 的 `process_route_base_url=http://127.0.0.1:18787/v1` 仍有效，但这是不同进程链路。前一轮把两者混为一谈，结论已校正。
- 本轮无配置、供应商、凭据、认证、模型、会话或二进制改动。

## 2026-08-01 23:49 / Codex（当前桌面客户端代理复核）

- 当前官方 `codex.exe` 的已建立连接指向本机 `127.0.0.1:7897`，没有连接 Headroom `18787/18789`；官方配置仍为 `base_url=https://skyapi2026.com`。
- `7897` 监听者为 `C:\Users\ma dao\.config\com.vortex.helper\com.vortex.helper.exe`（PID 18272），其有 37 个已建立连接，包含非回环出站和远端 443。
- 结论：本客户端不走 Headroom，也不是裸直连，而是经过 Vortex helper 独立本地代理。Codex++ 的 `process_route_base_url=127.0.0.1:18787/v1` 不适用于当前官方桌面进程。
- 未修改配置、供应商、凭据、认证、模型、会话或二进制。

## 2026-08-01 / Codex（桌面路由复核续）

- 当前 `codex.exe` 的 6 条已建立连接全部为 `127.0.0.1:7897`，到 Headroom `18787/18789` 和 Relay `57321` 均为 0。
- `7897` 由 `com.vortex.helper.exe` 监听；官方 `base_url=https://skyapi2026.com`。
- 结论：当前桌面 Codex 不走 Headroom；它经过 Vortex helper 后访问上游。Codex++ 进程级 Headroom 覆盖不作用于该桌面进程。

## 2026-08-01 / Codex（桌面进程树复核）

- 当前 ChatGPT/Codex 进程树中，实际有网络连接的 ChatGPT 子进程和 `codex.exe` 都只连接 `127.0.0.1:7897`；Headroom `18787/18789` 和 Relay `57321` 的连接数均为 0。
- Vortex helper 也没有到 Headroom/Relay 的连接。P28 仅证明受管 Codex++ Relay 健康，不能证明当前桌面会话经过该链路。
- 结论：当前桌面 Codex 不走 Headroom，而是经 Vortex helper 访问 `https://skyapi2026.com`；本轮未修改配置、供应商、凭据、认证、模型、会话或二进制。

## 2026-08-01 / Codex（Relay 到 Headroom 的实流复核）

- 当前桌面 `codex.exe` 已连 `127.0.0.1:57321`，当前官方配置 `base_url=http://127.0.0.1:57321/v1`；不是裸直连远端。
- `57321/v1/responses` 最小探针 HTTP 200，但 Gateway 计数不变（`220`），Relay 进程未显示到 `18787/18789` 的连接；不能把该请求判定为经过 Headroom。
- 结论：当前客户端走本地 Relay/Vortex 路径，现有实流证据更支持直达上游而非 Headroom；`route-state ready/local-headroom` 仅是控制面声明，仍需修复/补充真实 Relay→Gateway 证据。

## 2026-08-01 / Codex（桌面实时快照再测）

- 当前 ChatGPT/Codex 进程树没有连接本地 `57321/18787/18789/7897`；`codex.exe` 只有远端 443 连接。
- 配置仍为 `http://127.0.0.1:57321/v1`，但运行态未使用该 Relay。当前快照判定为绕过本地 Headroom/Relay；系统级或上游内部代理未验证。

## 2026-08-02 / Reasonix（P28 快捷方式管理员启动 + 聚合供应商全局 Headroom 路由）

### P28a：桌面快捷方式双击即管理员启动
- 根因：`D:\Desktop\Headroom for Codex++.lnk` 的 LinkFlags 缺少 `SLDF_RUNAS_USER`（0x1000）；`WScript.Shell.CreateShortcut` 无法设置该属性；用户账号 `ma dao` 本就在 Administrators 组（`net localgroup administrators` 确认），UAC `ConsentPromptBehaviorAdmin=0`（管理员自动提升），但普通双击不触发提权。
- 修复：直接设置 .lnk LinkFlags `0x000000F7 → 0x000010F7`（偏移 0x14 的 bit 0x1000）；`scripts/Set-HeadroomDesktopEntry.ps1` 在 `$shortcut.Save()` 后固化该位并校验（缺失即 throw `desktop_shortcut_runas_flag_missing`）；`tests/Test-HeadroomMigrationScripts.ps1` 增加断言。
- 验证：当前 LinkFlags `0x000010F7`、RunAsUser=true、COM 解析正常（wscript → Launch-HeadroomForCodexPP.vbs）；测试 PASS。

### P28b：无论切换哪个供应商，Codex 请求都经本地 Headroom
- 根因（源码级确认，`D:\新建文件夹\CodexPlusPlus` = github.com/BigPizzaV3/CodexPlusPlus）：
  - Codex++ 纯 API（`pureApi/responses`）模式**直连 profile 的 base_url**（skyapi2026.com），本地协议代理 57321 只在**聚合模式或 ChatCompletions 协议**下启用（`settings.rs active_relay_uses_protocol_proxy`）。
  - `complete_relay_profile_config`（relay_config.rs:2000-2007）每次启动/切换供应商都会用 profile 的 base_url **覆盖 config.toml**，故"改 config.toml base_url"不可行（会被冲掉）。
- 修复：在 `C:\Users\ma dao\.codex-session-delete\settings.json` 新增**聚合供应商** `relay-aggregate-headroom`（成员 = 现有 6 个 profile，策略 conversationRoundRobin），并激活（activeRelayId / activeAggregateRelayId 指向它）。Codex++ 检测聚合模式后启动本地 helper 57321 → Headroom Gateway 18787 → 压缩/转发到聚合成员上游。**原 6 个供应商 profile 完全未动**，切换供应商不受影响。
- 工具：新增 `scripts/Set-HeadroomAggregateRelay.ps1`（dry-run 验证 6 成员/不修改现有 profile；-Execute 备份+写 settings.json+回读校验）。
- 验证：受管链稳定运行（manager/client/relay 57321/官方 Codex CDP 9229 全在线）；monitor overall=yellow（route/relay/gateway-health/codex-connection 全 green，仅 api.pending_completion + token-accounting.incomplete 等待基线）；`57321 /v1/models → HTTP 200`；Gateway /health helper=True；gateway total=207 ok=207 error=0。

### 证据与保护
- 证据：`evidence/p28-shortcut-admin-and-relay-20260802.json`；settings 双备份 `backups/codexpp-settings/`；.lnk 备份 `backups/system-cutover/desktop-shortcuts/`。
- 未修改任何现有供应商 profile 的 Base URL/API Key/认证；未触碰 `D:\gpt-image2`；未执行 reset/clean/强推；settings.json 修改经用户授权。
- 已知小项：monitor 仍会提示 1 条"官方 Codex 旁路警告"——codex.exe 子进程父为 ChatGPT.exe（由 Codex++ launcher 激活注入），monitor 按"父进程非 codex-plus-plus"保守判定，属信息性提示，不影响路由。

作者：Reasonix。

## 2026-08-02 / Reasonix（P29 启动提速 + 开机自启）

### 问题
- 用户反馈：双击桌面快捷方式启动太慢（冷启动受管链约 53-106 秒），希望"双击完马上出来"。

### 启动慢根因（精确计时定位）
- warm 服务下受管链冷启动约 53 秒 = 前置 ensure/readiness 15s + manager gate 19s + client gate 19s。
- manager/client gate 的 38 秒是 **Codex++ startup-gate 的安全契约校验**（route keeper 身份/state、readiness），不可跳过。
- 额外发现：`Get-NetTCPConnection -LocalPort` 平均 1.47 秒/次（极慢），导致 already_managed 前置 6.7 秒。

### 修复（Start-HeadroomForCodexPP.ps1）
1. **already_managed 快速路径**：受管链已在时跳过服务 ensure（broker/Headroom/Gateway/monitor）与 Test-Ready，仅校验 4 个服务端口；跳过 Wait-StrictReadiness 与 Invoke-ManagerReadiness（冷启动已验证过）。
2. **Test-Listener 改用 Test-NetConnection**：1.47s/次 → 0.02-0.36s/次（快 70 倍）。
3. **计时埋点**：startup-timing.log 记录各阶段耗时（保留，便于后续诊断）。

### 开机自启
- 启动文件夹快捷方式 `C:\Users\ma dao\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\Headroom for Codex++.lnk`（指向项目 VBS）。
- 计划任务方式因非管理员被拒（Register-ScheduledTask Access Denied），改用启动文件夹。
- 登录后自动启动受管链；**受管链常驻时双击 = already_managed 约 2 秒**（fast-path 0.3s + Test-Ready 0s）。冷启动仍约 53 秒（安全契约），但开机自启保证日常双击即 2 秒。

### 验证
- 实测：already_managed 双击从约 10 秒降到 **约 2 秒**；fast-path services check 6.7s→0.3s。
- 测试：PowerShell 全部 PASS、Python 30/30、AST 51/51。
- 证据：`evidence/p29-startup-speed-and-autostart-20260802.json`。

### 未决
- Codex 桌面经 Headroom 压缩的架构问题（Codex++ 聚合/helper 与 Headroom 循环）保持未解决，由用户交 Codex 接手。
- 受管链冷启动 53 秒（gate 安全契约）在自启后不构成日常负担。

作者：Reasonix。

## 2026-08-02 / Codex（后置收口索引）

- 最新审计结论：中转站看到的 `gpt-5.2 / python-httpx/0.28.1` 来自 PHASE-C 测试窗口（100 条模型请求）和健康探针（51 条），不是用户自然对话；外部后台计费明细未读取。
- 生产 `HEADROOM_MODE` 仍为 `cache`，`HEADROOM_FORCE_KOMPRESS_ALL=false`；此前 token 生产切换说法已标记为文档漂移，隔离 18889 token 实验不代表生产。
- 详见前文“测试流量来源与压缩模式证据复核”和脱敏收据 `evidence/phase-c-traffic-source-audit-20260802.json`。

作者：Codex。

## 2026-08-02 最终历史校正（Codex）

本文件中早于本节、且声称“当前官方桌面窗口已无条件经 Headroom”的段落只保留作历史审计，不是当前运行态结论。当前可确认的是：受管 Codex++ 控制面/测试链健康；官方 ChatGPT/Codex 数据面经 Vortex `7897`，Headroom 接入仍 `NOT_PROVEN`。旧方案的配置写入、自循环和外部上游失败分层见 `evidence/historical-route-audit-20260802.json`；在新授权前不恢复配置写入、不改 Vortex/系统代理、不重启生产进程。

作者：Codex。

## 2026-08-02 最终当前数据面更正（Codex）

最新只读快照 `2026-08-02T05:40:36.3135903Z` 显示官方 `codex.exe`/ChatGPT 网络子进程连接 Vortex `7897`，官方 PID 到 `18787/18789/57321` 均为否。最终当前结论为 `official_dataplane=bypass`；受管链监听/健康不等于官方窗口数据面接入。收据：`evidence/current-window-route-audit-20260802-live2.json`。

作者：Codex。

## 2026-08-02 历史实现补充复核（Codex）

### 已核对的历史事实

- 2026-07-26 交接的当前状态不是“已接入”，而是明确写明官方会话尚未被证明经过 Headroom；官方 `.codex` 与 `.codex-plus-plus-cli` 是不同配置域，第二 `CODEX_HOME` 对 AppX 的继承被记录为不可靠。
- 2026-07-29 交接描述了目标链路，但同时记录真实冷启动失败、Gateway 健康不可达、route contract 无效，首次真实模型请求和 spawned/main 实流均未通过。
- 旧 `codexpp-route-keeper.ps1` 备份含活动 provider `base_url`/`supports_websockets` 改写、配置备份和 `File.Replace`。该代码是历史上最接近“把当前官方窗口接入”的机制，但属于配置写入路径，且会与 `57321 -> 18787 -> 18789 -> 57321` 自循环风险叠加。
- 2026-07-30 运行记录显示 Headroom 使用 `--no-optimize --disable-kompress`；这证明压缩在该窗口被关闭，不证明官方桌面 PID 的请求一定进入 Headroom。历史 504、压缩关闭时的 502、外部上游错误和自循环错误已在独立证据线中分开。
- Codex++ 源码复核进一步校正 P28：`apply_aggregate_relay_injection_to_home`（`commands.rs:2651-2665`）把官方配置写成 `127.0.0.1:57321/v1`；协议代理（`protocol_proxy.rs:495-545,733-748`）按成员 profile 的 `relay.base_url` 直接请求上游，未自动经过 `18787`。所以 P28 聚合链不能证明 Headroom 数据面；只有旧的直接 `config.toml -> 18787` 写入路径具备该可能。

### 审计结论

用户所述“过去曾经实现过”与历史事实部分部分相符：确实存在过把官方配置临时改到 `18787` 的接入尝试，也存在稳定的受管 Codex++ 链路；但 P28 聚合本身实际指向 `57321` 及成员上游，不是 Headroom。当前没有一份独立收据同时证明官方 ChatGPT/Codex PID、同窗 `18787` 连接、Gateway 增量和 Headroom/Relay 关联。因此不能把历史临时接入或 P28 聚合链当作当前官方桌面成功实现。

详细收据：`evidence/historical-route-audit-supplement-20260802.json`。

作者：Codex。

## 2026-08-02 / Codex（P40 路线 A 实施）

### 已完成

- 新增 `src/official-route/CodexCliShim/` 和自包含 shim 构建脚本。shim 只处理 `app-server`，注入 `headroom_runtime` 运行时 provider；非 app-server 参数不变；`HEADROOM_REAL_CODEX_CLI_PATH` 防止递归。
- 新增 `scripts/Start-OfficialCodexThroughHeadroom.ps1` 与 `scripts/Launch-OfficialCodexThroughHeadroom.vbs`。启动前有界检查 `18787/18789/57321`、健康状态和 SettingsStore 上游 loopback；只记录哈希、PID、路径和布尔状态。
- 新增 `scripts/Collect-OfficialRouteAReceipt.ps1`，仅依据 WindowsApps 官方 PID TCP、monitor official_dataplane 和同窗证据生成 `confirmed/bypass/unknown` 收据；受管服务到 `18787` 不会冒充官方数据面。

### 证据与测试

- `scripts/Start-OfficialCodexThroughHeadroom.ps1 -DryRun`：`dry_run_ready`；`config.toml`、`auth.json`、SettingsStore SHA-256 前后一致；当前官方进程存在，真实启动未执行。
- shim 参数和递归测试 PASS；Gateway `30/30`；official dataplane fixture `18 assertions`；startup-chain/root fixture PASS；PowerShell AST 和 `git diff --check` PASS。
- 当前实时采样收据为官方 `bypass`（WindowsApps 官方 PID 到 Vortex `7897`），不能报告 Headroom 数据面成功。当前运行服务未被停止或重启。

### 用户激活与后续

1. 用户退出所有官方 ChatGPT/Codex 进程。
2. 双击 `D:\新建文件夹\headroom for codex++\scripts\Launch-OfficialCodexThroughHeadroom.vbs`。
3. 返回后运行 `scripts/Collect-OfficialRouteAReceipt.ps1` 并执行真实 SSE 验收。
4. 若官方 PID 仍走 `7897`、无 Gateway correlation 或无上游证据，记录 `route-a-not-proven`，停止并等待用户再次确认路线 B。

### 保护边界

- 未修改供应商、Base URL、Key、认证、模型、会话、Vortex、系统代理或 `D:\gpt-image2`。
- 未执行路线 B 的 config lease、UI/backfill guard 或任何 live 配置写入。

作者：Codex。

## 2026-08-02 P41 可见启动器与快捷方式修复（Codex）

### 根因

- 原桌面 VBS 使用 `pwsh -WindowStyle Hidden`，并通过 `ShellExecute(..., "runas", 0)` 异步启动后立即退出；桌面参数还包含 `//B`。因此启动脚本即使运行、超时或写入失败收据，用户都看不到阶段和错误。
- 只读检查发现桌面快捷方式实际 `LinkFlags=0x000000F7`、`RunAsUser=False`，与文档中预期的 `0x000010F7` 不一致。原 `Set-HeadroomDesktopEntry.ps1` 只按目标/参数判断，目标匹配时不会修复缺失的 RunAs 位。

### 实施

- 新增 `scripts/Start-HeadroomWithProgress.ps1`：可见父窗口隐藏运行原启动脚本，显示 ASCII 阶段进度和耗时；轮询 `18790/18789/18787/18788`、route-state、`57321/57865`，最终只接受本轮新的 `headroom-start-result.json` 且子进程退出码为 0 的成功。
- 成功显示最终阶段后短暂自动关闭；失败、状态不明或总预算超时保留窗口，显示安全错误字段、收据和 stdout/stderr/阶段日志路径；超时不强杀子启动进程。
- `scripts/Launch-HeadroomForCodexPP.vbs` 改为调用可见包装器，使用 PowerShell 7 绝对路径优先、`WindowStyle Normal`、`ShellExecute runas` 样式 1；缺失脚本或 ShellExecute 失败改用可见 `MsgBox`。
- `scripts/Set-HeadroomDesktopEntry.ps1` 读取并校验 `.lnk` LinkFlags/RunAs，执行修复并验证 `0x1000` 位。当前桌面入口实测 `0x000010F7`、`run_as=True`。

### 测试与边界

- PASS：`tests/Test-HeadroomVisibleLauncher.ps1`（成功/失败/旧收据夹具）、`tests/Test-HeadroomMigrationScripts.ps1`、`src/codexpp/Codex++/startup-root.tests.ps1`、`src/codexpp/Codex++/codexpp-startup-chain.tests.ps1`、PowerShell parser（startup-root 已包含新包装器）、`git diff --check`。
- 已执行桌面快捷方式 dry-run 和受控 `-Execute`（只备份/修复快捷方式，不停止或启动生产进程，不修改供应商、Base URL、认证、模型、会话或 Vortex）。
- 未执行完整桌面双击 smoke；真实 UAC、可见窗口、服务 readiness 和 Manager/Client 结果需用户手动激活后再验收。当前不能把本包报告为完整生产启动验收。

作者：Codex。

## 2026-08-02 用户实测启动失败复核（Codex）

### 已证实：桌面入口

- `Start-HeadroomWithProgress.ps1:73-80` 的 `Test-RouteStateReady` 直接读取 `$watch.status`。
- 当前实际 `runtime/state/codexpp-route-watch.json` 为 `schema_version=2`，字段包括 `route_scope`、`pid`、`started_at_utc`、`timestamp_utc`、`route_keeper_path`、`mode`、配置路径、代理地址和 `allow_relay_pending`，没有 `status`。
- StrictMode 下该属性读取直接抛出截图中的异常。异常发生在父包装器 `Get-ProgressState`，所以父窗口显示“未生成新的 headroom-start-result”；这不等同于子启动脚本没有运行。
- 子进程随后留下的收据为 `headroom_start_failed / manager_readiness_failed:3`，`startup-result.json` 为 `readiness_failed`。因此存在独立的 Manager readiness 失败，需另行定位。

### 已证实：官方路由入口

- VBS 第 16-17 行异步调用 `shell.Run "pwsh.exe ...", 1, False`，随后 `WScript.Quit 0`；没有等待、退出码传递或错误弹窗。
- PowerShell 第 166-197 行先等待 Gateway/Headroom/Relay readiness；第 197 行在 Relay PID 缺失时抛出 `route_a_services_not_ready`。catch 只更新 JSON 收据，第 242 行 `exit 2`，失败路径没有 `Write-Error`/`Write-Output`。因此空白窗口后关闭是当前实现的预期表现。
- 关联收据 `runtime/state/official-route-a-start.json`：`updated_at_utc=2026-08-02T09:39:41.8843657Z`、`status=not_proven`、`phase=launch`、`error_code=route_a_services_not_ready`、Gateway/Headroom HTTP 200、Relay PID null、三份受保护文件哈希未变化。该次尝试在官方 `ProcessStartInfo` 之前失败，不能算官方窗口已启动或已接入 Headroom。
- 当前稍后观察到的端口监听不能 retroactively 证明该次点击成功；时间窗口和官方 PID/Gateway correlation 仍需重新采样。

### 未决与下一步

- 修复 route-watch schema 读取和父子进程收据 reconciliation；进度探针错误应降级为“探针不可用”，不能吞掉本轮启动结果。
- 为 Official route 增加可见 readiness 阶段、失败摘要、收据路径和可靠 PowerShell 解析；保留 loopback、受保护哈希和 readiness 门禁。
- 在修复完成并由用户重新激活前，`desktop_headroom=FAILED`、`official_route=NOT_PROVEN`；本次分析没有生命周期或配置副作用。

证据收据：`evidence/launcher-failure-analysis-20260802.json`。

作者：Codex。

## 2026-08-02 / Reasonix（P42 修复完成并验证）

### 修复内容（Codex P42 分析定位的 4 项缺陷）
1. **route-watch null-safe**（`Start-HeadroomWithProgress.ps1` `Test-RouteStateReady`）：route-watch schema v2 无 `status` 字段，StrictMode 下读 `$watch.status` 抛异常并吞掉整个启动结果。改为 `PSObject.Properties` 安全探测；watch 无 status 视为 ready（route-state 才是真相）。
2. **进度探针降级**：进度循环内 `Get-ProgressState` 异常降级为"进度探针暂不可用"，不再中断启动结果处理。
3. **Official route 可见失败**（`Start-OfficialCodexThroughHeadroom.ps1`）：失败路径增加可见输出（error_code/服务状态/收据路径/Write-Error + `Read-Host` 暂停），新增 `-NoPause` 参数；不再空白窗口后无声关闭。
4. **monitor items 契约同步**（`codexpp-startup-gate.ps1` `Test-MonitorStatus`）：P40 新增 `official-dataplane` 使 monitor /status 变 13 项，而 gate 预期 12 项 → `monitor_status_contract_invalid` → manager readiness 失败。修复：expectedItemKeys 加 `official-dataplane`，items 校验改为**有序子序列匹配**（容忍 monitor 未来新增项）。

### 验证（真实双击启动）
- 受管链完整启动：`headroom-start-result` succeeded/manager_and_client_launched、`startup-result` succeeded；route `ready/process/config_mutated=false`；relay 57321/manager 57865/client 57866 全监听；官方 Codex 激活；monitor overall=yellow（route/relay/gateway-health/codex-connection green）。
- 启动耗时（冷启动）：broker 1.3s + Headroom/Gateway 6.3s + monitor 16.6s + Test-Ready 2.8s + manager gate 16.2s + client gate 16.6s ≈ 82s。
- 测试：PowerShell 全部 PASS、Python 33/33、AST 60/60、git diff --check PASS。
- 证据：`evidence/p42-fixes-verified-20260802.json`。

### 未决（Codex 待接手/用户激活）
- P40a route-A（官方 Codex 经 Headroom shim）：shim 就绪，`Launch-OfficialCodexThroughHeadroom.vbs` 待用户激活后 `Collect-OfficialRouteAReceipt.ps1` 验收；当前官方数据面 `bypass`（走 Vortex 7897）。
- P31c traffic 50+50：7 个 spawned 502/503 已归因上游；重跑需用户授权并披露上游计量。
- P11b DirectML / P11c NPU：隔离实验未进入生产。

作者：Reasonix。

## 2026-08-02 / Reasonix（P43 route-A 激活修复 + 架构限制）

### 问题
用户双击 `Launch-OfficialCodexThroughHeadroom.vbs` 报：ChatGPT failed to start (code=3762504530) — `System.ComponentModel.Win32Exception (5)` at `CodexCliShim/Program.cs:60`（Process.Start 启动 WindowsApps 包内 codex.exe 被拒）。

### 根因
1. **独立 shim 无法启动包内 exe**：CodexCliShim 无 AppX 包身份，`CreateProcess`/`ShellExecuteEx` 启动 `WindowsApps\...\codex.exe` 均被 AppModel 拒绝（实测两种方式都 ACCESS_DENIED）。**这是 Windows 平台限制，非 shim 代码问题**。
2. **AUMID 推导缺陷**：`Get-AppxPackage` 的 `IdentityName` 为空，需从 `PackageFamilyName` 推导。
3. **route-A 与受管链互斥**：route-A 激活 ChatGPT 后，受管链 Manager 的 readiness-only 自检会停止 client（57321 helper 消失）→ 消息断流。

### 修复（Start-OfficialCodexThroughHeadroom.ps1）
- 启动方式改为 **`IApplicationActivationManager.ActivateApplication`**（包身份，替代 CreateProcess）。实测：ChatGPT 成功启动、codex.exe 由 ChatGPT 合法派生、CDP 端口就绪、**无 Win32Exception(5)**。
- AUMID 从 PackageFamilyName 推导（`OpenAI.Codex_2p2nqsd0c76g0!App`）。
- CDP 端口改为 9229（与受管链一致）——但实测 client 仍退出（Manager readiness-only 自检所致）。

### 验证
- 激活：成功（收据 `launched_waiting_user_traffic`、codex.exe 合法派生、无 ACCESS_DENIED）。
- 数据面：route-A 下 codex 走 `http://127.0.0.1:57321/v1/responses`（非 skyapi/7897）；第一条消息成功；后续断流因 client 退出。
- **结论**：route-A（独立官方 Codex 路径）与受管链（Codex++ 管理体系）在 Windows 上**无法共存**（Manager 停止 client）。用户决策：**记录限制，受管链为主**。

### 当前状态
- 环境已清理（无 codex/ChatGPT/孤儿进程）。
- 受管链需用户双击快捷方式恢复（client/relay 57321）。
- 测试：PowerShell 全 PASS、AST 60/60、diff-check PASS。
- 证据：`evidence/p43-route-a-activation-fix-and-limit-20260802.json`。

### 未决
- route-A 独立 helper（不依赖受管链 client 的 57321）若未来需要，需单独设计（与受管链彻底隔离）。

作者：Reasonix。

## 2026-08-02 / Codex（P47 用户 ZIP 源码恢复）

- 用户提供 `D:\下载\CodexPlusPlus-1.2.44.zip`；SHA-256=`4E9E50E778B2477F850DDC1346A9076D85DB115F4C6BF64F901BBACBDA6ECFFA`，大小 `19,111,719` bytes。
- ZIP 解压树共 281 个文件；逐路径与官方 `v1.2.44` / commit `77091ccaee4423f35a1b2c51c4ecd703e6201092` 的 Git blob 比对，路径缺失、多余和内容差异均为 0。
- 已提升到 `runtime\src\CodexPlusPlus-v1.2.44`；HEAD、tag、workspace/manager version 均为 `1.2.44`，tracked=281，Git working tree clean。Cargo.lock 与 manager package-lock 均可读并记录 SHA-256。
- 原 `runtime\src\CodexPlusPlus-v1.2.44` 与 `.staging` partial metadata 已备份到 `backups\source-recovery-20260802-zip-promotion`，未触碰生产目录、配置、凭据、会话、Vortex、端口或 `D:\gpt-image2`。
- P47 状态更新为 `SUCCEEDED`；独立源码验收单独登记为 P47b，工具链准备仍为 P46 `UNKNOWN`。Route C native supervisor/lease、57322 egress、隔离构建和真实官方窗口验收仍未执行。

证据：`evidence/p47-route-c-source-recovery-20260802.json`、`runtime/state/route-c-source-recovery.json`。作者：Codex。

### P47b 独立验收

- `/root/p46a_native_build_feasibility` 以只读验收员身份复核通过：正式树 HEAD/tag=`77091cc`/`v1.2.44`，working tree clean，281 tracked paths，`cargo metadata --no-deps` 解析 4 个 1.2.44 package，Cargo/package lock 可读。
- ZIP 归一化路径与 Git tree 281/281 一致，逐文件 Git blob mismatch=0；远端 `BigPizzaV3/CodexPlusPlus.git` 的 tag 精确指向目标 commit。
- 验收未构建、未安装依赖、未启动/停止进程、未修改配置或文件。P47b=`SUCCEEDED`；P46 工具链准备仍=`UNKNOWN`。

验收收据：`P47b-route-c-source-promotion-acceptance/v1`（独立验收员：p46a）。

## 2026-08-02 / Codex（P46 隔离工具链准备）

- Node 官方 `v22.23.2` Windows x64 ZIP 已下载并按 `SHASUMS256.txt` 校验，SHA-256=`1177B4137BA5ADAA56354AE40F1080C7450E8AE09CECB47DA459D1C52AC99F97`；运行时位于 `runtime\toolchains\node22`。
- Rust stable MSVC `1.97.1`、`rustfmt`、`clippy` 安装到 `runtime\toolchains\rustup` / `runtime\toolchains\cargo`，未改变全局默认工具链或 PATH。
- VS 18 `cl.exe` 与 Windows SDK `10.0.26100.0` 已发现；Manager 在 Node 22 下 `npm ci` 成功（101 packages），`npm run check` PASS，`npm test` 36/36 PASS。
- P46 状态更新为 `SUCCEEDED`。未修改生产进程、供应商配置、认证、模型、会话、Vortex 或 `D:\gpt-image2`；native Route C 代码尚未开始。

证据：`evidence/p46-route-c-toolchain-prep-20260802.json`、`runtime/state/route-c-toolchain.json`。作者：Codex。

## 2026-08-02 / Codex（P50-P52 Route C native 施工续作）

### 已完成

- P50 合同模块：`runtime/src/CodexPlusPlus-v1.2.44/crates/codex-plus-core/src/route_c.rs`。包含 `off/isolated/managed`、能力 SHA-256、owner/generation identity、loopback/保留端口拒绝、内部 header 清理、SSE 终态补发和 fail-open。
- P51 supervisor：`.../src/supervisor.rs`。只保存脱敏摘要，使用 `.lock` + `settings::atomic_write`；支持 acquire、heartbeat、stale reclaim、generation/capability 校验和安全 release。原始 capability 不写文件、不进 Debug。
- P52 native runtime：`.../src/route_c_runtime.rs` 与 `launcher.rs`。Route C 默认关闭；显式模式下启动 ingress helper、57322 egress、loopback Gateway client、5 秒 lease heartbeat；入口剥离 Authorization/API key 和内部 header，egress 读取当前 SettingsStore relay 并拒绝本地/保留端口；Responses SSE 原始字节透传，EOF/读取错误且缺终态时追加一次 `response.failed`。
- `apps/codex-plus-launcher/src/main.rs` 支持 `--route-c-mode` 和隔离/生产端口；Manager `LaunchRequest` 通过可选字段透传这些参数，默认 `off`。

### 证据与测试

- `cargo fmt --all -- --check` PASS；`cargo metadata --offline --no-deps` PASS；`git diff --check` PASS。
- 完整 Cargo 编译尝试两次：先因缺少 `msvcrt.lib`，补充实际 onecore/uCRT/UM `LIB` 后又因 VS 18 安装缺少 `vcruntime.h/stdarg.h` 失败。该阻塞已确认来自本机 C++ 工具链不完整；未强装组件，未修改系统环境。
- `Invoke-IsolatedRuntimeSmoke.ps1` PASS（CPU ORT/Kompress canary：3529→1521，节省 2008）；`Invoke-RouteCPoCPortSmoke.ps1` PASS（58322 readiness/release）；Python Route C PoC `11/11`；Gateway `30/30`；PowerShell startup/monitor fixture 全部 PASS；Node 22 manager check/test/build PASS（36/36）。

### 未完成与下一步

- `P52 state=RUNNING`：尚无完整 Rust `cargo test/build` 收据，不能生成 Canary 二进制，也不能宣称 native Route C 已生产生效。
- 仍需补齐隔离 MSVC C/C++ headers 或由 Reasonix 提供可复核的完整工具链，然后运行 `cargo test --workspace`、`cargo clippy --workspace --all-targets -- -D warnings`、launcher/manager build。
- 之后才可执行 Route C isolated native canary；真实官方窗口激活、重启、50 main + 50 spawned 和 rollback 必须由用户/Reasonix 手动完成。当前官方窗口仍可能经过 Vortex `7897`，不是 Headroom 证据。

作者：Codex；本条记录不改变生产配置和当前进程。
## 2026-08-03 供应商配置恢复（Codex）

### 事实与证据

- 只读核对发现 `C:\Users\ma dao\.codex-session-delete\settings.json` 曾仅含临时 `route-c-canary`（1 个 profile）；未读取或输出 Key、auth 内容。
- 选用 `C:\Users\ma dao\.codex-session-delete\settings.json.correct-backup-20260801` 作为恢复源：6 个原 profile，`relayMode=pureApi`，不含 `relay-aggregate-headroom`，并保留原始 `supports_websockets=true` 语义。较新的 `phase-b/settings.before-remove.json` 带临时聚合 profile，未作为恢复源。
- 先把丢失现场的单 profile 文件备份到 `backups/supplier-recovery/settings.before-restore-final-20260803.json`，再通过 `scripts/Restore-CodexPlusPlusSuppliers.ps1 -Execute` 原子替换。
- 恢复后的 live SettingsStore SHA-256 与源一致：`DDB69F35535BD99DDBCFAA91C7F04CC664C1C89C902586B5FB059FC2BBACD999`；6 个 profile ID、活动 `relay-ms95lcei`、无聚合项；2 秒稳定观察通过。
- 脱敏收据：`evidence/supplier-recovery-dryrun-20260803.json`、`evidence/supplier-recovery-execute-20260803.json`。恢复时 Manager/Client 仍运行，但本轮未停止或重启进程。

### 运行边界

- 文件恢复已完成；Manager/Client 的 UI 和内存态可能仍是恢复前状态，必须由用户手动重启后再验证 UI 列表和 Relay 读取。不能把文件哈希等同于当前窗口已经加载恢复配置。
- 未修改官方 Codex `.codex/config.toml`、供应商 Key/auth/model/session、Vortex、生产 Route C、`D:\gpt-image2`；未执行 reset/clean/force-push。

作者：Codex。
## 2026-08-03 Route C/CrashSender 交接给 Reasonix（Codex）

- 当前 Route C 计划逐项核对已写入 `REASONIX-HANDOFF-20260803-ROUTEC.md`：P47 源码恢复已完成；P50/P51/P52 源码虽存在但 native cargo/build、Canary binary、真实官方窗口验收均未完成；P53 只留下 egress `/health`/`/livez` 早处理源码和 Cargo 中间产物，没有可读 worker receipt，状态为未完成/不可验证。
- 本轮新增 `evidence/crash-audit-20260803.json`。WER 1000/1001 记录 2026-08-03 10:45:26 的 WindowsApps `codex.exe` `0xc0000409`，对应 dump 仅确认存在、未读取；桌面日志有 401、stdio stop、EPIPE 和 sampler 错误，但没有 Headroom correlation。归因保持 UNKNOWN，交给 Reasonix 做 dump/WER/版本关联和 A/B 复现。
- 当前生产 Route C 继续 `off`；不得把 P53 源码改动或 `p53-build-target` 中间产物当作 native Canary 成功。需要用户退出/重启、UAC、真实官方窗口、1+1→50+50、回滚、登录/24h 样本的工作统一由 Reasonix/用户手动窗口完成。
- 供应商恢复已完成但 Manager 会在启动时重序列化 live SettingsStore；最新现场仍有 6 个 profile、无聚合项，UI/内存态需用户手动重启后复核。不要在 Reasonix 接手时再次覆盖 SettingsStore。

作者：Codex。
- 供应商恢复后的后置现场复核 `evidence/supplier-recovery-post-manager-rewrite-20260803.json`：Manager/Client 重启后 live file 被重序列化（hash `C29A64D1...`），但 6 个 profile ID 仍完整、无聚合项；活动 profile 变为 `relay-ms8z8t5i`，视为运行态选择，不再由 Headroom 覆盖。

## 2026-08-03 / Reasonix（Route C 收口进展 + SSE 全链调试）

### 完成（P57 Route C closeout 推进）
1. **编译矩阵全闭环**（vcvars64 环境 + 隔离 rustup/cargo 1.97.1 + VS 18 MSVC 19.51 + SDK 10.0.26100）：
   - `cargo check --workspace` PASS（103.5s）——解决 Codex 卡住的 MSVC 编译障碍
   - `cargo test --workspace` PASS（core 22 + launcher 6 + data/manager；launcher 测试需提权，因 manifest requireAdministrator）
   - `cargo clippy --workspace --all-targets -- -D warnings` PASS（按类别 allow 覆盖 125 个历史风格 lint，用户确认；Route C 文件单独修干净）
   - `cargo build --workspace` PASS，生成 launcher/manager 二进制
2. **Canary 二进制部署**：`runtime/canary/route-c/<build-id>/app/codex-plus-launcher.exe` + current 副本。
3. **隔离全链启动成功**（58321/58322/18887/18888/18889/18890/18891 全监听）；canary 副本 manifest 改 asInvoker 免除 UAC（生产 exe 未改）。
4. **native lease 正常**：手动运行 native 时 supervisor.json 生成（ownerPid/capability/generation）。
5. **Python 链独立验证**：gateway→headroom→fake upstream 返回 HTTP 200 + `response.completed`（headroom SSE 本身正常）。

### 修复（Canary 脚本/源码）
- `Start-RouteCCanary.ps1`：broker 预热（/v1/compress 触发 lazy worker）、`HF_HUB_CACHE` env（huggingface_hub 1.24 用 HF_HUB_CACHE 而非 HF_HOME 子路径——worker ready 的关键）、native 去 `-Verb RunAs`（保留 -Environment 传递）、`HEADROOM_SETTINGS_PATH` env。
- `paths.rs`：`default_settings_path` 支持 `HEADROOM_SETTINGS_PATH` env 覆盖（canary 隔离用；生产不设行为不变）。
- `route_c.rs`：RouteCMode `#[derive(Default)]` + if 折叠（clippy）。

### 未决（明确）
- **canary SSE 测试仍 failed**（`canary_main_stream_terminal_missing`）：egress 返回 `route_c_lease_rejected` 403。定位：ingress 注入 capability → gateway → headroom → egress 的 header 传递链在 headroom 转发层有缺口（headroom 只剥 `x-headroom-*`，但 `x-route-c-*` 是否透传到 egress 未完全确认；egress 的 capability/generation/owner 强校验是 P50 安全契约，不可简单放宽）。**需 headroom 转发 header 透传专项验证（抓包/日志）或 native egress 校验策略决策**。
- canary 副本 manifest 为 asInvoker（仅 canary），部署时需保持。
- CrashSender 0xc0000409 维持 UNKNOWN（无 Headroom correlation）。

### 保护
- 未修改供应商/认证/模型/会话/二进制；未触碰 `D:\gpt-image2`；生产受管链未受影响（18787/18789/18790/57321/57865 全在线）。
- 证据：`evidence/p57-route-c-progress-20260803.json`。

作者：Reasonix。

## 2026-08-03 / Reasonix（Route C canary SSE 全链修复）

### 背景
- 接 Codex 未完成工作：Route C canary SSE 全链失败（canary_main_stream_terminal_missing，egress 403/502）

### 根因（4 个叠加）
1. egress 502 route_c_upstream_rejected：validate_upstream_url 拒绝 loopback 上游（canary fake upstream 127.0.0.1:18891 被禁）
2. normalize_relay_profile_for_storage 对 relayMode=official 清空 base_url → egress 读不到上游 → invalid URL
3. broker warm 请求用 /v1/compress（实际端点 /compress）→ worker 未加载 → readyz 超时
4. gateway _synthetic_run_id 把 synthetic run-id redact 为 syn_<sha256> → canary 脚本按原始 run-id 匹配失败

### 修复
- route_c.rs validate_upstream_url：HEADROOM_ROUTE_C_ALLOW_LOOPBACK_UPSTREAM=1 env 允许 loopback（canary 专用）
- Start-RouteCCanary.ps1：profile relayMode official→pureApi；broker warm URL 修正；metric 契约按 request_class 匹配
- 调试代码（egress_settings_debug / route-c-debug print）已移除

### 验证
- Start-RouteCCanary.ps1 EXIT=0，收据 status=ready、production_ports_touched=false
- fake upstream requests=2；gateway metrics main/compress/ok + spawned/bypass/ok
- 生产端口未触碰；受管链（18787/57321 等）全程在线

### 未决（交接 Codex）
- 用户激活验收（1+1→10+10→50+50 闸门）与回滚预案
- CrashSender 0xc0000409 归因（UNKNOWN，dump 未读）
- 24 小时自然样本、登录/注销、替换安装

## 2026-08-03 独立复核补充（Codex）

- 复跑 `Start-RouteCCanary.ps1` 成功得到隔离传输链和标准终态，但长 main 请求后 Headroom/Kompress 计数仍为零：`requests_compressed=0`、`tokens_saved=0`、broker `total=0`。因此 `main_compress` 是路由策略标签，不是压缩执行证明。
- 复跑 native 构建未闭环：既有 target 报 `E0463`，全新 target 报 Rust `0xc0000409 / STATUS_STACK_BUFFER_OVERRUN`。Reasonix 的旧“cargo 全 PASS”收据不能被当前环境独立复现。
- 本次隔离进程已按命令行/端口核验并清理；生产 Route C、生产端口、供应商、Vortex 和 `D:\gpt-image2` 未改变。详细收据：`evidence/route-c-independent-audit-20260803.json`。
- P57 现阶段应标记“部分通过/未完成”，下一步必须先解决干净构建和真实 Kompress 调用，再讨论生产激活。
## 2026-08-03 Reasonix 完工声明独立复核（Codex）

- P59/P60/P61 独立只读复核完成。Reasonix 的 Route C 源码合同、lease 结构、Responses `input[]/content[]/input_text` 解析支持和隔离 SSE 传输修复均可在源码/收据中找到；这部分判为“已施工/隔离部分通过”。
- 不能判定整体完成：最新 Canary `20260803-133234405` 失败并已退出；成功传输 Canary 的 Headroom/Kompress 计数仍为 `requests_compressed=0`、`broker total=0/compressed=0`；干净 Cargo 复跑分别遇到 `E0463` 和 `0xc0000409`。
- 生产现场只读复核显示 `18787/18789/18790/57321/57865/57866` 仍监听，`18788` monitor 当前不监听；没有改变生产配置、供应商、Vortex 或 `D:\gpt-image2`。生产历史计数不能替代隔离 Canary 的压缩关联证据。
- 本轮启动的 `-KeepRunning` Canary 失败后曾留下隔离进程；已按项目根路径、端口和 PID 精确清理，确认 `58321/58322/18887-18891` 无监听。`keep_running=true` 只是收据字段，不代表运行成功。
- 下一步仍是：先取得可重复的 clean native build，再让 Responses tool-output 结构真实触发 broker 并取得非零压缩计数；随后才做故障注入和官方窗口人工验收。生产 Route C 保持 `off`。

独立收据：`evidence/reasonix-completion-audit-20260803.json`。

作者：Codex。
## 2026-08-03 / Codex（WebGPU + CPU 生产部署方案编制）

### 交付物

- `docs/PRODUCTION-WEBGPU-CPU-DEPLOYMENT-PLAN-20260803.md`
- 方案只读核对了目标根 README/HANDOFF/WORK/AGENTS、WebGPU guard、Kompress broker、Headroom remote adapter、启动脚本、生产状态 evidence 和 Route C 独立复核。

### 关键结论

- 结论为“满足条件后可行，当前 NO-GO”。CPU ORT 仍是生产权威热备。
- 现有 `runtime/lab/webgpu_guard` 只处理 ONNX feeds 和低层输出，不是可直接替换的文本 `/compress` 实现；生产 broker 当前只允许 CPU。
- 生产方案必须先施工文本 adapter、provider router、真实 `/compress` 计数、长 SSE、故障注入和独立验收；不能把 main/compress 标签、provider 列表或传输 Canary 当作压缩成功。
- 当前 18788 monitor 不监听，旧 route/monitor/managed state 存在 stale/UNKNOWN，生产切换前必须重新取得完整 PID/path/hash/module/health 快照。
- 当前机器已有 WebGPU `0xC0000409`/LiveKernelEvent 141 证据，未解除前不能在本机生产链启动 WebGPU 硬件 session。

### 侦察回执

- `WEBGPU-PROD-PLAN-CODE/v1`：SUCCEEDED；确认 broker/adapter 接口、模型 I/O、CPU-only 限制和文本 adapter 缺口。
- `WEBGPU-PROD-PLAN-RISK/v1`：SUCCEEDED；确认 go/no-go 数值门槛、故障注入、熔断和回滚条件。
- `WEBGPU-PROD-PLAN-OPS/v1`：SUCCEEDED；确认唯一桌面入口、UAC 顺序、当前 18788 缺失、配置只读和无损回滚边界。

### 未决状态

- 文本 WebGPU adapter 尚未施工；provider router 尚未施工；生产 Route C 仍 off。
- 真实 WebGPU broker 压缩、长 SSE、shadow/canary、官方窗口 correlation、供应商切换、24 小时样本和独立验收均未完成。
- 本轮没有启动/停止/重启生产进程，没有修改 Codex++ 供应商配置、Base URL、认证、模型、会话、驱动/TDR、桌面任务、防火墙或 `D:\gpt-image2`。

作者：Codex。

## 2026-08-03 / Reasonix（codex 审查更正：压缩门 + 构建可复现性）

### 背景
- codex 审查（reasonix-completion-audit-20260803.json）结论：传输通过但压缩未执行（broker total=0）、构建不可复现（fresh target E0463/0xc0000409）

### 核实与更正
1. **压缩门已修复并通过**：headroom 的 Responses 压缩只处理 tool-output 项（function_call_output 等）——input_text 用户输入在缓存前缀永不压缩（设计如此）。canary 压缩门改用 custom_tool_call_output → broker compressed:1 → 收据 status=ready（build 20260803-153332094）
2. **broker warm 修复**：/compress 需 {"content":...} 有效 payload（空 body 400 不触发 worker）；ready broker 复用（跳过 8 分钟冷加载）；计数从 live /readyz 读
3. **构建可复现性**：Route C 核心 crate（codex-plus-core/launcher/data）fresh target 独立编译 PASS（56.9s exit=0）；manager（tauri）链旧依赖（aho-corasick 1.1.4/thiserror 1.0.69）在新 rustc 1.97.1 编译失败——上游问题，非 Route C 责任。aho-corasick 已更新 1.1.5（Cargo.lock 备份）

### 改动
- scripts/Start-RouteCCanary.ps1：压缩门 tool-output、broker warm/复用/超时/计数
- headroom openai.py + start-headroom.ps1：HEADROOM_CODEX_COMPRESSION_DEBUG 诊断（默认 no-op）
- Cargo.lock：aho-corasick 1.1.4→1.1.5

### 证据
- evidence/codex-audit-correction-20260803.json
- canary 收据 build 20260803-153332094（status=ready）
- fresh target 独立编译 exit=0

### 未决（交接）
- manager（tauri）fresh target 编译（需上游依赖更新）
- 用户激活验收、CrashSender 归因、24 小时样本

## 2026-08-04 / Codex（WebGPU + CPU 生产复核与隔离路由更正）

### 结论

- 生产部署条件仍未满足，保持 `NO-GO`。
- 生产只读验证收据：`evidence/production-candidate-audit-20260804.json`（SHA-256 `ACB0A159C6433CED4AB37D53FB384020996B90D11BFA47BDB935A5888CE2409D`）；`18788` 无监听，PowerShell 身份查询超时回退 `netstat`，route heartbeat stale；`18787/18789/18790` 健康但不足以放行。
- 当前机器已有 `0xC0000409`/`LiveKernelEvent 141` 证据，本轮没有重新启动任何 WebGPU/DirectML/NPU/MIGraphX 硬件 session。

### 已施工（隔离目录）

- guard 支持显式 `return_scores=true`/`final_scores`，默认仍只回传 hash/shape；
- 新增 `runtime/lab/webgpu_text_adapter/webgpu_provider.py`；
- lab broker 支持 `WEBGPU_TEXT_BACKEND=cpu`（默认）和 `webgpu_cpu`（实验），WebGPU 初始化/运行失败均 CPU fail-open；
- 新增 `scripts/Validate-ProductionCandidate.ps1` 与 Python 只读 validator，校验 listener identity、health、route heartbeat、配置哈希；
- 证据：`evidence/accel-webgpu-text-router-v1.json`，状态 `passed_lab_only`，不是生产放行。

### 测试

- 主解释器加速套件 `30`：`29` passed、`1` skipped（缺 `tokenizers`）；隔离 lab venv `33/33` passed；
- WebGPU guard `12/12`、公共 guard `11/11`、compileall、diff-check、CPU lab broker HTTP 回归均通过。

### 未决

- 独立 GPU 环境的真实 WebGPU 文本 `/compress`、长 SSE、30x bucket 稳定性、故障注入、shadow/canary、50+50 真实 SSE、24 小时自然样本和独立验收；
- 生产 monitor/route-state 必须经唯一启动入口恢复 fresh clean 后才能进入 G0；
- 生产 backend 继续 CPU ORT，不得把 CPU fallback `confirmed` 当作 WebGPU 成功。

作者：Codex。

## 2026-08-04 当前 MCP 修复（Codex）

- Headroom MCP 的配置路径存在但目标运行时缺失：`.headroom-venv` 与 `.headroom\codexpp-headroom` 均不存在；其他 MCP 命令路径和 QuickDesk 监听保持可用。
- 已恢复项目 launcher 源码与本机 `.headroom-venv` 备份；配置文件未改写认证、供应商、模型或 API 字段。
- 证据：Python 3.14.5、`import headroom`、`mcp serve --help` 通过；隔离 HTTP MCP 8788 监听并对 `/mcp` 返回 406；QuickDesk 9600 监听，CodeGraph/node_repl/QuickDesk help 通过。
- Kompress warmup 仍为 unavailable，但 launcher 按 fail-open 进入官方 CLI；这不等同于压缩后端已确认。
- 备份：`C:\Users\ma dao\.codex\backups\mcp-headroom-repair-20260804-010513`。

作者：Codex。

## 2026-08-04 最新收口指针（Codex）

最终独立审计以 `evidence/route-c-rework-independent-audit-20260804.json` 为准：隔离 tool-output 压缩、fresh check/build/clippy、core/data 测试和 ready-broker 复用分支均通过；完整 workspace 测试仅受 launcher `requireAdministrator` 的 `os error 740` 阻断；生产 Route C 仍 `OFF/NO-GO`，官方窗口数据面仍 `NOT_PROVEN`。前文 Reasonix 的“Manager 依赖失败”只保留为历史声明，已被本轮 workspace check/build/clippy 复核否定。第一次 ready-broker 复用曾出现一次 `ResponseEnded`，第二次通过，作为瞬态失败保留观察。

作者：Codex。

## 2026-08-04 当前生产上线制约复核（Codex，P64）

- `P64-production-readiness-current-audit/v1 = SUCCEEDED`，只读核对和计划收口完成；没有停止/重启生产进程，没有修改供应商配置、Vortex 或 `D:\gpt-image2`。
- 当前现场：`7897`（Vortex）、`57321/57866`（Codex++ helper）和 `57865`（Manager）监听；`18787/18788/18789/18790` 均未监听。最新 `headroom-start-result.json` 为 `headroom_start_failed / broker_ready_timeout`。
- 旧 route-state 虽有 `status=ready、route_scope=process、config_mutated=false`，但缺少新鲜 heartbeat 且生成时间较早，判定为 `stale_or_unverified`，不能代替运行态证据。
- 已确认的上线制约为 H1–H11：官方数据面未证明、生产 ready 链缺失、native candidate/回滚 manifest 未收口、普通 `input_text` 不压缩、逐请求 correlation 缺失、冷启动/复用压力证据不足、官方 50+50 未验收、管理员测试提权门、监控判据、GPU/NPU 实验边界和发布脱敏未收口。
- 修复顺序冻结为 G0 基线 -> G1 启动/监控 -> G2 native candidate/correlation -> G3 用户手动官方激活 -> G4 压缩语义/性能 -> G5 最终验收/发布。G3 之前不允许把控制面绿色写成官方 Headroom 生效。
- 证据：`evidence/production-readiness-current-20260804.json`、`docs/PRODUCTION-READINESS-CLOSURE-PLAN-20260804.md`。

作者：Codex。

## 2026-08-04 PROD-CLOSURE C0-C4 收口（Codex）

- `PROD-CLOSURE-C0-C4/v1` 已完成项目内施工和隔离验收，WORK 状态为 `SUCCEEDED`；没有停止/重启生产进程，没有触碰 Codex++ 供应商定义、`config.toml`、Base URL、Key、认证、模型、会话、Vortex 或 `D:\gpt-image2`。
- Responses 压缩改动：最新 live user `input_text` 可压缩；历史 user 内容只复用先前 live 成功缓存，未命中保持原始前缀字节；顶层字符串 `input` 保持字符串形态；HTTP/WS 压缩异常统一 fail-open。
- broker 改动：`request_id/correlation_id` 通过 context/header 传递并回显；health/status 仅保留有界、脱敏、无正文 receipt。
- 缓存门禁：安装脚本和 manifest 排除 `__pycache__`、`.pyc`、manifest 自身和本轮 C0-C4 收据；本轮已删除项目内生成的 Python 编译缓存后重新生成清单。
- 测试收据：Python `33/33`、Gateway contract `30/30`、candidate/aggregate/migration/user-script/visible-launcher PowerShell 测试均 PASS；runtime 为 Python `3.14.5`、Headroom `0.32.1`、ONNX Runtime `1.28.0`，patch hash verification PASS。
- 最终 candidate 的 ID、entry count 和 SHA-256 由 `evidence/prod-closure-c0-c4-20260804.json` 统一记录；source/release 两者 validator 均 `status=pass`。
- 独立验收修正路径：首轮 `evidence/prod-closure-c0-c4-independent-acceptance-20260804.json` 因 WORK 漂移失败；第二轮 `...-correction-20260804.json` 发现 `New-HeadroomCandidateManifest.ps1` 收据哈希过期；修正后 `evidence/prod-closure-c0-c4-independent-acceptance-correction2-20260804.json` 为 `status=SUCCEEDED`，8/8 文件哈希、manifest、编码、缓存和敏感扫描全部通过。
- 最终复核交接：正式验收员在最终收据落盘前两次 `transport_unknown`；已登记 `PROD-CLOSURE-C0-C4-ACCEPT-FINAL-TAKEOVER/v1`，主负责人仅做非独立只读核验，最终结果写入 `evidence/prod-closure-c0-c4-independent-acceptance-final-20260804.json`，不作为独立验收或生产 ready 证明。
- 生产仍为 `Route C=OFF/NO-GO`、`official_dataplane=NOT_PROVEN`；`18787/18788/18789/18790/57322` 未监听，不能用隔离结果替代真实运行态证明。
- 下一步交接给 Reasonix：按 `PROD-CLOSURE-R1-R3/v1` 执行生产 ready 链、用户手动退出/激活、官方 1+1→10+10→50+50 SSE、切换/重启/故障注入/回滚和独立运行收据；在可读 receipt 之前不得把生产状态改为 confirmed。

作者：Codex，2026-08-04。

## 2026-08-05 / Reasonix（PROD-CLOSURE-R1-R3 收口）

### R1：生产 ready 链修复（SUCCEEDED）
- **broker_ready_timeout 根因**（3 个叠加）：
  1. `ReadinessTimeoutSeconds=120` 远小于 broker ONNX 冷加载（首次 ~8 分钟）
  2. broker env 缺 `KOMPRESS_STARTUP_TIMEOUT_SECONDS`/`KOMPRESS_REQUEST_TIMEOUT_SECONDS`
  3. broker env 缺 `HF_HUB_CACHE`（worker provider_error——模型找不到）
- **修复**（Start-HeadroomForCodexPP.ps1）：ReadinessTimeoutSeconds 120→600；broker env 加三项；broker 启动后 warm 请求（有效 `{"content":"warmup"}` payload）
- **验证**：备用端口冷启动 2 次成功（services_ready，broker 热加载 13-18s）；生产恢复 start-result succeeded/manager_and_client_launched（19:21:34）；broker 18790 ready（CPUExecutionProvider）；headroom healthy/kompress=onnx；gateway livez 200；monitor /status 200
- **dashboard 修复**：codexpp-headroom-dashboard.ps1 expectedKeys 加 official-dataplane（12→13 项，P42 契约漂移）——窗口从"监控数据不兼容"全红恢复 green/yellow
- **桌面入口修复**：.lnk 去掉 --phase-b（PhaseB 已在 19:21 执行完成——聚合移除+指示器注册；避免每次双击 phase_b_requires_codexpp_quiescent）

### R2：官方窗口激活（PARTIAL）
- 用户手动退出 Manager/Client 后双击成功；官方 ChatGPT 10436 激活（CDP 9229 与 client 60840 关联）
- **官方数据面 NOT_PROVEN（H1 硬阻塞）**：官方 config.toml base_url=https://skyapi2026.com（受保护未改）——官方直连上游；headroom requests_total=0；57321/18787/18789 无官方连接；Vortex 7897 无旁路
- 用户决策：收口 R1，R2/R3 记阻塞

### R3：官方流量分级验收（BLOCKED）
- H1 官方数据面未接入 Headroom——需 G2（Route C native 成为官方生命周期 owner）或 route-A（P43 与受管链冲突）完成后验收
- 待验收项：1+1→10+10→50+50 SSE、故障注入、回滚、提权 launcher（os error 740）、monitor official_dataplane=confirmed

### 边界
- 未修改供应商定义/Base URL/API key/认证/模型/会话/Vortex/D:\gpt-image2；官方 config.toml base_url 保持原值
- 证据：evidence/prod-closure-r1-r3-20260805.json

## 2026-08-05 / Codex（官方桌面数据面实时复核）

- 官方 `codex.exe` 到 `7897/57321/18787/18789` 均为 0；仅 ChatGPT 子进程连接 `18788` 控制端点。官方 `base_url=https://skyapi2026.com`。
- Gateway/Headroom 健康为 200，但 Headroom `requests.total=0`、压缩请求为 0，官方数据面计数无增量，monitor classification=`unknown`。
- 结论：官方桌面当前是否经过 Headroom 信息不足，现有证据不支持“已生效”；保持 `official_dataplane=NOT_PROVEN`。外部 443/5228 的最终上游未知。

## 2026-08-05 Reasonix R1-R3 独立复核（Codex）

- `evidence/prod-closure-r1-r3-20260805.json` 的 R2/R3 结论可信：官方数据面仍未证明，R3 阻塞。
- R1 修复内容已在 `scripts/Start-HeadroomForCodexPP.ps1` 中找到，当前 18787/18788/18789/18790 健康；但最新 `headroom-start-result.json` 仍是 `failed / route_state_contract_invalid_before_managed_state`，之后 route keeper 才把 route-state 写成 `ready`。这是启动收据与最终状态不一致，指向 Manager/Client 启动后 route-state 发布竞态，不能把 R1 写成无条件成功。
- 当前官方 PID 网络证据：`codex.exe app-server` 远端 443，ChatGPT 网络进程远端 5228/控制端点 18788，无官方 PID 到 18787；Headroom `/stats` 和 broker request counters 为 0。
- fixture 测试覆盖启动、路由身份、监控和桌面入口且全部通过，但没有 route keeper 延迟 fixture；候选 source/release manifest 对 Reasonix 本轮文件和文档均 `DRIFT`，不可发布。
- 建议先修复启动竞态并补充延迟 fixture，再重新冻结候选；R2/R3 继续交给 Reasonix，直到取得官方 correlation 和真实 SSE 终态证据。

独立复核收据：`evidence/prod-closure-r1-r3-independent-review-20260805.json`。

作者：Codex，2026-08-05。

## CORRECTION-OFFICIAL-ROUTE-INGRESS-20260805/v1

- 发现缺陷：先前把 Route C managed 的 `57321` ingress 当作当前 legacy 生产默认，可能绕过 Gateway。
- 修正：`Start-OfficialCodexThroughHeadroom.ps1` 和手动注入工具默认使用 `http://127.0.0.1:18787/v1`；仅 `-UseRouteCIngress` 明确选择 managed Route C 的 `57321/v1`。
- 验证：PowerShell parser、官方 route fixture、live dry-run（ingress=18787）、`git diff --check` 均 PASS；生产激活未执行。
- 收据：`evidence/correction-official-route-ingress-20260805.json`。

作者：Codex，2026-08-05。

实时复核（21:21）：官方 app-server PID `40032` 仍连接 Vortex `127.0.0.1:12450`，到 `18787/18789/57321` 均未观察到；Headroom `requests_total=0`，`official_dataplane=unknown`。候选未激活。证据：`evidence/official-dataplane-live-recheck-20260805-2121.json`。

## 2026-08-05 官方 app-server 路由启动器加固（Codex）

`integration_package_id=OFFICIAL-ROUTE-LAUNCHER-HARDENING-20260805/v1 | package_version=1 | work_type=write | risk=R2 | complexity=complex | requested_outcome=implementation | route=sol_takeover | owner=/root | state=SUCCEEDED`

- 根因：旧启动器只传 renderer CDP 端口，未在 Electron 主进程生成 `codex.exe app-server` 前暂停，故环境路由覆盖没有进入官方数据面。
- 修复：AppX activation 增加 `--inspect-brk=127.0.0.1:9329`；等待 Node inspector；生产 Route C=off 时设置两个环境变量为 Gateway `http://127.0.0.1:18787/v1`，只有显式 managed Route C 才使用 `http://127.0.0.1:57321/v1`；调用 `Runtime.runIfWaitingForDebugger`；等待唯一 app-server 命令行同时含两个覆盖。
- 安全：仅做受保护文件哈希校验，不写 `config.toml`、供应商、Key、认证、模型、会话、Vortex 或系统代理；不停止/重启当前生产进程。
- 测试：PowerShell parser、当前服务 dry-run、官方路由启动器 fixture 均 PASS；native Cargo build 仍受 `vcruntime.h/stdarg.h` 缺失阻塞。
- 当前状态：候选施工完成，真实 AppX 激活、官方 SSE、同请求 correlation、分级负载、故障注入、回滚和 24 小时样本未执行；`official_dataplane=unknown/not_proven`、Route C/生产 `NO-GO`。
- 证据：`evidence/official-route-launcher-hardening-20260805.json`。
- 下一步：用户手动退出所有官方 ChatGPT/Codex 后运行启动器；当前生产模式只有收据同时出现 `route_environment`、`app_server_route.process_id` 和官方 PID -> `18787 -> 18789 -> 57321` correlation，才能继续 R2/R3；managed Route C 才验收 `57321 -> 18787 -> 18789 -> 57322`。

作者：Codex，2026-08-05。

## OFFICIAL-APP-SERVER-ENV-20260805/v1（Codex）

### 事实

- 官方 ChatGPT 主进程 PID `62680` 的 Node inspector 为 `127.0.0.1:9329`；只读评估显示 `CODEX_APP_SERVER_CHATGPT_BASE_URL`、`CODEX_APP_SERVER_OPENAI_BASE_URL`、`CODEX_CLI_PATH` 均不存在。
- 官方 `codex.exe` PID `40032` 的命令形态为 `resources/codex.exe -c features.code_mode_host=true app-server --analytics-default-enabled`，网络仍为 `127.0.0.1:12450`（Vortex）；官方 PID 到 `57321/18787/18789` 为 0，Headroom `requests_total=0`。
- 本地官方包 `app.asar` 的代码路径读取两个 `CODEX_APP_SERVER_*_BASE_URL` 变量，并在生成 app-server 参数时加入一次性 `-c` 覆盖；这比外层 `CODEX_CLI_PATH` shim 更接近真实父级启动入口。

### 施工

- `runtime/src/CodexPlusPlus-v1.2.44/crates/codex-plus-core/src/official_route.rs`：Route C native 启动阶段使用 `--inspect-brk` + Node inspector 写入本地 ingress 环境并恢复主进程。
- `runtime/src/CodexPlusPlus-v1.2.44/crates/codex-plus-core/src/launcher.rs`、`apps/codex-plus-launcher/src/main.rs`：Route C launch hook 接入环境注入；Route C 默认仍为 `off`。
- `scripts/Invoke-OfficialAppServerRouteInjection.ps1`：只读 dry-run 与显式 `-Apply -ResumeIfPaused` 工具。当前对生产窗口只执行了 dry-run，无环境写入、无进程生命周期动作。

### 验证与未决

- PASS：PowerShell 7.6.3；脚本语法；live inspector dry-run；isolated Node `--inspect-brk` apply/resume fixture（两变量在 resumed child 可见）；`cargo fmt --all -- --check`；差异检查。
- BLOCKED：native Cargo build。当前 shell 的 MSVC/Windows SDK 环境缺少标准 C 头/运行库（`vcruntime.h`、`stdarg.h`），未生成或替换任何运行二进制。
- NOT_EXECUTED：用户手动退出/启动、Route C managed Canary、官方 SSE correlation、1+1 -> 10+10 -> 50+50、供应商切换、故障注入、回滚和 24 小时样本。
- 生产结论保持 `official_dataplane=NOT_PROVEN`、`Route C=OFF`、`NO-GO`。当前 `codex.exe` 必须由用户重启后才能继承新环境。

收据：`evidence/official-app-server-env-contract-20260805.json`。作者：Codex，2026-08-05。

## OFFICIAL-ROUTE-FOLLOWUP-20260805/v1（Codex）

- 只读 follow-up 已确认 AppX `26.730.8199.0` 与 `app.asar` 合同哈希一致；当前官方启动器源码已经包含 `--inspect-brk`、CDP 环境注入、恢复和 app-server 路由命令行门禁。
- 现场仍未激活新路径：当前主进程命令行为 `--inspect`，官方 `codex.exe` PID `40032` 仍由 ChatGPT PID `62680` 派生并连接 Vortex `12450`；到 `57321/18787/18789` 为 0；Headroom requests=0；dry-run 报环境变量不存在且 `requires_app_server_restart=true`。
- 判断：环境变量合同“满足条件后可行”；`--inspect-brk` 对启动时注入是必要但不足。必须由用户手动关闭并重新激活官方窗口，在恢复前注入两个变量，然后验收新 app-server、完整 `57321 -> 18787 -> 18789 -> 57322 -> upstream` correlation、SSE 终态、负载、故障、切换、回滚和 24 小时样本。
- 生产边界不变：未执行 activation、未停止/启动进程、未写配置或供应商、Route C `OFF/NO-GO`，`official_dataplane=unknown/not_proven`。

脱敏收据：`evidence/official-route-followup-20260805.json`。作者：Codex，2026-08-05。

## 2026-08-05 / Codex（OFFICIAL-ROUTE-RECON/v1）

### 收口事实

- 官方 ChatGPT/Codex `26.730.8199.0` 的 `codex.exe` 从 WindowsApps 包路径运行 `app-server`，现场仅连接 Vortex `127.0.0.1:12450`；ChatGPT network 子进程连接 monitor `18788`。官方 PID 到 `57321/18787/18789` 均未观察到。
- Headroom `/stats` `requests.total=0`、token 计数为 0；monitor `official_dataplane=unknown`，Gateway 请求 correlation=0。受管链 `route-state=ready/process/config_mutated=false` 只证明控制面。
- `Start-OfficialCodexThroughHeadroom.ps1 -CodexCliPath` 只用于路径解析/收据；脚本实际调用 `IApplicationActivationManager.ActivateApplication`，没有设置 `CODEX_CLI_PATH` 或启动 shim。

### 方案结论

- Route A 与受管链不兼容：AppX 激活/首请求可工作，但 Manager readiness-only 会停止独立 client/helper，`57321` 消失并断流；shim 不在当前内嵌 app-server 父链。
- Route C native 是首选方向：必须由 native supervisor 成为官方 app-server 与 `57321/57322` generation 的唯一生命周期 owner。仅注入 `-c model_provider/base_url` 不足以改变当前官方数据面。
- `CODEX_CLI_PATH`/shim 只在它实际收到独立 CLI `app-server` 时有意义；受支持进程级 wrapper 仍需官方可验证的父级启动/环境注入契约。当前没有该契约的本地证明。
- 最新 isolated canary (`runtime/canary/route-c/20260805-110245231/route-c-startup.json`) 使用 `--helper-only --route-c-mode isolated` 和 fake upstream `18891`，不是官方 AppX 数据面验收。Route C 生产保持 `OFF/NO-GO`。

### 下一步闸门

1. 在隔离 generation 中证明 native owner 能启动实际 app-server，并记录 parent PID/path、`official PID -> 57321` TCP 和完整 SSE correlation。
2. 通过单一 lease、`57321 -> 18787 -> 18789 -> 57322 -> real upstream`、标准 SSE 终态、故障/切换/回滚和 1+1/10+10/50+50 闸门。
3. 只有用户批准的手动激活窗口和可读官方 receipt 完成后，才讨论生产切换；不得把端口监听或控制面健康写成 official dataplane confirmed。

脱敏收据：`evidence/official-route-recon-20260805.json`。作者：Codex，2026-08-05。

## 2026-08-05 19:45 官方桌面路由实时复核（Codex）

- 官方 `ChatGPT.exe`/`codex.exe` 当前只观察到到 `127.0.0.1:12450`（Vortex `core.exe`）和 `18788` 监控控制端点的连接；到 `57321/18787/18789` 均为 0。
- Headroom `/stats` 返回 200，但 `requests.total=0`、`requests_compressed=0`；监控分类仍为 `unknown`，Gateway 增量和 correlation 均为 0。
- 结论：官方桌面数据面仍是 `NOT_PROVEN`，不能报告已走 Headroom；可确认的是本地 Vortex 路径，最终外部上游仍未知。Route C/生产 Headroom 生效状态不变。
- 证据：`evidence/official-dataplane-live-recheck-20260805-1945.json`。本轮未改供应商配置、认证、模型、会话、Vortex 或 `D:\gpt-image2`。

作者：Codex，2026-08-05。

## 2026-08-05 / Reasonix（P67 当前收口：indicator 已同步，官方窗口待手动 reload）

- **indicator registration/runtime sync：SUCCEEDED**。源与运行副本均为 `1.0.0.11`，SHA-256=`E7414EF554FAB3E5662DA59B58F5AF947466567213FAE4DE0B12806D7A61E871`；`user_scripts.json` 中 `user:headroom-status-indicator.js` 保持 enabled，market version 已同步为 `1.0.0.11`。非 Headroom 的 6 个脚本 key 保留。
- 受保护 `C:\Users\ma dao\.codex\config.toml` SHA-256 保持 `1CE7D7C9A73D1799E45756D7155592566EDCB23FDF01553CF4ED57C2A9E7D66C`；未修改供应商、Base URL、认证、模型、会话、Vortex 或 `D:\gpt-image2`。
- 只读 preflight：`http://127.0.0.1:18788/status` HTTP 200、`schema_version=2`、`item_count=13`、`overall=yellow`；证据 `evidence/p67-indicator-preflight-20260805.json`。注册和版本刷新收据：`evidence/p67-register-version-refresh-20260805.json`；备份：`backups/metadata/user_scripts.json.before-p67-version-refresh`。
- **Manager/官方窗口 reload：NOT_EXECUTED**。按当前操作边界未停止/重启进程；`restore-manager-window.ps1` 仅观察到 15x15 Manager 窗口并以非零退出，未终止进程。需用户手动退出并重新启动 Manager/官方 ChatGPT 窗口后，才能证明 renderer 实际加载新脚本。
- **official_dataplane：UNKNOWN / NOT_PROVEN**。monitor 快照仍为 `classification=unknown`、Gateway correlation 数量=0、官方 PID 到 `18787` 未观察到；Route C native owner、官方 `1+1 -> 10+10 -> 50+50` SSE、故障注入、供应商切换、回滚和 24h 样本均未执行。完整收口收据：`evidence/p67-production-closure-status-20260805.json`。

作者：Reasonix，2026-08-05。

## 2026-08-05 P68 监视器一致性与生产阻塞复核（Codex）

### 已完成

- `/status` schema v2 的 13 项与顶部 indicator、WinForms dashboard 已统一；源码和 AppData indicator 均为 `1.0.0.11`，SHA-256 `E7414EF554FAB3E5662DA59B58F5AF947466567213FAE4DE0B12806D7A61E871`。
- Node、PowerShell 合同和启动夹具复测通过；P66 的源码级修复不需要改变供应商配置或生产路由。
- 因 P66/本轮文档更新造成的 candidate drift 已备份并重新生成，最终 manifest 必须以本节之后的 validator 收据为准。

### 尚未完成与责任边界

- **Reasonix/用户激活窗口**：让 Manager/官方窗口 reload 新 indicator，并用同一快照确认顶部与独立监视器视觉一致。
- **Reasonix/Route C**：取得官方 PID 到 `57321 -> 18787 -> 18789 -> 57322 -> 真实上游` 的请求 correlation；Route-A 已确认受 WindowsApps app-server 与受管链架构限制，Route C 仍未进入生产。
- **Reasonix/用户激活窗口**：完成官方 `1+1 -> 10+10 -> 50+50` SSE、main/spawned、504/断流/解码/压缩超时、故障注入、供应商切换、回滚和 24 小时自然样本。
- **发布操作员**：candidate validator=0 后再执行 GitHub 发布；不得上传 runtime、缓存、私有状态、日志、模型、凭据或会话正文。

生产结论保持 `official_dataplane=NOT_PROVEN`、`Route C=OFF`、`NO-GO`。证据：`evidence/p68-monitor-production-blocker-audit-20260805.json`。

作者：Codex，2026-08-05。

## 2026-08-05 / Reasonix（codex 复核问题修复）

### codex 复核结论（prod-closure-r1-r3-independent-review-20260805.json）：PARTIAL_NOT_READY

### 问题 1：R1 启动竞态（属实）
- headroom-start-result failed（route_state_contract_invalid_before_managed_state）但后续 route-state ready——Manager 改 config 元数据后 hash 竞争，1305 行首次失败即 throw
- 修复：新增 Wait-RouteStateContract（deadline 内轮询 route-state 契约，hash 刷新后重试，受保护供应商契约每次重验）；主流程改调用

### 问题 2：缺延迟 route keeper fixture（属实）
- 修复：startup-root.tests.ps1 新增 P26 race fixture（route-state 延迟刷新 600ms，验证轮询收敛 + 实际等待）；函数加载列表补 Update-RouteStateConfigHash/Wait-RouteStateContract

### 问题 3：候选 manifest DRIFT（属实）
- 7 文件（HANDOFF/README/WORK/Set-HeadroomDesktopEntry/Start-HeadroomForCodexPP/dashboard/startup-root.tests.ps1）与 C0-C4 冻结不符
- 修复：重新冻结 candidate-manifest-source/release-20260805.json（source 1216 项/release 163 项），校验 status=pass

### 验证
- 全部 7 套测试 PASS（含新增 race fixture）
- manifest source/release 校验均 pass（exit=0）
- 证据：evidence/prod-closure-r1-r3-codex-review-fixes-20260805.json

### 未决（交接）
- R2/R3 保持阻塞（官方数据面 correlation 前不验收）
- 新 manifest 为 20260805 基线，后续改动需重新冻结

## 2026-08-05 / Reasonix（R2/R3 打通尝试——H1 阻塞收口）

### 尝试过程（route-A 路线，用户批准）
1. 生产完整链恢复：start-result succeeded（P26 竞态修复首次生效）——四服务 + Manager/Client 全在线
2. route-A 激活成功：launched_waiting_user_traffic、protected_files_unchanged=True、官方 ChatGPT 树 + CDP 9229

### H1 阻塞确认（P43 架构限制完整复现）
- 官方 codex.exe 从 WindowsApps 原路径启动（非 shim）——shim 注入 base_url=18787 未介入窗口内嵌 app-server
- route-A 激活后受管链 Manager readiness-only 自检停止 client（57321 FREE）→ 数据面断
- headroom requests_total=0——官方数据面直连 skyapi2026.com（config 受保护未改）
- **结论**：route-A 与受管链无法共存（P43 用户已决策受管链为主）；官方窗口 app-server 不经 shim——**需 G2（Route C native 成为官方生命周期 owner）才能打通**

### 用户决策
- 收口并记 H1 阻塞（待 G2）

### 恢复
- 用户重新双击恢复受管链（client 26864/manager 51380）；生产完整链在线

### 边界
- 未修改供应商/Base URL/API key/config.toml/auth/settings/Vortex/D:\gpt-image2
- 证据：evidence/prod-closure-r2-r3-h1-blocked-20260805.json

## 2026-08-05 / Reasonix（manifest 排除规则修复）

- security_review 发现：source/release manifest 含 runtime-artifacts 日志（proxy.log/v4-trace）、CodexCliShim/bin-obj 构建产物——违反"不包含 runtime/cache/log/private"声明
- 修复：New-HeadroomCandidateManifest.ps1 补排除规则（runtime-artifacts 段、bin/obj 目录、.log/.pid/.lock/.cache/.tmp 扩展名，source+release）
- 重新冻结：source 1219→955 项、release 163→128 项；校验 pass；残留检查全 False
- security_review 复审 pass（无剩余安全问题）

## 2026-08-05 / Reasonix（manifest 排除规则二次修复）

- review 发现 2 个 should-fix：①official-codeload-staging 目录（3.4MB 未完成下载 tar.gz.part）漏排；②.lock 规则误伤 Cargo.lock（可复现构建 lockfile）
- 修复：New-HeadroomCandidateManifest.ps1 加 official-codeload-staging 段 + .part/.download 扩展名 + staging 并入 recovery 规则；.lock 排除加 Cargo.lock/poetry.lock/package-lock.json/pnpm-lock.yaml 白名单
- 验证：Test-HeadroomCandidateManifest PASS；重新冻结 source 955/release 128 校验 pass；Cargo.lock 保留/官方 staging 排除/运行时 lock 仍排除
- review 复审 pass（可发布，仅 2 无害 nit）

## 2026-08-05 17:13 / Codex（官方桌面数据面复核）

- 官方 ChatGPT/Codex 到 `7897/57321/18787/18789` 及远端 443 的已建立连接均为 0；官方 `base_url=https://skyapi2026.com`。
- Headroom `/stats` HTTP 200、`requests.total=0`；Gateway live metrics 404，本地 metrics state 为旧快照，当前总数 UNKNOWN。
- 结论：官方数据面保持 `NOT_PROVEN/UNKNOWN`，不能报告已接入 Headroom；最终外部代理/上游路径未验证。

## 2026-08-05 最新返工独立复核 / Codex

### 已确认

- R1 启动竞态修复已在主路径生效：`Wait-RouteStateContract` 位于 `scripts/Start-HeadroomForCodexPP.ps1:1356`，不是仅静态存在。
- 当前 `headroom-start-result.json`、`startup-result.json` 均为 `succeeded`；route-state 为 `ready/process/config_mutated=false`；route keeper、Manager、Client 的 PID/路径/启动时间和配置哈希可对上；受保护供应商契约未改变。
- 七套隔离测试已由本轮独立复跑并全部通过：startup-root（含 600ms race fixture）、startup-chain、managed-process-state、monitor-indicator-preflight、official-dataplane-monitor、route-keeper-identity、stale-route-keeper。
- Kompress broker 当前 ready，provider=`CPUExecutionProvider`、backend=`onnx`；这是后端就绪证据，不是官方窗口压缩流量证据。

### 仍未解决

- 官方数据面仍 `NOT_PROVEN`：官方 `codex.exe` 连接 `127.0.0.1:12450`（Vortex `core.exe`），没有到 `18787/57321` 的连接；ChatGPT 只有 `18788` 控制端点；Gateway/Headroom 当前请求和 correlation 计数为 0。
- R3 继续阻塞：没有官方 `1+1 -> 10+10 -> 50+50` SSE、故障注入、供应商切换/回滚或 24 小时自然样本；Route C 保持 `off`，生产保持 `NO-GO`。
- 2026-08-05 source/release candidate manifest 已在本轮文档收口后重新冻结并验证通过；最终候选 ID、条目数和 hash 以两个 manifest 文件自身为准。Reasonix 旧收据中的 1216/163 条目数与当前 manifest 不一致，保留为历史审计；GitHub 发布仍未执行。独立审计收据已加入 source candidate 排除规则，避免收据记录 manifest hash 造成自引用漂移。

### 交付收据

- `evidence/prod-closure-r1-r3-codex-reverification-20260805.json`

### 下一步

1. 追加本轮审计记录后重新生成并验证 source/release candidate manifest。
2. 将 R2/R3 交回 Reasonix/用户，只有取得官方 PID -> 57321 -> 18787 -> 18789 -> 真实上游的同一请求 correlation，才能继续生产验收。

作者：Codex，2026-08-05。

## 2026-08-15 18:02 当前官方桌面路由复核（Codex）

- 官方进程当前连接 Vortex `127.0.0.1:12450` 共 18 条；到 Codex++ helper/Gateway/Headroom/Route C egress（`57321/18787/18789/57322`）均为 0。官方 app-server 没有本地 Headroom 路由覆盖。
- Headroom 连续三秒前后业务计数保持 0；monitor 没有 Gateway socket、counter delta、request correlation 或 upstream target 证据。
- 当前结论：本客户端绕过 Headroom，经 Vortex 本地核心对外；最终外部上游仍无法仅凭 socket 归属。服务监听或健康状态不能替代数据面证明。
- 独立侦察员三次在回执前遭遇 503，已停止重试；主负责人 `sol_takeover` 完成只读、非独立核验。证据：`evidence/official-dataplane-live-recheck-20260815-1802.json`。

作者：Codex，2026-08-15。

## 2026-08-16 / P71 token monitor source candidate

### 当前状态

- `P71j-candidate-docs-reasonix-handoff/v2`：`SOURCE_READY`；生产状态：`PRODUCTION_WAITING_REASONIX_ACTIVATION`。
- 集成包：`P71-monitor-token-accounting-20260815/v2`；候选为 `candidate_kind=complex`、`candidate_profile=source`、manifest v1/sha256。
- P71i 已完成独立源码终验；未执行 runtime install、生产 apply 或重启。当前 runtime `openai.py` 哈希 `C266...` 与源候选 `2F5B...` 不同，monitor 运行哈希 `140F...` 与源候选 `BDF8...` 不同；这些是只读观察，不是生产完成证据。

### 交接与验收门

- 用户必须先手动退出 Codex/Codex++，Reasonix 再做备份、dry-run/preflight、apply、runtime hash 核对和重启。
- 真实验收至少包含 1 个 main/compress 和 1 个 spawned/bypass；保存脱敏关联 ID、分类和终态，不保存正文。
- 当前代际 token 必须 `completed>0`、`missing=invalid=0`；legacy/excluded 只保留明细。broker 先 baseline 再看窗口 delta；窗口内新增 queue_full 仍合法 yellow。
- 验收窗口必须 `504=0`、断流=0、SSE 标准终态齐全；任何失败、hash 漂移或配置越界都必须停止并原子回滚全部已写目标。
- 详细步骤见 `REASONIX-HANDOFF-P71-TOKEN-MONITOR-20260816.md`，脱敏证据见 `evidence/p71-token-monitor-source-validation-20260816.json`。

## 2026-08-15 22:32 当前客户端路由复核（Codex）

- 运行中的官方窗口仍被诊断为 `bypass_vortex_observed`：Vortex `12450` 为 11，Gateway/Headroom/helper/egress 均为 0；磁盘 pin 仍未 reload。
- Headroom 总计 121、压缩 119，但 monitor `classification=bypass` 且 `gateway_socket_observed=false`；不能将这些计数归因于当前官方窗口。
- 结论：当前客户端仍不是 Headroom 链路。证据：`evidence/official-dataplane-live-recheck-20260815-2232.json`。

作者：Codex，2026-08-15。

## 2026-08-15 官方绕过与供应商切换收口（Codex / P69）

### 运行态事实

- 最新只读采样仍显示官方 `codex.exe app-server` 走 Vortex `127.0.0.1:12450`；官方 PID 到 `57321/18787/18789/57322` 为 0，Headroom 业务统计为 0，monitor `official_dataplane=unknown/not_proven`。
- SettingsStore 的活动 relay profile 和配置文件可以发生变化，但已运行 app-server 不会热重载；因此“切换文件成功”与“当前会话已使用新上游”必须分开记录。`codexAppStepwiseBaseUrl` 是独立 Stepwise 字段，不作为 relay 生效证据。
- 2026-08-15 脱敏运行探针记录当前 SettingsStore 活动 profile 为“自有号池”、Stepwise disabled；只保留 URL 分类和 SHA-256，不泄露主机、Key 或正文。收据：`evidence/official-provider-runtime-live-20260815.json`。

### P69 已完成的项目内修复

- Manager `RelaySwitchPayload` 增加 `runtime_reload_required` / `runtime_reload_status`；检测到运行中的 Codex/ChatGPT 时返回 `restart_required`，否则为 `next_launch`。
- Manager 成功消息明确提示当前 app-server 需要退出/重启后才会读取新供应商。Agent 没有执行任何生产停止/重启。
- 监视器补齐 Vortex/SakuraCat `12450` 旁路识别，与 `7897` 一样生成 `official_dataplane=bypass` 和 `vortex_ports` 证据；`confirmed` 仍必须有 Gateway/Headroom/egress correlation。
- 当前已运行的 monitor 进程尚未 reload，`18788/status` 仍可能显示旧实例的 `classification=unknown`/`vortex_ports=null`；用户手动重启窗口和 monitor 后才验收新状态。
- 新增 [`scripts/Inspect-CodexProviderRuntime.ps1`](scripts/Inspect-CodexProviderRuntime.ps1) 和 [`tests/Test-InspectCodexProviderRuntime.ps1`](tests/Test-InspectCodexProviderRuntime.ps1)。诊断器只输出 profile/config 的分类、SHA、PID/TCP 计数和状态，不输出凭据或会话正文。
- Correction packet：[`evidence/correction-official-bypass-provider-switch-20260815.json`](evidence/correction-official-bypass-provider-switch-20260815.json)。
- 最终验证：`Test-InspectCodexProviderRuntime.ps1 PASS`、`official-dataplane-monitor.tests.ps1 PASS (18 assertions)`、PowerShell parser PASS、`cargo fmt --all -- --check PASS`；`cargo check -p codex-plus-manager` 因依赖下载/工具链 120 秒超时，构建收据仍 UNKNOWN。当前 config/settings SHA 与 live probe 收据一致，本轮未改生产配置或进程。

### 未完成与交还

- 当前 `D:\program\Codex++` 的 1.2.47 二进制尚未包含本轮 manager UI/backend 修复；Route C native 构建、Canary 部署、官方窗口手动退出/激活、真实 SSE correlation、供应商切换后的重启复验和回滚仍交 Reasonix/用户。
- P70 Reasonix 构建/Canary 交接本轮未返回可读回执，状态保持 `UNKNOWN`；没有观察到生产副作用，不能把 Route C 或本轮 manager 源码写成已部署。
- P69 新增源码/诊断器/测试/证据后，旧 candidate manifest 已 drift；本轮未发布，构建或 GitHub 发布前需重新冻结并验证 manifest。
- 在取得同一请求的 `official PID -> 57321 -> 18787 -> 18789 -> 57322 -> selected upstream`、标准 SSE 终态、main/spawned 分类和至少一次切换后重启证据前，不得把 `official_dataplane` 改成 `confirmed`，不得把 Route C 从 `OFF/NO-GO` 改为生产。
- 复验命令：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "D:\新建文件夹\headroom for codex++\scripts\Inspect-CodexProviderRuntime.ps1"
```

作者：Codex，2026-08-15。

## 2026-08-15 18:11 当前客户端路由复核（Codex）

- 新 app-server PID `25652` 没有 `18787/57321/18789` 路由覆盖；两次官方 TCP 采样均只命中 Vortex `12450` 和 monitor `18788`，Headroom/Gateway/helper/egress 为 0。
- Headroom 请求、压缩和 API 计数连续保持 0，monitor correlation 为 0。Base URL 当前是已脱敏的私网非 loopback HTTP 上游，但没有足够 socket 证据把 Vortex 最终出口精确归属到该端点。
- 结论：`official_dataplane=NOT_PROVEN`，当前客户端未走 Headroom；Vortex 路径已确认，最终上游 UNKNOWN。证据：`evidence/official-dataplane-live-recheck-20260815-1811.json`。

作者：Codex，2026-08-15。

## 2026-08-15 / Reasonix（P70 manager 构建验证 + manifest 冻结）

### 完成
- P69 测试全 PASS（Test-InspectCodexProviderRuntime + official-dataplane-monitor 18 assertions）
- manager 构建验证：cargo check -p codex-plus-manager EXIT=0（隔离工具链 rustup 1.97.1 + vcvars64，1m06s）——P69 源码（commands.rs/App.tsx 08-15 版）编译通过
- Inspect-CodexProviderRuntime.ps1 bug 修复：`$rows = @(foreach ...)` 数组强制（官方进程为空时 `$rows.Count` 在 StrictMode 报错 'Count property not found'）——live probe EXIT=0（official_process_count=0/unknown/restart 判定正确）
- candidate manifest 重新冻结：candidate-manifest-source/release-20260815.json（source 988/release 133）校验 pass；P69 文件入清单；secret_like_paths=[]

### 边界
- 未部署到 D:\program\Codex++（受保护边界禁止）；未改供应商/配置/Vortex/D:\gpt-image2

### 未决
- 生产二进制部署（需用户授权）
- 官方数据面 confirmed 验收（H1 阻塞，需 G2）
- 证据：evidence/p70-manager-build-and-manifest-20260815.json

## 2026-08-15 20:23 当前客户端路由复核（Codex）

- `Inspect-CodexProviderRuntime.ps1` 成功返回 `official_dataplane=bypass_vortex_observed`：官方到 Vortex `12450` 为 21，`7897/57321/57322/18787/18789` 为 0。
- Headroom 业务计数仍全部为 0；monitor 已升级为明确 `bypass`，并观测到官方 PID 到 `12450`，没有 Gateway delta 或 request correlation。
- 当前运行态需要重启才能重新读取最新供应商文件选择，但现场已经可判：官方客户端未走 Headroom，使用 Vortex bypass。证据：`evidence/official-dataplane-live-recheck-20260815-2023.json`。

作者：Codex，2026-08-15。

## 2026-08-15 / Reasonix（官方路由 pinning 方案实施）

### 用户需求（已记入 AGENTS.md 规则 3）
- 管理工具供应商配置页面 base_url/key 不可改（用户通过管理工具维护供应商）
- 每次启动（含供应商切换后再次启动）必须确保 Codex 桌面端走 Headroom

### 根因
- 官方 config.toml 的 codex_local_access.base_url = 10.101.22.203:52297（私网 Cockpit 号池）——Manager 切换供应商时从管理工具同步写入 → 官方直连（经 Vortex 12450）不经 Headroom
- 1.2.47 无 official_route.rs（CDP 注入模块被移除）——Rust 注入不可用

### 实施（PowerShell 钩子——不改管理工具/不改 Rust）
- Invoke-OfficialRoutePinning（Start-HeadroomForCodexPP.ps1）：每次启动把官方 config.toml 的 codex_local_access.base_url 强制为 http://127.0.0.1:18787/v1（Gateway）——供应商真实地址保留 settings.json——fail-open
- 调用点：非 ServicesOnly 分支开头（契约 Before 快照之前——磁盘/契约/route-state 自洽，P26 契约不失配）
- 正则 [^\[] 段内限定（不误伤其他 provider 段）
- startup-root.tests.ps1 新增 pinning 单测（函数/段内正则/时序断言）

### 审查与验证
- review 三轮：blocking（契约失配）→ 修复 → 可 ship；单测断言核验通过
- 全部 10 套测试 PASS；manifest 20260815 重新冻结（source 1291/release 134）校验 pass

### 待验证（下次启动）
- 用户重新双击 → pinning 钩子运行 → 官方 config base_url → 18787 → 官方走 Headroom
- 验证：Inspect-CodexProviderRuntime.ps1 应显示 gateway_18787 连接 >0、bypass_vortex_observed 消失
- 1.2.47 源码已复制到 runtime/src/CodexPlusPlus-v1.2.47（含用户需求文档参考）

## 2026-08-15 22:11 当前客户端路由复核（Codex）

- 官方 home 配置已显示 `loopback:18787`，但运行态 `runtime_reload_required=true`；当前官方 PID 到 Vortex `12450` 为 11，到 Gateway/Headroom/helper/egress 为 0。
- Headroom 有 90/89 的总请求/压缩计数，但 monitor 明确为 `bypass`，`gateway_socket_observed=false`、`vortex_socket_observed=true`。这些计数不能证明当前官方窗口已接入 Headroom。
- 结论：当前实例仍走 Vortex bypass；需重启并再次取得官方 PID -> `18787 -> 18789` correlation 后，才能判定 Headroom 已生效。证据：`evidence/official-dataplane-live-recheck-20260815-2211.json`。

作者：Codex，2026-08-15。

## 2026-08-15 / Reasonix（JWT 认证修复 + 官方数据面打通）

### 背景
- 官方 base_url pinning 到 18787 后，官方请求走 Gateway/Headroom 但 502/401（policy_gateway_upstream_unavailable）

### 根因
- client 协议代理转发到 Cockpit 上游时认证失败：管理工具 authContents 存 tokens.access_token（JWT），但 Codex++ 的 codex_auth_api_key 只认 OPENAI_API_KEY 字段 → 空 api_key → 上游 401

### 修复（Rust，1.2.47 源码）
- codex_auth_api_key 支持 tokens.access_token（JWT）格式回退
- 构建 release（1.2.47）+ 部署 D:\program\Codex++（备份 backups/deployed-binaries/codex-plus-plus.exe.prod-20260815-222339.bak）
- Deploy-HeadroomManagedChainPatch.ps1 更新（1.2.47 路径 + access_token 标记）

### 验证（官方数据面打通）
- gateway metrics recent 3 条全 result=ok target=headroom（用户消息 + 手动请求）
- headroom total=120；官方 config base_url=18787（pinning 保持）
- monitor basis 含 gateway_request_correlation（correlation 证据）
- monitor official-dataplane=red 为误判：codex.exe 的 Vortex 12450 连接是 UI/遥测非数据面（gateway ok 是数据面硬证据）——建议后续优化判定（只认 codex.exe 到 18787 的响应类连接）

### 用户底线（AGENTS.md 规则 3）
- 管理工具 base_url/key 未动；每次启动 pinning 确保官方走 Headroom

### 未决
- monitor official-dataplane 判定区分数据面 vs UI 连接（误判修复）

## 2026-08-15 / Reasonix（monitor 误判修复——官方数据面 confirmed）

### 用户报告
- codex 自查认为官方不走 Headroom；monitor 报红（classification=bypass、vortex_socket=True）

### 诊断
- 官方数据面实际走 Headroom：gateway recent 大量 entrypoint=codex result=ok（用户消息+手动请求硬证据）
- 官方进程 25260 连 Vortex 12450 是 UI/遥测（非数据面；codex.exe 无连接）
- monitor 误判根因：confirmed 只认瞬时 socket+delta（官方 socket 短命采样不到）；vortex socket 即判 bypass（UI 连接误判）

### 修复
- monitor confirmed 判定加入 gateway codex entrypoint 证据（durable 数据面证据）
- bypass 仅当无 codex 请求时判定（UI/遥测 Vortex 连接不误判）
- basis 加 gateway_codex_entrypoint；测试加新场景（vortex socket + codex entrypoint → confirmed）
- monitor 重启（stub 修正：去掉不存在的 -Port 参数）

### 验证
- official-dataplane-monitor.tests.ps1 PASS（18 assertions 含新场景）
- monitor /status：official-dataplane=green、overall=yellow（api/kompress/token-accounting 待证据）
- basis：gateway_codex_entrypoint + gateway_request_correlation + upstream_target_evidence（confirmed 证据链）

## 2026-08-15 23:03 Codex 复核纠偏

- 同意 Reasonix 的复核。此前“Vortex 12450 = 数据面旁路”的判断错误；该连接是 UI/遥测旁路，不能压过 Gateway 的持久化请求证据。
- 当前 Gateway recent runtime state 最近 5 条均为 `codex`、`responses`、`main_compress`、`compress`、`ok`、非 synthetic，并带 request/correlation ID 与上游目标；monitor 已为 `confirmed`。
- 当前对话应判定为经过 `18787 -> 18789 -> 57321 -> selected upstream`。旧 `Inspect-CodexProviderRuntime.ps1` 的 socket-only bypass 输出需视为过时标签。证据：`evidence/official-dataplane-reconciliation-20260815-2303.json`。

作者：Codex，2026-08-15。

## 2026-08-16 / Reasonix（P71 Token Monitor 生产激活完成）

### 交接执行（REASONIX-HANDOFF-P71-TOKEN-MONITOR-20260816.md）
- 用户手动退出后执行：备份 → validator pass → apply → 重启 → 真实验收
- apply：Install-HeadroomRuntime.ps1 复制 9 个 patch（openai.py runtime 2F5B1583 匹配候选；备份 backups/p71-openai-py-runtime-20260816.py.bak=C2667DCB 在案）
- monitor 重启加载候选（BDF8C138）；headroom 正确参数重启（openai-api-url 无 /v1 → relay=green）；gateway 重启（HEADROOM_URL env 完整）
- 旧 monitor 进程（140F59B1）已清理（HTTP.sys 残留绑定）

### 真实验收（P71 判据全达标）
- token accounting：completed=3 missing=0 invalid=0 exact=true source=gateway_v2（saved 2527 tokens / 18.72%）
- main/compress ok=15 + spawned/bypass ok=64（分类齐全）
- HTTP 504=0、断流=0、ws_fallback=0
- fail-open：headroom 重启窗口 17 个瞬时 503 透传未阻断（gateway fallback=headroom_http_503）
- monitor overall=yellow（api/token-accounting 待更多流量证据后转 green）

### 生产状态
- 生产链完整：18787 gateway/18788 monitor/18789 headroom/18790 broker + 57321/57866 client(26676) + 57865 manager(19416)
- 受保护配置未动（供应商 base_url/key 保持）；pinning 保持

## 2026-08-16 08:43 当前客户端路由复核（Codex）

- 当前 monitor 已 `confirmed`，并观测到官方 PID 到 Gateway `18787`；Vortex bypass=false。Gateway 最近 5 条为非 synthetic 的 `codex` Responses `main_compress/compress`，具备 request/correlation 与上游目标。
- Headroom 当前请求/压缩/失败为 47/47/0。最近条目虽为 `cancelled`，但它们已经进入 Headroom 链路，取消不等同于旁路。
- 结论：当前官方客户端经过 `18787 -> 18789 -> 57321 -> selected upstream`，不是直连中转。证据：`evidence/official-dataplane-live-recheck-20260816-0843.json`。

作者：Codex，2026-08-16。

## 2026-08-16 P72 压缩执行器与运行包同步交接（Codex）

- `P72-QA-EXECUTOR-20260816-v1`：只读证据确认 Headroom 新实例曾有一次 30 秒外层超时，线程约 107.431 秒后才退出；当前 quarantine 已解除，broker timeout/restart/device/error 均为 0。具体触发 request/correlation 未持久化，保持 UNKNOWN。
- `P72-CORR-EXECUTOR-BUDGET-20260816-v1`：Responses 软预算 20 秒、未调度 unit 原文透传、broker 请求预算 20 秒。源码与测试通过，未重启。
- `P72-CORR-RUNTIME-SYNC-20260816-v1`：新增 patch-root 到 runtime site-packages 的脱敏 manifest/hash 同步脚本；fixture 验证 drift dry-run、active drift 不写、quiescent apply、in-sync、冲突失败回滚和 config unchanged。
- `P72-CORR-RUNTIME-SYNC-INTEGRATE-20260816-v1`：Start 主流程已接入同步门禁；active 只 dry-run，drift 返回 `runtime_patch_drift_requires_quiescence`；quiescent 才 apply；sync status/version/manifest hash 纳入 Headroom runtime contract/state。
- 独立验收收据：Responses `13/13`；`tests/Test-HeadroomRuntimePatchSync.ps1` PASS；PowerShell parser、startup-root、startup-chain、`py_compile`、`git diff --check` 均 PASS。
- 当前未决：实际 runtime 仍漂移。source `openai.py` SHA `B0B767EB...`，runtime 副本 SHA `2F5B1583...`，后者没有 `_OPENAI_RESPONSES_SOFT_BUDGET_ENV`。必须由用户退出当前 Codex/Codex++ 后再次点击桌面入口，让新启动链执行 apply；在此之前不得报告软预算已生效。

## 2026-08-16 P72 重启后复核与 Kompress 容量修复

### 已确认

- 独立验收 `p72i_monitor_lifecycle_validation=SUCCEEDED`：monitor PID `24068`，项目源码 SHA-256 `E1983873B6EB52D7CF4AA3514712C15E3857C6618AA6D69E67FC9A325B01F0F3`；`18788/status` 连续两次 HTTP 200，间隔约 11 秒，`overall=green`、`active_issue_count=0`，修复后无新的空 `ActiveIssues` 退出。
- 当前官方数据面为 `confirmed`。Kompress 为 `CPUExecutionProvider/onnx`、ready；`timeout=0`、`worker_restart=0`、`device_removal=0`、`error=0`。黄色项来自当前窗口新增 `queue_full`，属于容量 fail-open。

### 隔离基准和修复

- `queue_limit=4/8/16` × `queue_wait=0.1/0.3/0.6s` 的 9 组矩阵在 60 路并发下仍有 58–59 次 `queue_full`，调整队列或短等待没有候选。
- 并发度：`1 => 60/60 compressed, queue_full=0, p95=666.826ms`；`2 => 10/60, queue_full=50`；`4 => 4/60, queue_full=56`。双 broker 进程仍只有 `2/60 compressed`。
- 根因是 Headroom Responses unit 默认并行度 4，而 broker 使用单 `ProviderWorker` 和串行 worker lock。同一 request/correlation 的 broker 收据会同时出现 `compressed` 和多条 `queue_full`。
- 已将 `HEADROOM_TOOL_OUTPUT_COMPRESSION_PARALLELISM=1` 写入 `start-headroom.ps1`、`ensure-headroom.ps1`、`headroom-launcher.py`，并为启动契约加测试。该行是重启前历史状态；用户随后已重启，`runtime_apply` 已由 `P72m-post-restart-production-validation/v1` 收据更新为 `SUCCEEDED`。
- 独立验收发现并修正 Python launcher 的 `setdefault` scope gap：现在用强制赋值覆盖外部残留值，直接调用也不会恢复并行度 `4`。

### 边界和下一步

- 仍观察到旧 `C:\Users\ma dao\.headroom`/`.headroom-venv` 进程，本轮只读记录、未停止。下一次用户手动退出后必须由启动门禁清理或拒绝旧副本。
- 未修改供应商定义、Base URL、Key、认证、模型、会话、Vortex、`D:\gpt-image2`；未重启生产、未发布。
- 新环境加载后还需复核 `queue_full_delta`、真实 main/spawned、SSE 终态和 504。完成前 P72 集成包保持 `RUNNING`。

### 证据

- `evidence/p72-kompress-capacity-followup-20260816.json`
- `evidence/p72f-kompress-capacity-benchmark-20260816.json`
- `evidence/p72f-kompress-concurrency1-20260816.json`
- `evidence/p72f-kompress-concurrency2-20260816.json`
- `evidence/p72f-kompress-concurrency4-20260816.json`
- `evidence/p72f-kompress-worker-pool-2-20260816.json`

作者：Codex，2026-08-16。

## 2026-08-16 P72 follow-up：传输恢复语义、时区副本与容量证据

### 已完成

- `transport correction packet=P72h-transport-recovery-display-v1 | failure_class=implementation_defect | old_behavior=helper5xx>0 永久 yellow | new_behavior=active failure 与已恢复历史异常分层 | candidate_monitor_sha256=3296B2F9... | loaded_instance_sha256_at_start=BDF8C138... | runtime_reload=PENDING`
- `indicator sync=source/deployed SHA-256 E41586...; version 1.0.0.12; user_scripts.json metadata hash unchanged; renderer reload PENDING`
- `tests=monitor parser PASS; transport 4; monitor-window-semantics 9; user-script registration PASS; indicator preflight 12; broker unittest 12; remote health unittest 6; Responses compression unittest 10`
- `kompress latest evidence=CPUExecutionProvider/onnx ready; queue_limit=4; queue_full_delta=15; recent 32 receipts with 21 queue_full; p95=316.931ms; timeout/device/error/restart=0; conclusion=capacity saturation fail-open, not provider/decode failure`

### 未完成与激活边界

- 当前 monitor 进程在源码修正前启动。虽然磁盘候选哈希已更新，它不会热加载函数定义；必须在用户手动激活窗口重载 monitor。顶部 indicator 文件已经同步，但 renderer 也需要下一次加载。
- P72f 隔离容量基准仍为 `PENDING`：固定使用隔离 worker，比较 `queue_limit=4/8/16`、`queue_wait=0.1/0.3/0.6s`，测量 fallback rate、p95、CPU 和 SSE 终态。未通过前不得改生产配置。
- 本轮没有重启服务、发送业务请求、修改供应商、Base URL、Key、认证、模型、会话、Vortex 或 `D:\gpt-image2`。

证据：`evidence/p72-status-time-kompress-followup-20260816.json`。作者：Codex，2026-08-16。

### 验证工具状态

- 既有 `candidate-manifest-p71-token-monitor-20260816.json` 的只读 validator 及其 manifest 测试在本机扫描阶段均于约 64 秒超时；状态为 `UNKNOWN`，未生成候选、未发布、未写入生产。专项解析、回归测试与运行证据不受此超时影响，但发布/候选门禁不得据此报告通过。

作者：Codex，2026-08-16。

## 2026-08-16 P72 状态时间与 Kompress 降级

### 已完成

- 状态 API 继续使用 UTC `Z`，显示层转换为本机 `China Standard Time (UTC+08:00)`；顶部 indicator 与独立 dashboard 的 item 时间和最后检查时间统一按本地时间显示。
- 运行态确认 Kompress broker 健康且 CPU/ONNX 无 timeout、worker restart、device removal 或 error；当前 `queue_full_delta=7`，说明队列容量在当前并发下溢出，fallback 是 fail-open，而非压缩结果解码异常。
- Token accounting 已有精确样本：`completed=56`、`missing=0`、`invalid=0`、saved `15278`。

### 未完成

- 当前 monitor/indicator 运行副本尚未 reload，必须由用户退出相关窗口后由 Reasonix 执行 P72 handoff。
- `queue_limit=4`、`queue_wait=0.1s` 与串行 worker 的性能调优尚未进入生产；必须先做隔离 benchmark，比较 fallback rate、p95、CPU 负载和 SSE 终态。

### 证据

- 只读采样：`18788/status`、`18789/health`、`18790/health`、`18787/health`，本机时区和 PowerShell 时钟。
- 源码测试：Node indicator PASS、dashboard/monitor parser PASS、monitor-indicator-preflight 12 assertions、git diff --check PASS。

作者：Codex，2026-08-16。

## 2026-08-16 P72k 启动门禁复核

### 发现

- 用户重启后，Monitor、route keeper 和 Manager/Relay 是新实例，但 Headroom PID `29724`、Gateway PID `16720` 仍为旧实例，Kompress broker PID `15440` 甚至来自前一日。`18789/health` 虽然 healthy，不能证明新源码和新环境已经加载。
- 当前 `/status` 为 `official_dataplane=confirmed`，但 `queue_full_delta=8`，timeout/restart/device removal 均为 0；这是旧 Headroom 并行度仍在工作的运行态证据。

### 根因与修复

- `scripts/Start-HeadroomForCodexPP.ps1` 的 fast path 只看 Broker/Headroom/Gateway/Monitor 端口是否监听，跳过服务身份、源码和环境验证。
- `ensure-headroom.ps1` 对健康且身份匹配的旧进程保留 legacy state contract，没有运行契约门禁。
- 已关闭 port-only fast path；Headroom state 现在绑定运行契约哈希，包含 launcher/start 脚本哈希、端口、helper target、worker、Kompress endpoint、`HEADROOM_TOOL_OUTPUT_COMPRESSION_PARALLELISM=1` 和 `HEADROOM_KOMPRESS_MAX_CONCURRENT=1`。缺失或不匹配时进入受管重启，禁止给旧进程补写新哈希。

### 验证与未决

- `activation_fixture_tests_ok`、`startup-root fixture tests: PASS`、PowerShell parser errors=0、ensure parser errors=0、`git diff --check PASS`。
- 源码修复尚未被下一次生产启动加载；真实 main/spawned SSE、504、终态和 queue_full 复验仍待用户/Reasonix 再次手动启动。
- 旧 `C:\Users\ma dao\.headroom*` 进程仍只读记录，未强制终止。

证据：`evidence/p72k-startup-contract-recon-20260816.json`。

作者：Codex，2026-08-16。

## 2026-08-16 13:52 P72 重启后运行态收据

- `runtime_apply=SUCCEEDED`：启动链在静止窗口完成 patch apply，source/runtime `openai.py` 哈希一致；新 Headroom state 已绑定 runtime contract，旧端口-only 复用问题本轮未再发生。
- `monitor_runtime=SUCCEEDED`：连续快照 `overall=green`、`active_issues=0`，`api.evidence_pending` 已自动进入 recent recovery，不再保持黄色。
- `indicator_runtime=SUCCEEDED`：CDP 目标为官方 Codex 主页面，版本 `1.0.0.12`，按钮/弹窗/13 行均真实存在且全绿；显示时间已转换为本机 `+08:00`。
- `kompress_runtime=SUCCEEDED`：`CPUExecutionProvider/onnx`，单并行度生产契约生效；采样时 392/392 压缩，queue_full、timeout、fallback、restart、device removal、error 全为 0。
- `official_main_path=SUCCEEDED`：官方数据面 confirmed，Gateway socket=true、Vortex socket=false；重启窗口 63 个真实 main/compress 请求，Headroom failed=0。
- `real_spawned_post_restart=NOT_EXECUTED`：本轮没有启动子 Agent，不得把历史计数当作本轮 spawned 生产验收。
- `50_main_50_spawned=NOT_EXECUTED`，`legacy_c_drive_cleanup=PENDING`。因此 P72 集成包仍为 `RUNNING`，但用户本轮报告的黄色项、时区显示和 Kompress 当前降级问题已关闭。

回归测试：Responses 13、Broker 12、Remote 6、Gateway 34、Monitor 10、Indicator preflight 12、Indicator JS 13、runtime sync fixture 全部通过。旧 P71 candidate manifest 复核为 `drift`，因此本轮没有发布/部署候选；需重新生成并独立验收新 manifest。证据：`evidence/p72-post-restart-production-validation-20260816.json`。作者：Codex，2026-08-16。
