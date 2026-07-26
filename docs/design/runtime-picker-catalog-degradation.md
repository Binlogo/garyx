# Runtime Pickers Must Survive Provider-Catalog Degradation

## Problem

The iOS thread settings panel stopped showing the `Thinking level` row on every
thread, and the `Model` row showed the raw id `claude-opus-5` instead of the
catalog label `Claude Opus 5`.

Observed state at diagnosis time (all measured, not inferred):

- Anthropic `/v1/models` upstream: healthy — `claude-opus-5` plus
  `low/medium/high/xhigh/max`, identical across all three managed Claude
  accounts.
- Local gateway `/api/provider-models/claude_code`: healthy —
  `supports_reasoning_effort_selection: true`, 11 models.
- The affected thread's own server state: healthy —
  `thread_runtime.model_reasoning_effort_override = "max"`.
- The iOS client: holding an older provider catalog that advertised neither
  `claude-opus-5` nor any effort metadata.

So the thread genuinely runs at `max`, the server knows it, and the client
deleted the control that displays and changes it.

## Root Cause

Two independent defects compose into the observed failure. Both exist on iOS
and on the Mac app.

### 1. Control existence is derived from catalog metadata

`GaryxThreadModelOverridePresentation.pickerOptions` returns no rows at all
when the catalog advertises nothing:

```swift
guard !advertisedOptions.isEmpty else { return [] }
```

The thread's own effective value is only appended *after* that guard, so a
catalog with no effort metadata erases the value's row too. The panel's
`canSelectReasoningEffort` is `!reasoningEffortOptions.isEmpty`, so the whole
row disappears.

Desktop has the same class of defect one layer up:
`resolveComposerModelControlState` already unions the effective value into
`reasoningEfforts`, but `ComposerForm.tsx` re-gates on the raw capability flag
(`Boolean(providerModels.supportsReasoningEffortSelection) && …`), so a
capability-poor catalog still hides a control whose value is present.

### 2. A degraded catalog is treated as authoritative for sanitizing

`sanitizedReasoningEffort` / `sanitizedServiceTier` answer "is this value
supported?" by membership in the catalog list. An empty list therefore reads as
"unsupported", and `modelSelectionUpdate` writes `""` for that cell. Picking any
model while the catalog is degraded **erases the user's pinned thinking level**.
Desktop's `selectModelSanitizingTier` has the same shape for service tier.

This is worse than the reported symptom: degradation is not only hiding state,
it can destroy it.

### 3. A degraded snapshot is pinned for the whole app session

Both clients fetch a provider catalog once and never refresh it:

- iOS: every call site guards `providerModelsByType[providerType] == nil` —
  including `refreshProviderModelsForVisibleAgents`, whose name promises the
  opposite. The dictionary is only cleared on gateway switch / logout.
- Desktop: `AgentsHubPanel.tsx` returns early when
  `providerModelsByType[providerType]` is present; `AppShell` holds the same
  fetch-once state.

So a single degraded fetch — one upstream blip, one older gateway, one
capability-poor payload — is pinned until the app is killed. That is why the row
was missing on *every* thread and stayed missing for days.

## Contract

The thread runtime snapshot is the truth for what a thread runs with. The
provider catalog is a choice list and a label source, nothing more.

`thread_runtime.model`, `thread_runtime.model_reasoning_effort`, and
`thread_runtime.model_service_tier` are server-resolved thread state
(`docs/design/thread-runtime-model-snapshot.md`). A provider catalog that fails
to advertise a capability may shrink the list of *other* choices. It must never:

1. hide a control whose value the thread actually carries,
2. change or hide that value, or
3. cause that value to be cleared.

Stated as one rule: **catalog metadata is authoritative about what else you may
pick, never about what you already have.**

Corollary for freshness: a catalog snapshot is a cache, not a decision. Clients
serve the last good snapshot and keep refreshing it; a failed refresh keeps the
previous snapshot and never degrades it.

## Changes

### A. iOS Core — `GaryxThreadModelOverridePresentation`

**A1. `pickerOptions` — the current value is a row in its own right.**
Rows exist when at least one advertised option survives normalization **or**
`current` is a non-empty value. With an empty catalog and `current = "max"`, the
picker is `[follow-default, max]`: the user can see what is pinned and can unpin
it. With an empty catalog and no current value (a provider that genuinely has no
thinking levels) the picker stays empty and the row stays hidden — this
distinction is the point and must be covered by tests both ways.

**A2. Sanitizing requires an authoritative list.**
`sanitizedReasoningEffort` / `sanitizedServiceTier` may only drop a value when
the advertised list is non-empty. An empty list means "the catalog does not
know", not "unsupported", and the existing cell is preserved. This removes the
data-loss path in `modelSelectionUpdate`.

**A3. Labels.** `modelLabel` / `reasoningEffortLabel` already fall back to the
raw id when the catalog lacks the entry. Unchanged — the raw id is the honest
render of a value the catalog cannot name, and it self-heals once the catalog
refreshes.

### B. iOS panel — `GaryxMobileThreadRuntimeSettingsViews`

`canSelectReasoningEffort` / `canSelectServiceTier` / `canSelectModel` already
derive from the resolved option lists and become correct through A1; verify each
one rather than assuming. The Speed row must stay hidden for a provider with no
tiers and no effective tier (Claude today), and the Model row must keep showing
its value even when nothing can be picked.

### C. Desktop — `ComposerForm.tsx` / `composer-model-control.ts`

**C1.** Derive `supportsReasoning` / `supportsServiceTier` from the resolved
lists that already union the effective value, not from the raw capability flags.
Before doing so, check every branch of `garyx-gateway/src/provider_models.rs`
for a provider that ships a non-empty `reasoning_efforts` / `service_tiers` list
while reporting its capability flag `false`; if such a branch exists, keep the
flag as a gate for the *catalog-derived* rows only and never for the effective
value's row.

**C2.** Apply A2 to `selectModelSanitizingTier`: only clear a tier against a
non-empty target list.

### D. Catalog freshness — both clients

Replace fetch-once with stale-while-refresh, matching the gateway-scoped
caching contract mobile already uses for other low-frequency catalogs:

- Serve the existing snapshot immediately; never blank the UI to refresh.
- Refresh on the triggers that already exist (thread settings panel open, agent
  list refresh, provider settings open, foreground sync) instead of skipping
  when a value is present.
- De-duplicate concurrent in-flight fetches per provider type.
- A failed refresh keeps the previous snapshot untouched and must not raise a
  user-facing error banner for a background refresh (today's `catch` writes
  `lastError`, which would surface a toast on every transient refresh).
- Keep the existing gateway-generation / scoped-request guards; a response from
  a superseded gateway scope is still discarded.

### E. Out of scope — recorded as debt

Both belong to the gateway and are real, but neither is on this change's path;
they go to `docs/design/runtime-picker-catalog-degradation-debt.md` as their own
tasks:

1. **The catalog has no capability floor.** `provider_models.rs` derives
   `supports_reasoning_effort_selection` purely from a live upstream payload. A
   successful-but-capability-poor `/v1/models` response silently reports `false`
   to every client. Only an empty list or a transport error falls back to the
   builtin catalog.
2. **The Claude catalog is not account-scoped.** `fetch_claude_code_models`
   calls `read_oauth_token()` with no config dir, i.e. the default keychain
   entry, while runs use the selected managed account. The advertised catalog can
   therefore belong to a different account than the one that actually runs.

The pre-existing debt item "choosing a model can silently clear thinking level
and speed" (`docs/design/thread-runtime-picker-review-debt.md` §2) is *not*
resolved here. A2 only stops clearing caused by a degraded catalog; the product
question about surfacing a legitimate sanitize stays open.

## Test Plan

Headless first. No UI test may stand in for these.

### RED reproduction (must fail before the fix)

Use a real captured degraded catalog fixture: models present, every
`supported_reasoning_efforts` empty, `supports_reasoning_effort_selection`
false, `claude-opus-5` absent.

1. **Core / row erased.** `reasoningEffortPickerOptions(providerModels:
   degraded, model: "claude-opus-5", effectiveReasoningEffort: "max")` returns
   `[]` today; must return a follow-default row plus a `max` row.
2. **Core / nil catalog.** Same with `providerModels: nil` and an effective
   `max`.
3. **Core / value destroyed.** `modelSelectionUpdate` against the degraded
   catalog with `reasoningEffortCell: "max"` emits `reasoningEffort: ""` today;
   must leave the cell untouched (`nil`).
4. **Desktop / control hidden.** Capability flag `false` with an effective
   `max` hides the thinking control today; must render it.

### Regression / negative controls

- Provider with no efforts **and** no effective effort → row still hidden
  (proves the fix did not just always-show the row).
- Healthy catalog → unchanged option list, labels, checkmarks, ordering.
- Sanitizing against a healthy catalog still drops a genuinely unsupported
  value (A2 must not disable legitimate sanitizing).
- Service tier keeps the same matrix on both ends.

### Freshness

- A refresh that fails keeps the previous snapshot and raises no user-facing
  error.
- A refresh that succeeds replaces the snapshot and the row/labels recover
  without an app restart.
- Concurrent triggers for the same provider type produce one in-flight fetch.
- Gateway switch still clears the cache.

### Validation

```bash
cd mobile/garyx-mobile && swift test                     # GaryxMobileCore
xcodebuild -scheme GaryxMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' build
cd desktop/garyx-desktop && npm run test && npm run build:ui
cargo test -p garyx-gateway --lib provider_models        # only if gateway files change
```

End to end, against the live gateway (healthy catalog): the panel shows
`Thinking level · Max` and `Model · Claude Opus 5`, and picking a model leaves
the pinned level intact.
