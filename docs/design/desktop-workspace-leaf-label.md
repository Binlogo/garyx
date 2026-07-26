# Desktop Workspace Leaf Label — Separate Computation From Copy

Status: design, ready to implement
Surface: `desktop/garyx-desktop` renderer — every place that shows a workspace
by its last path segment
Origin: debt found while shipping #TASK-2769 / #TASK-2774 (thread search
command palette). Recorded here rather than absorbed into that task.

## The real problem is not duplication

Seven functions in the renderer compute "show a workspace by its last path
segment". The obvious read is *seven copies of one helper, go merge them*. That
read is wrong, and merging them naively would be a regression.

Measured inventory:

| Location | Empty-input result | Separators | Extra rule |
| --- | --- | --- | --- |
| `app-shell/workspace-helpers.ts` `compactPathLabel` | `'Workspace unavailable'` | `/` and `\` | — |
| `thread-model.ts` `workspaceNameFromPath` | `'Workspace'` | `/` and `\` | strips trailing separators first |
| `NewThreadEmptyState.tsx` `workspaceLabel` | `"No workspace"` | `/` only | — |
| `components/WorkspacePathPicker.tsx` `workspaceLeafName` | `''` | `/` only | — |
| `components/AutomationListPage.tsx` `compactPathLabel` | `''` | `/` and `\` | — |
| `components/WorkspaceComposerChip.tsx` `workspaceChipLabel` | input path | `/` only | gateway home → `~` |
| `components/AutomationDialog.tsx` `compactPath` | `''` | `/` only | **keeps last *two* segments as `…/a/b`** |

Two of these are not the same function at all:

- `AutomationDialog.compactPath` returns the last **two** segments with an `…/`
  prefix. That is a different presentation strategy, not a leaf label.
- `WorkspaceComposerChip.workspaceChipLabel` maps the gateway home directory to
  `~` before falling back to the leaf. That is a product rule layered on top.

The remaining five do compute the same leaf, and they differ only in **what to
say when there is nothing to show**. That difference is why they were copied:

```
compactPathLabel('')  →  'Workspace unavailable'   // hard-coded English
```

The shared helper welds the leaf computation to one caller's user-facing copy.
Any surface needing different copy — and they all do — cannot reuse it, so each
wrote its own. **The duplication is a symptom; the welded copy is the cause.**

## And the welded copy is a live i18n bug

Three of those fallbacks are hard-coded English strings returned from plain
functions, never passing through `t()`:

```
app-shell/workspace-helpers.ts:8   return 'Workspace unavailable';
thread-model.ts:181                return 'Workspace';
NewThreadEmptyState.tsx:326        return "No workspace";
```

`i18n/index.tsx` already carries translations for two of them:

```
'Workspace unavailable': '工作区不可用',
'No workspace': …
```

So a zh-locale user hits an English string even though the translation exists.
This is a user-visible defect, not a style preference.

## The fix: computation has no copy

Split the two concerns. One shared pure function computes the leaf and says
nothing when there is nothing to say; every caller injects its own translated
copy.

```ts
// app-shell/workspace-helpers.ts
/**
 * The workspace's last path segment, or '' when the input has no segments.
 * Never returns user-facing copy — callers own their own fallback string so it
 * can go through t().
 */
export function workspaceLeafSegment(path?: string | null): string
```

Behavior, unified to the most permissive of the current implementations:

- trim the input; strip trailing `/` and `\` runs
- split on both `/` and `\` (Windows-style paths keep working where they
  already did, and start working where they did not)
- return the last non-empty segment, else `''`

Callers then read:

```ts
const label = workspaceLeafSegment(path) || t('No workspace');
```

`AutomationListPage.getWorkspaceLabel` is already written this way
(`… || compactPathLabel(...) || t('Workspace not set')`) and is the reference
shape to copy — it keeps its behavior and just drops its local copy of the
computation.

### Per-caller outcome

| Caller | Change | Visible copy |
| --- | --- | --- |
| `workspace-helpers.compactPathLabel` | delete; callers move to the new function | its two callers gain `t()`-routed copy |
| `thread-search-model.ts` | already injects `noWorkspaceLabel`; swap the inner call | unchanged |
| `thread-model.ts` | use the shared function; fallback becomes translated | **fixes** `'Workspace'` → translated |
| `NewThreadEmptyState.tsx` | use the shared function + `t('No workspace')` | **fixes** hard-coded English |
| `WorkspacePathPicker.tsx` | use the shared function | unchanged (`''` fallback) |
| `AutomationListPage.tsx` | delete local copy, use the shared function | unchanged |
| `WorkspaceComposerChip.tsx` | use the shared function, **keep** the `~` rule | unchanged |
| `AutomationDialog.compactPath` | **leave alone** — different strategy | unchanged |

`thread-model.ts` is not a React component and has no `t()` in scope. Its
`workspaceNameFromPath` feeds a workspace `name` field, so the fallback belongs
at the presentation boundary: pass the already-translated fallback in, or return
`''` and let the view decide. Pick whichever keeps the existing `name`
consumers correct — do not invent a second translation mechanism outside React.

## Explicitly out of scope

- `AutomationDialog.compactPath`'s two-segment strategy. Different presentation,
  not a leaf label. If the two-segment form should become a shared recipe, that
  is its own task.
- The `~` home-directory rule stays local to the composer chip.
- Any broader rework of workspace naming, `selectedWorkspace`, or the workspace
  data model.
- Mobile. This is a desktop renderer duplication only.

## Verification plan

Behavior parity is the whole point, so the gate is per-caller copy:

1. A focused unit test for `workspaceLeafSegment` covering: normal absolute
   path, trailing separator (single and repeated), backslash path, mixed
   separators, root `/`, single segment, empty string, whitespace-only, `null`,
   `undefined`.
2. For every caller in the table, assert the rendered label for both a real path
   and an empty path. The three fixed fallbacks must now come from `t()` — test
   under a zh locale and assert the Chinese string, which is the regression that
   proves the bug is gone.
3. Guard verification in both directions: revert `workspaceLeafSegment` to
   returning the full path and confirm the caller tests fail; revert a fallback
   to its hard-coded English and confirm the locale test fails.
4. `npx tsc --noEmit`, then the full `npm run test:unit` — and check the **total
   test count went up**, not just that failures are zero: a value import missing
   its `.ts` extension makes the whole test file exit 1 under the native runner
   while `tsx --test` on that one file still passes.
5. `npm run build:ui` and `npm run dist:dir`, then verify in the packaged app
   that each touched surface still shows the same label it showed before —
   thread search rows, new-thread empty state, workspace picker, automation
   list, composer chip.

No screenshots of unchanged surfaces are needed beyond confirming the labels;
this change is deliberately invisible except for the three translated fallbacks.
