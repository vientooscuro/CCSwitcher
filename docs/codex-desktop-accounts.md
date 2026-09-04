# Codex desktop accounts

CCSwitcher opens an independent Codex desktop profile for each account. It no longer switches Codex by restoring a saved auth.json over the default home.

- The existing default account keeps `~/.codex` and `~/Library/Application Support/Codex` unchanged.
- Additional profiles live in `~/Library/Application Support/CCSwitcher/CodexProfiles/<account UUID>/home` and `desktop`.
- **Open Codex** opens or focuses that account's existing window. Other desktop windows and terminal sessions stay signed in to their own accounts.
- **Login New Account** opens a clean Codex profile. Complete sign-in inside that window and its browser flow. Select the intended second account if the browser offers an existing session.
- Legacy saved accounts require one fresh sign-in in their isolated profile. Old Keychain backups are retained but never restored, since their refresh tokens may have rotated.
- **Re-authenticate** opens the account's own window. Use Codex's sign-out/sign-in controls there if needed; CCSwitcher does not revoke credentials itself.
- **Stop waiting** pauses detection without deleting the profile. Login New Account resumes a pending new account; Open Codex resumes an existing account.
- Removing an account removes its registry row only. Profile data and credentials are retained.

## Terminal use

The default `codex` command continues using the default account. To use an additional account in a new terminal session, set `CODEX_HOME` for that command to the account's `home` directory. Do not copy or symlink auth.json between profiles. A running terminal session cannot safely be switched by replacing its credentials on disk.

## Compatibility and verification

Desktop isolation uses `CODEX_HOME`, `CODEX_ELECTRON_USER_DATA_PATH`, and `--user-data-dir`, verified with the renamed ChatGPT desktop app 26.901.22334 (bundle ID com.openai.codex). The Chromium argument is necessary before Electron startup: without it, the new process exits before creating its profile. The Electron environment setting is internal, so recheck isolation after major updates. The launcher prefers the renamed ChatGPT bundle when both versions remain installed. Instances are identified by their profile's SingletonLock and checked against the Codex bundle identifier before activation. A launch succeeds only after that exact process has an on-screen layer-zero window; a missing process or window reports failure.

Each refresh fetches limits for every registered Codex account using that profile's live credentials, regardless of which account is selected. Snapshots, stale indicators, errors, and HTTP 429 backoff remain scoped to the account UUID; an unavailable profile does not prevent other accounts from updating. A failed request retains that account's last snapshot or loads its own disk cache after relaunch. Refresh never switches accounts, opens windows, writes credentials, or attempts an OAuth refresh grant.

Cost/activity statistics default to all local Codex profiles; the Cost tab can switch to the current account and remembers the selection. Both active and archived sessions are included. Retained profiles still contribute to the all-profiles history even if their account row was removed. Historical logs from before profile isolation stay in the default home; they cannot reliably be reassigned to individual accounts.

Token accounting uses last-request usage and suppresses repeated cumulative snapshots. Fork replay can rewrite timestamps, so requests are deduplicated by session, stable turn identity, cumulative counters and request usage; the earliest available occurrence supplies the day. Independent agents are not merged into a synthetic cumulative curve. Cached input is counted once in the shared display model. Costs are API-equivalent estimates at the loaded pricing table, not subscription charges; missing model prices are explicitly reported. Version 7 invalidates old session aggregates and rebuilds history without modifying source logs. Activity duration/turn counts retain their existing timestamp-based heuristics and are not validated as exact billing metrics.

For a previously verified v6 cache, `node scripts/enrich-codex-cache.mjs /absolute/cache.json` streams only identity/usage records to add stable turn IDs, preserving a backup. Changed or ambiguous files are invalidated for normal parsing. The migration tests run with `node --test scripts/enrich-codex-cache.test.mjs`.

Regression tests cover untouched default credentials, profile permissions, no credential seeding/restoration, stale-auth preservation, launch failure, wrong-account rejection, default reimport, pending-login separation, and scoped caches.
