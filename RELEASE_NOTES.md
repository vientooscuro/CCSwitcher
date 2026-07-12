### Reliability fixes for account tokens & usage

- **Fixed the recurring "Session expired and refresh failed" loop.** CCSwitcher no longer runs its own OAuth refresh for the *active* account. That refresh competed with Claude Code refreshing the same rotating token, which tripped the server's refresh-token reuse detection and revoked the whole login every day or two. Token refresh for the active account is now delegated to the Claude CLI, so your signed-in account stays signed in.
- **Fixed accounts showing the wrong plan and limits** (for example, a personal Max account displaying a Team subscription and Team limits). Before saving an account's backup, CCSwitcher now confirms the live token's real identity via the Claude CLI, so one account's token can never be stashed under another account's slot.
- Additional hardening from this cycle: usage polling backs off correctly on repeated 429s from dead tokens, per-account usage responses are never cached (each account shows its own numbers), and account backups are guarded against identity mismatches.

**Full Changelog**: https://github.com/vientooscuro/CCSwitcher/commits/v1.11.4

#### Included from v1.11.0

- **Sonnet 5, Fable 5 and Opus 4.8** are now recognized in cost tracking, with correct per-token pricing (offline-ready from the bundled LiteLLM snapshot, revalidated over the network each cycle).
- Merged upstream v1.10.0: cost math re-derived to match ccusage 20.0.9, live LiteLLM pricing with ETag revalidation, Fable shown in the cost breakdown, configurable iStats-style menu-bar modules, and a Claude CLI binary picker in Settings.
- Fork extras kept: silent OAuth token refresh (no account switch), per-account 429 back-off, and a faster lock on Claude path resolution.

---

### 账号令牌与用量的可靠性修复

- **修复了反复出现的 "Session expired and refresh failed" 循环。** CCSwitcher 不再为*当前*账号自行执行 OAuth 刷新。该刷新会与 Claude Code 刷新同一个轮换令牌相互冲突，触发服务器的刷新令牌重用检测，导致整个登录每隔一两天就被吊销。现在当前账号的令牌刷新交由 Claude CLI 处理，让已登录的账号保持登录状态。
- **修复了账号显示错误的套餐与额度**（例如个人 Max 账号被显示为 Team 订阅和 Team 额度）。在保存账号备份前，CCSwitcher 现在会通过 Claude CLI 确认当前令牌的真实身份，因此一个账号的令牌绝不会被存到另一个账号的槽位里。
- 本轮的其他加固：对失效令牌反复返回的 429 正确退避、按账号的用量响应绝不缓存（每个账号显示各自的数字），以及对身份不匹配的账号备份进行防护。

**Full Changelog**: https://github.com/vientooscuro/CCSwitcher/commits/v1.11.4

#### 包含 v1.11.0 的更新

- 成本统计现已识别 **Sonnet 5、Fable 5 和 Opus 4.8**，并采用正确的按 token 计价（内置 LiteLLM 快照支持离线，且每个周期通过网络重新校验）。
- 合并上游 v1.10.0：成本计算重新对齐 ccusage 20.0.9、带 ETag 重校验的实时 LiteLLM 计价、成本明细中显示 Fable、可配置的 iStats 风格菜单栏模块，以及设置中的 Claude CLI 可执行文件选择器。
- 保留分支特性：静默刷新 OAuth 令牌（无需切换账号）、按账号的 429 退避，以及更快的 Claude 路径解析锁。
