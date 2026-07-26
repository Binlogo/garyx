# Runtime Picker Catalog Degradation — Follow-up Debt

Adjacent problems found while implementing
`runtime-picker-catalog-degradation.md`. They are outside A–D and must be
handled as independent tasks rather than folded into the client cache and
picker correction.

Items 1 and 2 are RESOLVED by
`docs/design/claude-catalog-floor-and-account-scope.md` (#TASK-2760): an
effort-blind payload is now a failed discovery served from stale/builtin with
an explicit error, and the Claude catalog fetch plus its cache key are scoped
to the selected managed account. Items 3 and 4 remain open.

## 1. Gateway provider discovery has no capability floor — RESOLVED (#TASK-2760)

Source:

- `garyx-gateway/src/provider_models.rs`
- `garyx-gateway/src/provider_models/cache.rs`
- `garyx-gateway/src/provider_models/claude_code.rs`

`supports_reasoning_effort_selection` is derived entirely from the discovered
models' live `supported_reasoning_efforts`. A successful upstream response that
contains models but omits capability metadata therefore becomes an
authoritative-looking `false` response. Only a transport/error path or a wholly
empty discovery falls back to the builtin catalog.

The client work in A–D prevents that response from hiding or clearing a
thread's effective values, but it cannot restore the missing choice list. A
separate gateway design should define a provider-specific capability floor and
the merge rules between builtin knowledge and live discovery.

## 2. Claude Code model discovery is not scoped to the selected managed account — RESOLVED (#TASK-2760)

Source:

- `garyx-gateway/src/provider_models/claude_code.rs`
- `garyx-gateway/src/provider_models.rs`

`fetch_claude_code_models` reads OAuth credentials through
`read_oauth_token()` without a managed-account config directory. Runtime runs,
however, use the currently selected managed Claude account. The catalog and the
run can consequently describe different account scopes.

This needs an account-scoped gateway catalog contract, cache key, invalidation
rule, and tests for account switching. Client stale-while-refresh alone cannot
make a catalog from the wrong account authoritative.

## 3. Desktop has no catalog-free composer presentation

Source:

- `desktop/garyx-desktop/src/renderer/src/ComposerForm.tsx`

The desktop composer returns no model control when it has never received a
provider catalog (`providerModels` is `null`) or when the catalog says model
selection is unsupported. A–D preserve the last successful snapshot and repair
capability-poor snapshots, but a cold-start fetch failure still has no catalog
object from which the current implementation can build the control.

The thread runtime snapshot already contains the effective model, thinking
level, and service tier. A separate cross-platform design should decide how the
desktop composer renders and unpins those values before the first catalog
success, without inventing selectable catalog rows.

## 4. iOS thread detail refresh ignores the server label fallback

Source:

- `mobile/garyx-mobile/Sources/GaryxMobileCore/GaryxGatewayThreadModels.swift`

After a thread runtime write, iOS refreshes the selected thread through the
thread-detail response. That decoder currently reads only `title` and falls
back to `New Thread` when `title` is null, even though the response can carry
the user-visible thread name in `label`. The runtime picker change did not
touch this decoder, but end-to-end verification exposed the existing title
regression.

This needs its own thread-summary decoding contract and parity tests. It must
not be coupled to catalog refresh or runtime-picker presentation.
