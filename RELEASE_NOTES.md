### OpenAI Codex support

CCSwitcher now tracks OpenAI Codex alongside Claude Code. A switcher in the top-right of the popover flips the whole app between providers — usage, costs and accounts all follow.

- **Usage and limits** come live from your ChatGPT account, including per-model limits such as GPT-5.3-Codex-Spark and your credit balance. Windows are identified by their actual duration rather than a fixed name, so whatever limits OpenAI exposes for your plan show up correctly. With no network, CCSwitcher falls back to the last snapshot Codex itself wrote locally, and says so.
- **Costs** are computed from your local Codex session files and priced with current OpenAI rates. Expect a large number if you run parallel subagents: it is what the same work would cost through the API, not what your subscription charges.
- **A matching theme.** Codex mode uses a flat near-black scheme modelled on the ChatGPT desktop app, with the ChatGPT mark in the switcher.

### Live pricing behind a "?"

The Costs tab has a new help button showing the exact per-million-token rates being applied, for the models you actually used, along with how current the price table is. A model with no published rate is called out rather than silently billed at zero.

### Menu bar and widget follow the active provider

Menu-bar modules are configured separately per provider, so Codex can show different things than Claude. Window labels are derived from the real window instead of a hard-coded `5H`/`7D`, a new module surfaces model-scoped limits, and the desktop widget switches to the Codex look when Codex is active. The active provider now also refreshes on the periodic timer, so the menu bar stays current without opening the popover.

### Fixes

- Claude cost figures are unchanged by the new OpenAI pricing rows — verified row by row.
- Session counts are preserved on the Costs tab.

---

### 支持 OpenAI Codex

CCSwitcher 现在可以在跟踪 Claude Code 的同时跟踪 OpenAI Codex。弹窗右上角的切换器可在两个服务商之间切换，用量、费用和账户都会随之变化。

- **用量与限额** 直接从你的 ChatGPT 账户实时获取，包括 GPT-5.3-Codex-Spark 这类按模型划分的限额以及积分余额。窗口按实际时长识别，而非固定名称，因此你的套餐提供的任何限额都能正确显示。没有网络时，CCSwitcher 会回退到 Codex 自己在本地写入的最近快照，并明确标注。
- **费用** 根据本地 Codex 会话文件计算，并按当前 OpenAI 价格计价。如果你并行运行多个子代理，这个数字会很大：它表示同样的工作通过 API 需要多少钱，而不是你的订阅实际扣费。
- **匹配的主题。** Codex 模式采用参照 ChatGPT 桌面端的纯黑配色，切换器中使用 ChatGPT 标识。

### "?" 按钮中的实时价格

费用标签页新增帮助按钮，显示实际生效的每百万 token 单价（仅列出你真正用过的模型），并说明价格表的更新时间。没有公开价格的模型会被明确标出，而不是静默按零计费。

### 菜单栏与小组件跟随当前服务商

菜单栏模块可为每个服务商单独配置，因此 Codex 可以显示与 Claude 不同的内容。窗口标签由真实窗口推导得出，不再硬编码为 `5H`/`7D`；新增模块用于显示按模型划分的限额；当 Codex 处于活动状态时，桌面小组件会切换为 Codex 外观。当前服务商现在也会随定时器刷新，无需打开弹窗即可保持菜单栏数据最新。

### 修复

- 新增的 OpenAI 价格数据不会影响 Claude 的费用计算——已逐行核对。
- 费用标签页保留会话数量显示。

**Full Changelog**: https://github.com/vientooscuro/CCSwitcher/compare/v1.12.0...v1.13.0
