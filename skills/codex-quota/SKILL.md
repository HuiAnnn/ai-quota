---
name: codex-quota
description: Use when the user asks to install or open the AI 额度 native macOS companion, or check local Codex, Grok Bot, Manus, Cue or Muse quota and reset times. Applies to this companion and its quota-file extensions on a local Mac.
---

# AI 额度

The companion plugin ships Swift source in `assets/native`. It requires a local Mac with macOS 13+, Xcode Command Line Tools and Python 3. Display name is AI 额度; plugin slug `codex-quota`, executable `CodexQuota`, bundle ID and `~/Applications/Codex额度.app` remain compatible. It is an independent tool, not an official OpenAI product.

Resolve the helper as `scripts/quota.sh` relative to this skill directory, then quote its absolute path.

`query` and `query-all` prefer the installed `~/Applications/Codex额度.app` when its version and signature are valid, before checking build tools or using a cache. This reuses the fixed installation path for local login access. If there is no valid installed app, queries retain the cached build fallback.

| Request | Helper action |
| --- | --- |
| Check prerequisites | `check` |
| Initialize once or verify the fixed local signing identity | `signing-setup` |
| Read Codex quota only, preserving the original JSON format | `query` |
| Read all five built-in sources and their connection/error states | `query-all` |
| Compile source and return the cached app path | `build` |
| Install the requested companion | `install` |
| Open the installed companion | `open` |

`query-all` invokes `--diagnose-all`; failures remain specific to each source. Missing values are unknown, not zero. Explain dates in Beijing time. Diagnostics output only quota fields and safe states, never account identities or credentials. Do not claim a source is connected from a fixture test or assume all five live integrations have passed. Verify live connectivity on the current Mac with `query-all`; services requiring authentication must complete their own login and quota check.

Codex reuses its app or CLI login. Grok Bot, Manus and Cue reuse their own local sessions; background Keychain reads never prompt. Open AI 额度, select the application icon, then use its action bar or connection details. The detail's「授权」「登录」or「重试」button matches the problem: authorize the matching Keychain item for access errors, log in for missing authentication, and retry temporary query failures. Muse uses this tool's own WebKit login at `https://muse.ai`; it does not read Meta's private Keychain group. Its「验证登录并读取额度」button closes the window only after both login validation and a real quota query succeed. Failure keeps the window open with a safe reason; Muse authentication must be verified on the current Mac. Never print, upload or ask the user to paste auth files, cookies or tokens. Queries and automatic refresh do not submit AI conversations or call an AI model.

Builds reuse the fixed signing certificate in this Mac's login Keychain. Run `signing-setup` once before the first build; subsequent setup calls verify and reuse it. Builds stop if the original signing identity is missing or invalid. They never generate a replacement automatically or fall back to ad-hoc signing. Preserve the signing records in `~/Library/Application Support/CodexQuota/Signing` and the original Keychain certificate and private key. Migrating from the old ad-hoc app may require one explicit authorization per local login item; background reads still never prompt. No paid developer membership is required.

Installation preserves the existing app path and does not enable launch at login. The helper never replaces an existing app or a running process. If the user requests an upgrade and the helper reports an existing installation, prepare and verify a new build, preserve the old bundle and pending reset journal, then carry out the authorized upgrade separately. Do not reinstall merely to answer a quota question.

The menu bar starts with Codex as default and shows one remaining percentage; users can change and save the default. The panel arranges 44 pt local application icons horizontally, with a remaining percentage and compact Beijing reset time beneath each icon. Additional applications remain reachable by horizontal scrolling. Clicking an icon selects its detail view without changing the default. Overview application names and per-icon more-options controls are removed; names remain available through hover and accessibility, and the selected detail header names that application. An action bar beneath the icons acts only on the selected application: set the menu-bar default, open its app, connect its login, or remove a local extension. Switching applications starts details at the top. A warning beside a percentage marks the last successful data as stale; details explain the connection error. Refresh shows progress and prevents repeated refresh clicks. Recovery actions share「授权」「登录」「重试」labels and stay disabled while connecting. Missing reset times stay unknown; the most recent sync time lives in a tooltip or details. Multiple primary cycles identify the selected cycle in details; Manus daily/weekly reset times are separate from its monthly pool. The independent top forecast strip is removed. Forecasts and reset history remain in the collapsed Codex detail section; expand it for announcements and timing. Periodic percentages and extra balances remain separate. Balance totals use「总额度」; periodic limits use「周期总量」. Each source refreshes independently with backoff; account changes or lost identity clear old snapshots.

「添加应用」imports a local quota-only JSON file. Read `assets/native/docs/quota-provider-extension.md` for its schema and `assets/native/examples/quota-provider.json` for an example. `observedAt` is required; the app rereads the file every minute and does not execute scripts. Never place credentials in an extension file. Press Escape to close the Add Application window.

Codex manual reset stays in the native panel. Clicking「重置」immediately consumes that opportunity without another confirmation. The helper has no reset action. Never use a reset while querying, installing, previewing or testing. For an explicitly requested reset, open the panel and use the chosen opportunity; uncertain results must reuse the saved request key. Do not delete `pending-reset.json` or switch opportunities to bypass a pending operation. `swift test --package-path assets/native` uses fixtures and does not establish that a real reset succeeded.
