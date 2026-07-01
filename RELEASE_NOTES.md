### New models & upstream sync

- **Sonnet 5, Fable 5 and Opus 4.8** are now recognized in cost tracking, with correct per-token pricing (offline-ready from the bundled LiteLLM snapshot, revalidated over the network each cycle).
- Merged upstream v1.10.0: cost math re-derived to match ccusage 20.0.9, live LiteLLM pricing with ETag revalidation, Fable shown in the cost breakdown, configurable iStats-style menu-bar modules, and a Claude CLI binary picker in Settings.
- Fork extras kept: silent OAuth token refresh (no account switch), per-account 429 back-off, and a faster lock on Claude path resolution.

**Full Changelog**: https://github.com/vientooscuro/CCSwitcher/commits/v1.11.0

---

### 新模型与上游同步

- 成本统计现已识别 **Sonnet 5、Fable 5 和 Opus 4.8**，并采用正确的按 token 计价（内置 LiteLLM 快照支持离线，且每个周期通过网络重新校验）。
- 合并上游 v1.10.0：成本计算重新对齐 ccusage 20.0.9、带 ETag 重校验的实时 LiteLLM 计价、成本明细中显示 Fable、可配置的 iStats 风格菜单栏模块，以及设置中的 Claude CLI 可执行文件选择器。
- 保留分支特性：静默刷新 OAuth 令牌（无需切换账号）、按账号的 429 退避，以及更快的 Claude 路径解析锁。

**Full Changelog**: https://github.com/vientooscuro/CCSwitcher/commits/v1.11.0
