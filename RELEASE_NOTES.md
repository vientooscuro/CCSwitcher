### Per-model limits: Fable 5 shown separately

- **Subscriptions can now carry a separate weekly limit for Fable 5**, and CCSwitcher shows it wherever the other limits live. When your plan has a model-scoped limit, a dedicated bar (Usage Dashboard) or ring (widget) appears next to Session and Weekly, with its own percentage and reset time. It only shows up when your subscription actually has such a limit, so nothing changes if it doesn't.
- The reading is generic: if Anthropic later scopes limits to other models too, they'll appear automatically — no update needed.
- CCSwitcher now reads limits from the newer structured `limits` feed of the usage API, which is more forward-compatible than the older per-model fields.

#### Also in this release

- **Hardened account credentials against a token/identity desync** that could momentarily attach one account's token to another account's slot. Backups are now guarded so an account can never be saved under the wrong identity.

**Full Changelog**: https://github.com/vientooscuro/CCSwitcher/compare/v1.11.4...v1.12.0

---

### 按模型的额度：单独显示 Fable 5

- **订阅现在可以包含针对 Fable 5 的单独周额度**，CCSwitcher 会在其他额度所在的位置一并显示它。当你的套餐带有按模型划分的额度时，会在 Session 与 Weekly 旁边出现一条专属进度条（用量面板）或圆环（小组件），并带有各自的百分比与重置时间。只有当你的订阅确实存在该额度时才会显示，否则界面保持不变。
- 读取方式是通用的：如果 Anthropic 之后也为其他模型划分额度，它们会自动出现，无需更新。
- CCSwitcher 现在从用量 API 更新的结构化 `limits` 数据读取额度，比旧的按模型字段更具前向兼容性。

#### 本次发布还包含

- **加固了账号凭证，防止令牌/身份错位**——此前可能会短暂地把一个账号的令牌挂到另一个账号的槽位上。现在备份已加防护，账号绝不会被保存到错误的身份之下。

**Full Changelog**: https://github.com/vientooscuro/CCSwitcher/compare/v1.11.4...v1.12.0
