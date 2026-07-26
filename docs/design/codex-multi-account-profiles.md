# Codex multi-account profiles

Companion to `claude-code-multi-account-profiles.md`. Codex follows the same
product shape and the same Garyx-owned managed-directory pattern; this document
specifies only the contract, and calls out where Codex deliberately diverges
from the Claude implementation and why.

## Goal

Garyx Mac and iOS can keep several Codex (ChatGPT) logins, show the active
account and its Session / Weekly quota on the Providers page, and switch the
account used by future Codex processes.

The system Codex profile remains a first-class, undeletable account. It uses
Codex's ordinary default home (`~/.codex`, or the Gateway's ambient
`CODEX_HOME`) and Garyx does not inject `CODEX_HOME` for it. Managed accounts
live in isolated Garyx-owned home directories.

## Product contract

- The Providers page grammar is unchanged from the Claude design: flat expanded
  native sections, monochrome linear meters, shared provider avatar artwork.
- The Codex section gains the same account surface Claude Code has: one
  current-account row, Switch / Add actions, per-account quota in the switcher,
  and provider-level add / rename / reauthenticate / switch / delete actions.
  The repo rule "Claude Code alone inserts the account-selection row" is
  amended to "Claude Code and Codex insert the account-selection row"
  (`AGENTS.md`, `CLAUDE.md`, `docs/agents/mobile-ui.md` in the same commit).
- Managed Codex accounts are ChatGPT accounts. API-key auth stays out of scope
  for managed accounts; users who need API-key Codex keep configuring agent
  `env` as today under System default.
- Login is the device-code flow. Garyx shows the verification URL and the user
  code; the user authorizes from any browser on any device. There is no code
  paste-back into Garyx (unlike Claude), so the login dialog/sheet is a
  display-and-wait surface with cancel.
- The system-default account can be reauthenticated but cannot be renamed or
  deleted.
- Deleting the active managed account switches Codex back to System default
  atomically before removing the directory.
- iOS mirrors the Claude account manager structure: current-account row on the
  Provider screen, native sheet account list with per-account quota, account
  detail page owning switch/rename/reauth/delete.

## Configuration model

Account selection belongs to the provider, not to an agent or thread:

```yaml
provider_accounts:
  codex:
    active_account_id: null        # null selects System default (~/.codex)
    accounts:
      - id: 6f6f1d2e-…             # UUID, mints the directory name
        name: Work
        email: user@example.com
        plan: pro                  # chatgpt_plan_type from the id_token
        chatgpt_account_id: 0b9e…  # identity anchor from the id_token/tokens
        created_at: 2026-07-26T12:00:00Z
        updated_at: 2026-07-26T12:00:00Z
```

Managed root:

```text
<garyx-config-parent>/provider-accounts/codex/<account-id>/
```

Production resolves to `~/.garyx/provider-accounts/codex/<account-id>/`. The
ownership marker is `.garyx-codex-account`, content `<account-id>\n`. The same
six delete-safety checks as Claude apply (config membership, exact root/id
shape, no symlink anywhere in the *ownership chain* — root components,
candidate, marker —, canonical containment under the config parent, direct
child of the canonical root, marker content match). Shared-resource symlinks
*inside* the account directory (next section) are expected and are not
ownership-chain members. All config writes go through the serialized
`mutate_config` transaction.

Account IDs are UUIDs (`Uuid::new_v4`), directory names derive from the ID,
and no filesystem path is ever accepted from a client or serialized into
thread metadata.

## Managed home layout and credential custody

A managed account directory is a real `CODEX_HOME`. Codex requires the
directory to pre-exist; Garyx creates it when reserving the account.

Owned per account (written by the Codex CLI, never by Garyx):

- `auth.json` — the only credential. Codex writes it at login and refreshes it
  in place during runs. **Garyx never writes, copies, or merges Codex
  credentials.** Because every account runs in its own home, tokens refresh in
  the right place by construction and no read-back/reconcile machinery exists
  (this is the deliberate divergence from Orca's shared-runtime-home design).
  Garyx only reads `auth.json` to decode the `id_token` JWT payload (no
  signature verification) for identity display: `email`,
  `https://api.openai.com/auth` → `chatgpt_plan_type`, `chatgpt_account_id`.
- Codex-internal state the CLI creates on demand (`log/`, sqlite state, etc.).

Shared with the user's `~/.codex` via symlinks created at account reservation
and re-asserted (repair-if-missing) whenever the Gateway applies a selection:

- `config.toml` — one config universe; user MCP servers, marketplaces, and
  trust levels apply to every account live.
- `skills`, `plugins`, `rules`, `memories`, `mcp.json` — capability surfaces
  a Codex run must not lose when running under a managed account.
- `sessions`, `archived_sessions` — one rollout store, so Codex-native thread
  resume keeps working across account switches (next section).

Repair never destroys data: a missing entry is re-linked; an entry that has
become a real file/directory (e.g. Codex atomically rewrote `config.toml`
through the symlink) is left in place and logged as drift. Symlink targets
that don't exist yet in `~/.codex` are skipped until they appear.

If Codex is ever configured with `auth_credentials_store_mode = keyring`, the
file contract breaks; login commit requires `auth.json` to exist in the
managed home and fails with a clear error otherwise.

## Gateway API

All routes use the existing Gateway authentication.

### Accounts

- `GET  /api/providers/codex/accounts` — System default first plus managed
  accounts, selected state, identity metadata, per-account quota fetched
  concurrently; a quota failure is isolated to its account.
- `PUT  /api/providers/codex/accounts/active` — body
  `{ "account_id": string | null }`; validates the managed directory before
  committing.
- `PATCH /api/providers/codex/accounts/{account_id}` — `{ "name": string }`,
  managed accounts only.
- `DELETE /api/providers/codex/accounts/{account_id}` — managed only; config
  state is removed first (active selection resets to System default), then the
  usage cache entry is invalidated and the verified owned directory removed.
  Codex has no Keychain item to clean.

### Login (device-code)

- `POST   /api/providers/codex/auth/start`
- `GET    /api/providers/codex/auth/{login_id}`
- `DELETE /api/providers/codex/auth/{login_id}`

There is no submit endpoint: the device flow takes no input through Garyx.

Start body carries the same target shape as Claude:

```json
{ "managed_account_name": "Work", "account_id": null }
```

- neither field: authenticate System default (no `CODEX_HOME` override);
- `managed_account_name`: reserve a new UUID + owned directory (marker +
  shared symlinks) and authenticate there;
- both fields: `400 ambiguous_auth_target`.

The session spawns `codex login --device-auth` with `CODEX_HOME` set for
managed targets (per-process env only; the Gateway environment is never
mutated). Device auth binds no local port, so concurrent logins to different
accounts cannot conflict (the browser-callback flow would collide on its fixed
localhost port — a second reason device auth is the only mode).

State machine: `Starting → WaitingForAuthorization → Succeeded | Failed`.
Stdout is parsed tolerantly for the verification URL and user code; start
waits up to 30s for them and returns
`{ login_id, account_id?, status, url, user_code }`. The overall session times
out at 15 minutes (device-code lifetime). Only exit code 0 with a readable
`auth.json` in the target home finalizes; identity is then decoded from the
`id_token` and committed inside `mutate_config`. Adding an account never
changes the active selection. Cancel (DELETE) and every terminal failure kill
the child and clean an uncommitted reserved directory after ownership
validation.

Login resolves the same default `codex` binary the bridge uses; per-agent
`codex_bin` overrides do not affect provider-level account login.

## Codex process runtime

`CODEX_HOME` is a launch-time provider setting, exactly like
`CLAUDE_CONFIG_DIR`:

- The bridge gains `set_codex_home(Option<String>)`; the Gateway applies the
  validated selection at startup and on every hot reload, with the same
  fail-closed quarantine: an unknown/stale `active_account_id` resolves to a
  nonexistent `<config-parent>/.invalid-codex-account-selection` path (Codex
  refuses a nonexistent `CODEX_HOME`, so launches fail credential-free rather
  than silently using System default).
- In provider assembly, account selection owns the identity env keys: Garyx
  removes agent/thread-era `CODEX_HOME` values, then injects the selection for
  managed accounts. When a managed account is active, the auth override
  variables `OPENAI_API_KEY`, `CODEX_API_KEY`, and `CODEX_ACCESS_TOKEN` are
  also stripped from the Codex process env — otherwise they silently outrank
  `auth.json` and make the selection a no-op. System default leaves the env
  untouched, preserving today's API-key workflows.
- The Codex provider implements `update_launch_environment` (currently the
  no-op trait default): launch env moves from frozen construction state into
  hot-applied provider state, mirroring the Claude provider.
- Snapshot semantics come from the existing per-thread app-server slots:
  `decide_codex_client_reuse` already keeps a busy slot untouched and restarts
  an idle slot whose startup env changed. A running turn therefore keeps its
  account; the next run on the thread observes the new selection.
- Threads store provider/session metadata only; no account ID or home path is
  snapshotted into thread metadata or admission state.

## Session continuity

Codex-native thread resume reads rollout files under `$CODEX_HOME/sessions`.
With `sessions` symlinked to `~/.codex/sessions` in every managed home, all
accounts and the user's terminal Codex share one rollout store, so
`thread/resume` finds the rollout regardless of which account created it — no
per-account mirror/reconcile layer (Claude needed one because
`CLAUDE_CONFIG_DIR` forks the whole session tree).

Implementation gate: verify empirically that `thread/resume` succeeds from a
home whose `sessions` is a shared symlink while per-home sqlite state differs
(start a thread under account A, switch, resume under B). If resume turns out
to require per-home index state, v1 ships without the sessions symlink,
relying on the existing `codex resume failed → start new thread` fallback
(Garyx transcript state preserves conversation context), and the shared-store
approach is recorded as debt.

Gate result (2026-07-26, codex-cli 0.144.0): **PASS** — a thread started by an
app-server under home A (one real turn, rollout persisted through the shared
`sessions` symlink) resumed successfully from an app-server under home B with
fresh per-home sqlite state, including history preview.

## Quota

Per-account usage extends the existing Codex usage path
(`chatgpt.com/backend-api/wham/usage`) with a home-directory parameter and a
per-account cache identity (`codex:<account-uuid>` / `codex:system`), 60s
fresh TTL, single-flight, mirroring Claude.

Token custody stays with Codex: the Gateway never refreshes Codex OAuth
tokens.

1. Read `auth.json` from the account home; if the access token is unexpired
   (local `exp` check), call the usage API directly with
   `Bearer <access_token>` + `ChatGPT-Account-Id` as today.
2. If the token is expired or the API returns 401, fall back to a short-lived
   `codex app-server` JSON-RPC call (`account/rateLimits/read`, added to
   `codex-sdk`) with `CODEX_HOME` pointing at the account home. Codex performs
   its own refresh and persists rotated tokens correctly in that home as a
   side effect.
3. If both fail, the account row shows the inline unavailable state and stays
   selectable.

`/api/usage/coding` keeps reporting the active account, with the cache
identity derived from `active_account_id`.

## Quota recovery wake

Account switch reuses the durable quota-recovery wake verbatim: the detached
switch-effects task calls the existing provider-keyed expedite with the
provider string Codex recovery rows actually carry (`codex_app_server`),
`account_switch` wake reason, same
respond-fast-then-repair ordering, and the same no-op rule when the selected
account did not change. No Codex session sweep step exists (nothing to
reconcile under the shared rollout store).

## Desktop structure

The Providers page already renders the account row pattern for Claude. Codex
reuses the same `provider-account-row` presentation and switcher dialog
structure with Codex-typed IPC (`listCodexAccounts`, `selectCodexAccount`,
`renameCodexAccount`, `deleteCodexAccount`, `startCodexAuth`, `getCodexAuth`,
`cancelCodexAuth`) — shared presentation, provider-specific wire types,
consistent with the shared-presentation-helper rule rather than a premature
generic abstraction. The login dialog shows the verification URL (opened
externally once per `login_id`, HTTP(S)-validated) and the user code with a
copy affordance, then polls the auth session until terminal; there is no code
input step.

## iOS structure

Core (`GaryxMobileCore`) gains Codex account wire models, target encoding,
presentation, and gateway client methods mirroring the Claude set; SwiftUI
gains the Codex current-account row (`supportsAccountSelection` extends to
`.codex`), the account sheet/detail reusing the Claude management structure,
and a device-code login sheet: verification URL open-in-browser, user code
display with copy, live status polling, cancel-on-dismiss calling DELETE.
No paste-code step. All business rules live in Core with SwiftPM tests.

## Failure behavior

- Unknown/stale selected account: quarantined launches (nonexistent
  `CODEX_HOME`), no selected account in the list response, explicit
  re-selection repairs config.
- Device-auth output unparseable / login child exits nonzero / `auth.json`
  missing after exit 0: terminal failure with captured output (tail-capped),
  reserved directory cleaned up.
- Account quota unavailable: inline unavailable state, account stays
  selectable.
- Shared-symlink drift (entry replaced by a real file): logged, never
  destructively repaired.
- Runtime config reload failure: `mutate_config` restores the previous config
  and selection, and the bridge's previous Codex home is restored before
  re-apply (same recovery shape as Claude).
- Managed directory cleanup failure: never recurse outside the verified root;
  report retained data.

## Non-goals and recorded debt

- Account-scoped model catalog: `fetch_app_server_models` stays account-blind,
  same recorded debt as `claude-catalog-floor-and-account-scope.md`; runtime
  pickers already survive catalog degradation.
- API-key managed accounts, workspace/org switching within one login, and a
  CLI management surface (Claude has none either).
- Proactive Gateway-side token refresh (custody stays with the Codex CLI).

## Verification

1. Config model serialization/back-compat tests (`provider_accounts.codex`
   omitted ⇒ System default).
2. Ownership/marker/symlink-attack deletion tests for the Codex managed root;
   shared-symlink reservation and repair tests.
3. Auth API tests with a fake `codex` binary: device-auth output parsing,
   system-default vs managed targeting, ambiguous target, cancel kills the
   child and cleans the reserved dir, exit-0-without-auth.json fails, identity
   decode from a fixture `id_token`.
4. Usage tests: per-account cache identity isolation, expired-token fallback
   ordering, unavailable degradation.
5. Bridge tests: `update_launch_environment` hot-apply, busy-slot snapshot vs
   idle-slot restart on `CODEX_HOME` change, env-key ownership stripping
   (managed) vs untouched env (System default), no account data in thread
   metadata.
6. Quota-recovery wake test with provider string `codex_app_server` and
   selection-unchanged no-op.
7. Empirical session-continuity gate: real `codex` thread started under
   account A resumes under account B through the shared sessions symlink.
8. Desktop typecheck/unit + packaged-app check of the Codex account row,
   switcher, and device-code login dialog; iOS SwiftPM tests plus simulator
   pass (light mode, iPhone 17 Pro Max / iOS 26.5) and `xcodebuild`.
9. End-to-end on a scratch gateway: add two real accounts, switch, run a
   thread under each, verify quota rows and `wham/usage` identity separation.
