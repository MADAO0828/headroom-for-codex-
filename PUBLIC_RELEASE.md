# Public Release Scope

This repository contains the Headroom/Gateway source, startup scripts, tests, project rules, and a model manifest. It intentionally excludes local runtime state, caches, logs, backups, credentials, authentication databases, session bodies, model binaries, and process-specific acceptance traces.

Production routing is process-scoped and must not rewrite Codex++ supplier configuration. The local project uses CPU ONNX Runtime as the production compression backend; GPU/NPU providers remain isolated experiments until they pass the full-model and streaming gates documented in the project README.
