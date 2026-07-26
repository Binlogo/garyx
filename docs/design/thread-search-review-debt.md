# Thread Search — Review Debt

Adjacent items found while implementing and reviewing thread search
(`docs/design/thread-search.md` §7 requires them recorded here and filed
separately). Nothing in this file is a defect in the thread-search change path;
each item is pre-existing or neighbouring work that should get its own task.

## Gateway

### G-1 — Existing provider-auth test timing flake

- Source: `garyx-gateway/src/provider_auth.rs:990-1013`
- Observed while running `cargo test -p garyx-gateway --lib`: the managed-auth
  test exhausted its polling window with a `Submitted` snapshot even though the
  child had already reported exit code 0. An immediate exact-test rerun passed.
  Independently reproduced by Gary during acceptance: the full-suite run showed
  1003 passed / 1 failed, and the same test passed alone both on the branch and
  on unmodified `main`.
- Disposition: unrelated to the thread-title search paths and tracked
  separately as `#TASK-2739`; do not change it as part of thread search.

### G-2 — Superseded iOS design still documents the four-field corpus

- Source: `docs/design/ios-thread-list-unification.md:74-112`
- The older design still specifies title/workspace/agent/preview matching and a
  `search_text` projection. `docs/design/thread-search.md` D1 now supersedes
  that contract with title-only `search_title`, leaving the two design documents
  contradictory.
- Disposition: tracked separately as `#TASK-2737`; do not rewrite that feature's
  historical design as part of this backend implementation.

### G-3 — Tier 1 changed-mode reports pass after running zero tests

- Source: `scripts/test/rust_tier1_fast.sh:99-103,151-169`
- `--changed` derives targets only from the dirty tree. After changes are
  committed, a clean worktree selects no packages, skips command execution, and
  still emits `STATUS=pass`, so the report can be mistaken for test evidence.
  Hit again by Gary during acceptance on merged `main`.
- Disposition: tracked separately as `#TASK-2738`. For this implementation, use
  the gateway library suite as the substantive Rust validation and run
  changed-mode before committing.

## iOS

### I-1 — Two mechanisms apply row running state

- `mobile/garyx-mobile/Sources/GaryxMobileCore/GaryxHomeThreadListPresentation.swift`
  — `GaryxHomeThreadListStore.sections(_:runningThreadIds:)` patches running
  state and the running-derived `canArchive` in a second pass *after* the cached
  section build, deliberately so the sections cache key stays independent of
  runtime run state.
- `mobile/garyx-mobile/Sources/GaryxMobileCore/GaryxThreadMembershipProviders.swift:1202`
  — workspace/automation/bot list stores instead pass
  `hasActiveRun: activeRunThreadIds.contains(row.id)` straight into
  `GaryxThreadRowCapabilityDeriver` at build time.

Both reach the same result, so this is not a behaviour bug. It is two ways to
express one rule, and every new thread-list surface has to pick one. Worth
collapsing to a single overlay helper.

### I-2 — Resolved: `GaryxGlassSearchField` automated coverage

`mobile/garyx-mobile/App/GaryxMobile/GaryxMobileStatusComponents.swift:465`.

Resolved in the iOS empty-search glass follow-up: the Home chrome UITest covers
the embedded, externally focused rendering mode, and the automation thread
picker UITest now covers the component's own glass surface through the empty,
non-empty, and cleared query states.

### I-3 — `prefetchTriggerRowId(recentIds:)` no longer only serves recency

`mobile/garyx-mobile/Sources/GaryxMobileCore/GaryxHomeThreadListPager.swift:405`.

The helper is now also the prefetch trigger for search results. The parameter
name still says `recentIds`. Rename to something feed-neutral when the pager is
next touched.

### I-4 — Home list divider still reads deprecated `UIScreen.main`

`mobile/garyx-mobile/App/GaryxMobile/GaryxMobileSidebarViews.swift:1220`.

The existing divider computes one physical pixel with `UIScreen.main.scale`,
which is deprecated on iOS 26 in favor of the screen or trait collection from
the active view context. The focused thread-search build reproduces this
warning, but changing the shared Home row rendering is outside this feature.

### I-5 — Other mounted morph sources may leak through the shared glass pass

- `mobile/garyx-mobile/App/GaryxMobile/GaryxCapsuleChromePanel.swift:53-70`
- `mobile/garyx-mobile/App/GaryxMobile/GaryxMobileConversationViews.swift:1560-1584`

Both pre-existing morph sources keep their compact button mounted, switch its
glass to `.identity` with `isEnabled: !isHidden`, and then hide the Button with
an ancestor opacity. The Home search residue proved that an enclosing
`GlassEffectContainer` can render a glass node outside that ancestor opacity on
iOS 26.5. These two surfaces need their own visual reproduction and pixel
coverage before changing them; they are outside the Home search fix.

### I-6 — `garyxAdaptiveGlass(isEnabled:)` combines two visibility contracts

`mobile/garyx-mobile/App/GaryxMobile/GaryxMobileDesignSystem.swift:330-369`.

On the Liquid Glass path, disabling the modifier selects `Glass.identity`; on
the Reduce Transparency path, it also removes the opaque
`secondarySystemBackground` fallback entirely. Those are separate concerns.
Changing or omitting `isEnabled` for a morph source can therefore alter the
accessibility fallback even when the glass-path intent is only to control
shared-pass participation. Split the contracts in a dedicated design-system
task rather than broadening the Home search fix.

### I-7 — Home UI-test fixtures inherit simulator container state

- `mobile/garyx-mobile/UITests/GaryxMobileUITests/HomeChromeInteractionTests.swift:291-300`
- `mobile/garyx-mobile/App/GaryxMobile/GaryxMobileModel.swift:662-697`

`GARYX_MOBILE_DEBUG_SNAPSHOT` supplies deterministic presentation data, but the
app still opens its persisted gateway-scoped state before applying that
snapshot, and a fresh app container can present the system notification prompt.
Both dirty and newly reset simulator containers can therefore block an
otherwise deterministic Home interaction test before its first assertion.
Give UI tests an isolated launch contract that resets scoped state and settles
first-launch permissions in a dedicated harness task; do not add one-off
dismissals to the thread-search test.

## Desktop

### M-1 — Baseline i18n literal failure predates this feature

- Source: `desktop/garyx-desktop/src/renderer/src/message-rich-text-linebreaks.test.mjs:71`
  and `:75`.
- Found while running `npm run test:i18n-literals` for the Mac thread-search
  implementation. The unchanged baseline at commit `844b332f7` contains Han text
  in a Markdown rendering fixture, so the repository-wide scanner fails before
  it ever evaluates the thread-search diff. Independently reproduced by Gary on
  clean `main`: the same two lines, and only those two.
- This fixture/scanner contract is outside the thread-search implementation
  path. Resolve it in a separate task; it is not a thread-search FAIL/BLOCKER.

## Explicitly still out of scope (do not re-open)

Per §7 and D4 of the design, and confirmed unchanged by review:

- Searching message content / transcripts.
- Match-substring highlighting inside result rows.
- Search history, recent queries, suggestions.
- The legacy-gateway picker fallback (`GaryxLegacyThreadPickerFallback`,
  `probeThreadSummariesCapability`). No new problem was found there; it is
  recorded so the next reviewer does not re-litigate it.
