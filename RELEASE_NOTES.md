### Fixes wildly inflated Codex figures

Codex cost, turns and active time were counted many times over. When a session is resumed, or when it spawns a subagent, Codex writes a new session file that replays the whole history — so the same usage was counted once per file. One real day showed **$77,367 instead of $751**, and 52 hours of "active" time in a 24-hour day.

Usage is now merged per session and deduplicated before anything is summed. If you ran v1.13.0, your Codex numbers were too high; this release recomputes them from scratch on first launch, which takes a minute or two if you have a large session history.

Claude figures were never affected.

#### Included from v1.13.0

CCSwitcher now tracks OpenAI Codex alongside Claude Code. A switcher in the top-right of the popover flips the whole app between providers — usage, costs and accounts all follow.

- **Usage and limits** come live from your ChatGPT account, including per-model limits such as GPT-5.3-Codex-Spark and your credit balance. Windows are identified by their actual duration rather than a fixed name, so whatever limits OpenAI exposes for your plan show up correctly. With no network, CCSwitcher falls back to the last snapshot Codex itself wrote locally, and says so.
- **Costs** are computed from your local Codex session files and priced with current OpenAI rates.
- **A matching theme.** Codex mode uses a flat near-black scheme modelled on the ChatGPT desktop app, with the ChatGPT mark in the switcher.
- **Live pricing behind a "?"** on the Costs tab: the exact per-million-token rates being applied, for the models you actually used, plus how current the price table is. A model with no published rate is called out rather than silently billed at zero.
- **Menu bar and widget follow the active provider.** Modules are configured separately per provider, window labels are derived from the real window instead of a hard-coded `5H`/`7D`, a new module surfaces model-scoped limits, and the active provider refreshes on the periodic timer.

---

### 修复 Codex 数据严重虚高

Codex 的费用、轮次和活跃时间被重复计算。会话被恢复或派生子代理时，Codex 会写入一个新的会话文件并重放全部历史记录，因此同一份用量在每个文件中都被计入一次。某一天实际显示为 **77,367 美元，而真实值是 751 美元**，并且在 24 小时的一天里出现了 52 小时的"活跃"时间。

现在用量会先按会话合并去重，然后才进行汇总。如果你使用过 v1.13.0，你看到的 Codex 数字偏高；本次更新会在首次启动时重新计算，若会话历史较多，可能需要一两分钟。

Claude 的数据自始至终未受影响。

#### 包含 v1.13.0 的更新

CCSwitcher 现在可以在跟踪 Claude Code 的同时跟踪 OpenAI Codex。弹窗右上角的切换器可在两个服务商之间切换，用量、费用和账户都会随之变化。

- **用量与限额** 直接从你的 ChatGPT 账户实时获取，包括 GPT-5.3-Codex-Spark 这类按模型划分的限额以及积分余额。窗口按实际时长识别，而非固定名称。没有网络时，会回退到 Codex 本地写入的最近快照，并明确标注。
- **费用** 根据本地 Codex 会话文件计算，并按当前 OpenAI 价格计价。
- **匹配的主题。** Codex 模式采用参照 ChatGPT 桌面端的纯黑配色，切换器中使用 ChatGPT 标识。
- **"?" 按钮中的实时价格**：费用标签页显示实际生效的每百万 token 单价（仅列出你真正用过的模型），并说明价格表的更新时间。没有公开价格的模型会被明确标出，而不是静默按零计费。
- **菜单栏与小组件跟随当前服务商。** 模块可为每个服务商单独配置，窗口标签由真实窗口推导得出，新增按模型划分限额的模块，当前服务商也会随定时器刷新。

**Full Changelog**: https://github.com/vientooscuro/CCSwitcher/compare/v1.13.0...v1.13.1
