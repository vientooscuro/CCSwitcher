### More reliable account tracking

- A running Claude Code session rewriting its profile no longer changes which account CCSwitcher treats as active, or touches your live token. The owner of the token is now recognised by its fingerprint.
- If the owner can't be determined, the account card asks you to switch once instead of showing another account's usage.
- Saved accounts with empty credentials can't be switched to, and empty credentials never replace a saved account.
- `~/.claude.json` is now written more safely: changes made by another program during a write are kept, and symlinks and file permissions are preserved.
- Email addresses are masked in the app log.

#### Included from v1.13.6

- Fix keychain prompts that kept coming back: saved accounts are now read by CCSwitcher itself, so "Always Allow" sticks.
- Prompts stay open long enough to type your password instead of closing after 5 seconds.
- After a denied prompt, CCSwitcher waits a minute before asking again.
- A failed read of saved Codex accounts can no longer overwrite the others.

#### Included from v1.13.5

- Fix a session being lost when another program changed the active Claude account: the newest token is now kept for its owner instead of being overwritten.
- A re-authenticated account recovers on the next refresh. Restarting the app is no longer needed to clear "Session expired and refresh failed".
- Temporary server errors such as rate limits no longer mark an account as needing to sign in again.
- Fix a slow Keychain read at launch that could make saved accounts look missing and put their credentials at risk of being overwritten.

### Codex

- Fix the Codex desktop profile socket path.
- Improve the Codex account layout.

#### Included from v1.13.1 to v1.13.4

- Price Claude Opus 5.5, GPT-6 Sol, GPT-6 Luna and GPT-6 Astra, and keep models without a verified price visibly unpriced.
- Refresh an expired token of the active Claude account automatically, and fix usage refresh right after switching accounts.
- Rebuild daily cost histories automatically and label the archive-wide cost as "All history".
- Fix heavily inflated Codex cost, turn and active-time figures caused by replayed session files.

#### Included from v1.13.0

- Track OpenAI Codex alongside Claude Code, with a provider switcher in the popover. Usage, costs and accounts follow the selected provider.
- See the exact per-million-token rates behind your costs with the "?" button on the Costs tab.
- Menu bar modules are configured per provider, and the menu bar and widget follow the active provider.

Costs remain estimates based on local usage and current model prices, not subscription invoices.

---

### 更可靠的账户跟踪

- 正在运行的 Claude Code 会话重写其配置信息时，不再改变 CCSwitcher 认定的当前账户，也不会影响当前令牌。现在通过指纹识别令牌的所属账户。
- 无法确定所属账户时，账户卡片会提示切换一次，而不是显示其他账户的用量。
- 无法切换到凭据为空的已保存账户，空凭据也不会覆盖已保存的账户。
- 更安全地写入 `~/.claude.json`：会保留其他程序在写入期间所做的更改，并保留符号链接和文件权限。
- 应用日志中的电子邮件地址会被遮盖。

#### 包含 v1.13.6 的更新

- 修复钥匙串弹窗反复出现的问题：已保存的账户现在由 CCSwitcher 自行读取，“始终允许”可以持续生效。
- 弹窗会保持足够长的时间以便输入密码，不再在 5 秒后关闭。
- 拒绝弹窗后，CCSwitcher 会等待一分钟再询问。
- 读取已保存的 Codex 账户失败时，不会再覆盖其他账户。

#### 包含 v1.13.5 的更新

- 修复其他程序更改当前 Claude 账户时会话丢失的问题：最新令牌现在会保留给其所属账户，不再被覆盖。
- 重新登录的账户会在下次刷新时恢复，无需重启应用即可清除“Session expired and refresh failed”。
- 限流等临时服务器错误不再将账户标记为需要重新登录。
- 修复启动时钥匙串读取缓慢可能导致已保存账户显示为缺失、其凭据有被覆盖风险的问题。

### Codex

- 修复 Codex 桌面配置文件的套接字路径。
- 改进 Codex 账户布局。

#### 包含 v1.13.1 至 v1.13.4 的更新

- 支持 Claude Opus 5.5、GPT-6 Sol、GPT-6 Luna 和 GPT-6 Astra 的价格，没有经过核实价格的模型会明确显示为未定价。
- 自动刷新当前 Claude 账户已过期的令牌，并修复切换账户后立即刷新用量的问题。
- 自动重建每日费用历史，并将全部归档费用标注为“All history”。
- 修复因会话文件重放导致 Codex 费用、轮次和活跃时间严重虚高的问题。

#### 包含 v1.13.0 的更新

- 在跟踪 Claude Code 的同时跟踪 OpenAI Codex，弹窗中提供服务商切换器，用量、费用和账户都会随之变化。
- 通过费用标签页的“?”按钮查看费用所用的每百万 token 单价。
- 菜单栏模块可按服务商分别配置，菜单栏和小组件会跟随当前服务商。

费用仍是根据本地用量和当前模型价格得出的估算值，并非订阅账单。

**Full Changelog**: https://github.com/vientooscuro/CCSwitcher/compare/v1.13.6...v1.13.7
