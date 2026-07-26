# Claude Catalog: Capability Floor And Account Scope

Resolves the two gateway items recorded in
`docs/design/runtime-picker-catalog-degradation.md` §E. The client-side work in
that design (rows survive degradation, sanitize requires authority, catalogs
refresh) ships separately; this design makes the gateway stop *producing*
degraded catalogs in the first place, and makes the catalog belong to the
account that actually runs.

## Problem

### 1. No capability floor

`list_provider_models`'s Claude branch derives
`supports_reasoning_effort_selection` and every model's
`supported_reasoning_efforts` purely from one live `/v1/models` payload. The
degradation machinery (`discover_or_fallback` → stale cache → builtin catalog)
only engages on transport errors or an empty model list. An HTTP-200 payload
whose entries simply *lack* `capabilities.effort` parses as "no model supports
effort" and is **stored in the cache as a success**, then served to every
client as `supports_reasoning_effort_selection: false` with no `error` field.

That conflates two different upstream statements:

- `capabilities.effort.supported = false` — an explicit, per-model statement.
  Honoring it is correct (today's `claude-haiku-4-5` etc. do exactly this).
- `capabilities.effort` absent — the payload does not speak the capabilities
  dialect at all (older proxy, schema change, filtered response). Reading this
  as "withdrawn" invents a fact.

### 2. The catalog is not account-scoped

`fetch_claude_code_models` calls `read_oauth_token()` with no config dir — the
system default credential chain (`Claude Code-credentials` keychain entry /
`~/.claude/.credentials.json` / env) — while runs execute under the *selected
managed account* (`provider_accounts.claude_code.active_account_id`, resolved
through `validated_active_claude_config_dir`). The advertised catalog can
therefore belong to a different account than the one that runs, and the single
process-wide cache key `"claude_code"` pins whichever account fetched first
even across account switches.

## Contract

1. **A successful catalog fetch must prove it speaks the capabilities
   dialect.** A payload with at least one model but zero
   `capabilities.effort` objects anywhere is a failed discovery — handled by
   the exact same machinery as a transport error (serve last-good stale entry,
   else builtin catalog, with a distinct `error` string). Per-model *explicit*
   `supported: false` inside an effort-aware payload stays honored.
2. **The Claude catalog belongs to the selected account.** The fetch uses the
   active managed account's credential locations only — never a cross-account
   or default-chain fallback when a managed account is selected. System
   default (no managed selection) keeps today's default chain. Cache entries
   are keyed per account, so an account switch serves that account's catalog
   and one account's degradation never poisons another's.

## Changes

All in `garyx-gateway`.

### A. Capability floor (`provider_models/claude_code.rs`)

- `parse_claude_code_models_response` additionally reports whether any entry
  carried a `capabilities.effort` object (an *effort-aware* payload). Shape is
  the implementer's choice (marker enum or field on the discovery), but the
  classification is payload-level, not per-model.
- `fetch_claude_code_models_from_endpoint` converts a non-empty but
  effort-blind payload into `Err` with a distinct message (e.g. "Claude model
  catalog response carried no effort capability metadata"), so
  `discover_or_fallback` routes it through `stale_or_fallback`: last-good
  cached discovery wins (the cache read there deliberately ignores TTL), else
  `claude_code_builtin_models`, with the error annotated on the response.
  An effort-blind payload must never be stored in the discovery cache.
- An empty-model payload keeps its existing "returned no models" path.

### B. Builtin fallback catalog refresh (`provider_models/catalog.rs`)

The floor routes degraded fetches to `claude_code_models()`, which still tops
out at `claude-fable-5` (a floor is only as good as its content: today's
fallback lacks `claude-opus-5` / `claude-sonnet-5`, so a degraded client would
keep rendering raw ids for the models actually in use). Refresh the list to
the current public catalog measured from `/v1/models` in the parent design's
diagnosis: `claude-opus-5`, `claude-sonnet-5`, `claude-fable-5` (five efforts
`low/medium/high/xhigh/max` each), then the 4.x family with their measured
effort sets (`opus-4-8` / `opus-4-7`: five; `sonnet-4-6` / `opus-4-6`: four
with no `xhigh`; `opus-4-5`: `low/medium/high`; `haiku-4-5` / `sonnet-4-5` /
`opus-4-1`: none). Keep the existing recommended/default markers' style. This
list is fallback-only display data; it advertises choices, it does not gate
what a thread may pin.

### C. Account scope (`provider_models.rs`, `routes/custom_agents.rs`)

- The Claude branch of `list_provider_models` takes an explicit catalog scope
  resolved by the caller that owns `AppState` — a small struct carrying the
  active account id and its validated config dir, e.g.
  `ClaudeCatalogScope { account_id: Option<String>, config_dir: Option<PathBuf> }`.
  `provider_models` stays decoupled from `AppState`; the route handler
  resolves the scope via the existing
  `provider_accounts::validated_active_claude_config_dir(state, config)` —
  including its quarantine semantics: an invalid selection yields the
  credential-less quarantine dir, whose failed read degrades honestly to
  stale/builtin instead of silently borrowing the system profile.
- `fetch_claude_code_models` reads credentials for the scoped dir via the
  existing `read_stored_oauth_token_and_subscription_for_config_dir`
  machinery (keychain service hashed per config dir, file fallback inside the
  same dir). With a managed scope there is no env-token and no default-chain
  fallback; a failed read is a failed discovery for that account. The
  `None` scope keeps today's default chain including the env fallback.
- Non-Claude providers are untouched; their branches ignore the scope.

### D. Per-account cache key (`provider_models/cache.rs`)

The discovery cache key becomes `String`. Claude uses
`claude_code:<account_id>` / `claude_code:system`; `codex_app_server`,
`traex`, and `grok_acp` keep their names as owned strings. Stale reuse,
TTL, and store semantics are unchanged — only the identity is finer. The
map is process-local and bounded by account count; no eviction needed.

## Non-Goals

- No change to run-time account selection, session reconciliation, or quota
  machinery.
- No client changes; clients keep rendering what the gateway serves.
- No per-model merge heuristics between upstream and builtin catalogs: inside
  an effort-aware payload, upstream is authoritative per model.
- The parent design's client work and its remaining debt items stay where
  they are. This task must not edit
  `runtime-picker-catalog-degradation-debt.md` (owned by the parallel task's
  flow); the orchestrator reconciles the ledger at merge time.

## Test Plan

RED first; all headless (`cargo test -p garyx-gateway --lib provider_models`
plus the touched `provider_accounts` tests). Fixtures use the real measured
payload shapes with synthetic ids where the id doesn't matter.

### RED (must fail before the fix)

1. **Effort-blind payload is cached as authoritative.** Feed the fetch path a
   200 payload with models but zero `capabilities.effort` objects: today the
   response reports `source: claude_code_api`,
   `supports_reasoning_effort_selection: false`, no `error`, and the discovery
   lands in the cache. After: response comes from stale/builtin with the
   distinct error, and the cache still holds the previous good entry (assert
   by fetching again with a healthy payload blocked).
2. **Cross-account cache bleed.** Store a discovery under account A's scope,
   request under account B: today one key serves A's catalog to B; after, B
   misses the cache and resolves its own.
3. **Default-chain read under managed scope.** With a managed scope whose
   config dir contains a synthetic credential file, the fetch must use that
   dir's token (mock endpoint asserts the bearer), and must not fall back to
   env/default keychain when that dir's read fails.

### Regression

- Effort-aware payload with explicit `supported: false` models: parsed exactly
  as today (floor does not resurrect efforts upstream explicitly withdrew).
- Transport error / empty-model payload: unchanged stale-then-builtin paths.
- Builtin catalog: ids/labels/effort sets match §B's measured table;
  `common_reasoning_efforts` still derives the provider-level list.
- System-default scope: behavior byte-identical to today for a healthy
  payload (existing tests keep passing).
- Codex/Traex/Grok discovery: untouched paths still cache and serve under
  their renamed-but-equal keys.

### End to end (orchestrator acceptance, live gateway)

Build, install, restart the managed gateway. Then:

- `/api/provider-models/claude` under two different selected accounts returns
  each account's own catalog (switch via the accounts API, not by hand-editing
  config).
- Kill upstream reachability (or point at a mock serving an effort-blind
  payload) and confirm the response degrades to stale/builtin with `error`
  set and `supports_reasoning_effort_selection` still true.

```bash
cargo test -p garyx-gateway --lib provider_models
cargo test -p garyx-gateway --lib provider_accounts
cargo fmt --check
```
