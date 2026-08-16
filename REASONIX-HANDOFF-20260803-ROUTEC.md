# Reasonix 交接：Route C 与 Codex++ 崩溃收口

生成时间：2026-08-03（Asia/Shanghai）
交接方：Codex（主负责人）
当前结论：Route C native 集成仍未完成；生产 Route C 继续 `off`。本文件只交接未完成项和可复核证据，不代表已通过验收。

## 现场先决事实

- 官方源码基线已经核对：`runtime/src/CodexPlusPlus-v1.2.44`，版本 `1.2.44`，commit `77091ccaee4423f35a1b2c51c4ecd703e6201092`，ZIP 与官方 tree 281/281 一致。
- 供应商 SettingsStore 已恢复 6 个原 profile。恢复源 SHA-256：`DDB69F35535BD99DDBCFAA91C7F04CC664C1C89C902586B5FB059FC2BBACD999`。当前 Manager 启动后会自行重序列化设置；最新现场只读显示仍是 6 个 profile、无聚合项，但 live hash 已由 Manager 改写，当前 UI/内存态必须人工重启后重新核对。不要把恢复源 hash 当作运行态 hash。
- 生产监听当前仍是受管链：`57321/57865/57866/18787/18789/18790`；本交接未停止生产进程，未写官方 `config.toml`、Vortex、认证或会话。
- CrashSender 相关证据：2026-08-03 10:45:26 本机 WER 记录 WindowsApps `codex.exe` 异常 `0xc0000409`，WER 1000/1001，存在 `codex.exe.30436.dmp`；桌面日志同时有 401、stdio stop、EPIPE 和 sampler 失败，但没有 Headroom correlation。归因暂为 `UNKNOWN`，不要把它直接归因于压缩或供应商恢复。收据：`evidence/crash-audit-20260803.json`。

## Route C 计划逐项状态

| 计划项 | 状态 | 证据/缺口 |
|---|---|---|
| v1.2.44 源码恢复 | 已完成并独立核对 | `evidence/p47-route-c-source-recovery-20260802.json`、`p47b...` |
| Node 22/Rust/MSVC 隔离工具链 | 部分完成，需复核 | Node 22、Rust、npm 收据存在；native 构建仍未产出可运行 Canary，VS C/C++ headers/库阻塞曾出现 |
| Route C 合同模块 P50 | 源码已写，测试未闭环 | `route_c.rs` 有 mode/capability/loopback/header/SSE/fail-open；无完整 `cargo test` 收据 |
| supervisor/lease P51 | 源码已写，测试未闭环 | `supervisor.rs` 有脱敏 lease/heartbeat/stale；无完整 native 编译验收 |
| native dataplane P52 | 未完成 | `route_c_runtime.rs`、`launcher.rs`、Manager 参数透传存在；默认仍 `off`，无可运行二进制/生产生效证据 |
| egress readiness P53 | 未完成/不可验证 | `launcher.rs:1758` 附近新增 loopback `/health`、`/livez` 早处理和单测；`runtime/canary/route-c/p53-build-target` 只有 Cargo 中间产物，无 exe、无 P53 receipt，施工员回执丢失 |
| Python 隔离 PoC P48 | 已完成但非 native | `evidence/p48-route-c-isolated-poc-20260802.json`；不能替代 native Canary |
| native Canary `Start-RouteCCanary.ps1` | 未通过 | 脚本存在；`runtime/canary/route-c/current/app` 未生成；`Activate-RouteCCanary.ps1`、`Rollback-RouteCCanary.ps1` 当前未找到 |
| Reasonix 用户激活 | 未执行 | 必须用户手动退出所有官方/Manager/Client 后，由 Reasonix 处理 UAC/Canary 激活 |
| 1+1、10+10、50+50 官方窗口验收 | 未执行 | 没有官方 PID→ingress→Gateway→Headroom→egress→假/真实上游全链 correlation |
| UI/indicator 回归 | 未完成 | 现有 renderer/user-script 必须保留；CDP、popup、供应商切换和 lease 共存未独立复核 |
| 24 小时自然样本、登录/注销、替换安装 | 未执行 | 只能在 Canary 全部闸门通过后进行 |

## Reasonix 下一步

1. 先只读核对当前共享树和 `git status`，确认 `launcher.rs` 的 P53 改动来自本包；不要覆盖其他改动。
2. 在隔离环境补齐或提供可复核的 MSVC headers/库；不得安装到系统全局、不得改 `D:\program\Codex++`。
3. 运行并保存：`cargo fmt --all -- --check`、`cargo check --workspace`、`cargo test --workspace`、`cargo clippy --workspace --all-targets -- -D warnings`、launcher/manager build。失败需记录完整首个编译错误和环境版本，不把中间产物当成 Canary。
4. 生成 `runtime/canary/route-c/<build-id>/app/codex-plus-launcher.exe` 后，先用 `Start-RouteCCanary.ps1 -DryRun`，再用隔离端口运行 fake upstream；验证 `/health`/`/livez`、lease/capability、main compress、spawned bypass、SSE completed/failed、崩溃/超时/fail-open、端口释放。
5. 若隔离 Canary 通过，用户手动退出 ChatGPT/Codex/Manager/Client；Reasonix执行 Canary 激活和 1+1→10+10→50+50 闸门。任一失败只运行本 generation 回滚，不动生产供应商或 Vortex。
6. 对 CrashSender：先把 `0xc0000409` 与精确 packaged build/dump/WER 对齐；只有在复现“Headroom off + 直连”和“Route C Canary”差异后，才能决定是否为本项目问题。不要读取或上传 dump/会话正文。

## 保护边界

- 禁止修改供应商定义、Base URL、API key、认证、模型、会话、官方 `config.toml`、Vortex、系统代理和 `D:\gpt-image2`。
- 禁止停止/重启当前生产进程；需要真实激活时由用户手动完成。
- 禁止 git reset/clean/force-push；不上传 runtime、缓存、日志、凭据、会话正文、dump 或模型。
- 每一步写入都要追加 `HANDOFF.md`、`README.md`、`WORK.md`，记录作者、证据、测试和未决项。

## 现有收据

- 供应商恢复：`evidence/supplier-recovery-dryrun-20260803.json`、`evidence/supplier-recovery-execute-20260803.json`
- 崩溃审计：`evidence/crash-audit-20260803.json`
- Route C 源码/工具链：`evidence/p46-route-c-toolchain-prep-20260802.json`、`evidence/p47-route-c-source-recovery-20260802.json`、`evidence/p47b-route-c-source-promotion-acceptance-20260802.json`
- 隔离 PoC：`evidence/p48-route-c-isolated-poc-20260802.json`

## P57 执行回收（2026-08-03）

- 已正式派发 `P57-reasonix-route-c-closeout/v1` 给 Reasonix；worker 最终被停止，未返回可读构建/测试/Canary 收据。
- 共享树可观察到部分改动：launcher 的 Route C 参数/生命周期透传，以及 egress `/health`、`/livez` loopback 提前响应。它们尚未通过完整编译、测试和隔离端到端验证，状态为 `UNKNOWN`。
- 证据：`evidence/reasonix-route-c-closeout-20260803.json`。生产 Route C 继续 `off`，任何 native 二进制、真实官方窗口接入和 1+1→50+50 验收都不能据此宣称完成。
- 接手者必须先审查共享树差异，再重新运行完整构建矩阵和隔离 Canary；所有用户手动退出/启动/UAC/真实窗口/回滚/24 小时样本仍是后续阶段。

## P58 独立复核补充（2026-08-03）

- Codex 独立复跑隔离 Canary：传输链、HTTP 200、`response.completed`、main/spawned 策略和端口清理均通过。
- 长 main synthetic 请求仍没有触发实际压缩：Headroom `requests_compressed=0`、`tokens_saved=0`、`memory_skip_reason=no_handler`；Kompress broker `total=0`。因此必须补“真实压缩执行”证据，不能只看 Gateway `main_compress`。
- 独立干净构建未复现 Reasonix 的 PASS：已有 target 报 `E0463`；新 target 报 Rust `0xc0000409 / STATUS_STACK_BUFFER_OVERRUN`。当前 exe 可运行不代表源码构建可重复。
- P58 收据：`evidence/route-c-independent-audit-20260803.json`。在构建复现和 Kompress 非零计数通过前，Route C 仍不得进入生产或官方窗口。
