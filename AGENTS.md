# Headroom for Codex++ 项目规则

1. 每次开工前先阅读 `README.md` 和 `HANDOFF.md`，再核对本机全局 `AGENTS.md`。
2. 生产路由必须经过 Headroom/Gateway；不得把直连当作 Headroom 已生效。
3. 不得修改 Codex++ 管理工具的供应商定义、Base URL、API key、认证、模型、会话或二进制。进程级路由覆盖必须可验证且不得写入供应商配置。
   - 用户底线（2026-08-15 确认）：管理工具供应商配置页面中的 `base_url` 和 `key` 字段**不可修改**（用户通过管理工具维护供应商配置）。
   - 官方路由 pinning（`Invoke-OfficialRoutePinning`）只改写官方 home `~/.codex/config.toml` 的 `codex_local_access.base_url` 指向本地 Gateway（`http://127.0.0.1:18787/v1`），供应商真实地址保留在 `settings.json` relayProfiles——**每次启动（含供应商切换后再次启动）都必须确保 Codex 桌面端走 Headroom 链路**（此条为用户硬性要求，任何改动不得破坏）。
4. `main` 使用压缩策略，真实 spawned 子 Agent 使用 bypass；不得仅凭 `thread_source=subagent` 分类。
5. 压缩异常、超时、ONNX/provider 失败和解码异常必须 fail-open，不得阻断原始请求或制造 504。SSE 原始字节必须透传。
6. GPU/NPU/MIGraphX/DirectML 只能在隔离 worker 中试验；未经完整模型、重复运行和流式联测通过，不得成为生产后端。
7. 不得显示、提交或上传凭据、令牌、完整会话正文、认证数据库或个人数据。日志、普通运行状态、缓存和模型文件可以保留在本地项目副本，但发布前必须重新检查脱敏和体积。
8. 不得修改、清理或回滚 `D:\gpt-image2`；不得使用 `git reset --hard`、`git clean`、强制推送或批量恢复。
9. 每次对话结束前更新 `README.md` 和 `HANDOFF.md`，记录作者、改动、证据、测试和未解决问题。
