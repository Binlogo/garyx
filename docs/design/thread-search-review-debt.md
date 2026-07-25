# Thread Search — Review Debt

Adjacent items found while reviewing thread search (`docs/design/thread-search.md`
§7 requires them recorded here and filed separately). Nothing in this file is a
defect in the thread-search change path; each is pre-existing or neighbouring
work that should get its own task.

## D-1 — Two mechanisms apply row running state

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

## D-2 — `GaryxGlassSearchField` has no automated coverage

`mobile/garyx-mobile/App/GaryxMobile/GaryxMobileStatusComponents.swift:465`.

The component now carries two rendering modes (`drawsGlassSurface`) and two
focus modes (optional `FocusState` binding). Its other consumer, the automation
thread picker (`GaryxMobileAutomationViews.swift`), is covered only by manual QA,
so a future change to the shared field can regress the picker silently. Either
add a focused UITest for the picker's search field or give the component a
snapshot/behaviour test.

## D-3 — `prefetchTriggerRowId(recentIds:)` no longer only serves recency

`mobile/garyx-mobile/Sources/GaryxMobileCore/GaryxHomeThreadListPager.swift:405`.

The helper is now also the prefetch trigger for search results. The parameter
name still says `recentIds`. Rename to something feed-neutral when the pager is
next touched.

## Explicitly still out of scope (do not re-open)

Per §7 and D4 of the design, and confirmed unchanged by this review:

- Searching message content / transcripts.
- Match-substring highlighting inside result rows.
- Search history, recent queries, suggestions.
- The legacy-gateway picker fallback (`GaryxLegacyThreadPickerFallback`,
  `probeThreadSummariesCapability`). No new problem was found there; it is
  recorded so the next reviewer does not re-litigate it.
