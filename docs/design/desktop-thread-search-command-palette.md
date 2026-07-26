# Desktop Thread Search — Codex Command Palette Parity

Status: design, ready to implement
Surface: `desktop/garyx-desktop` — `⌘K` thread search dialog
Reference: ChatGPT/Codex Mac app global command menu, measured live over CDP
on 2026-07-26 (Codex `Chrome/150.0.7871.128`, light mode, viewport
`1080×760`, DPR 2)

## Problem

The current `⌘K` panel is a generic modal dialog wearing search clothes, not a
command palette. Measured against the installed Garyx app (`1480×940`):

| Property | Garyx today | Codex |
| --- | --- | --- |
| Panel width | `760px` | `min(520px, 92vw)` |
| Panel height | `620px` fixed (`height`/`min-height`/`max-height` all pinned) | content-driven, `max-height` capped |
| Vertical anchor | true center (`top: 50%` + `translateY(-50%)`) | top pinned at `max(16px, (100dvh − maxH)/2)`; content grows downward |
| Input row | `73px` band, `21px` magnifier, `18px` text, `border-bottom` divider | `33px`, no icon, no divider |
| Result row | `58px`, two lines, `32px` avatar | `31px`, one line, `20px` icon slot |
| Hover vs highlighted | two different washes (`row-hover` / `row-selected`) | one shared wash |
| Empty / loading / error | fills the whole `620px` with a `24px` glyph | one `32px` centered line |

Two consequences are visible in the app:

1. **The empty state is a hole.** With no query the panel is 620px tall and
   contains one small glyph plus the sentence `按名称搜索线程` — which is a
   verbatim repeat of the placeholder two rows above it. Same words, twice, in
   an otherwise blank 760×547 area.
2. **Density is half of Codex.** 58px rows show ~9 results in the viewport
   where Codex's 31px rows show ~14 in a panel that is 240px narrower.

## Key insight

Codex's command palette is not a bespoke surface. `[cmdk-item]` and its
dropdown-menu item share one row recipe — measured identical padding
(`5px 8px`), radius (`radius-lg` = `12.5px`), and highlight wash
(`list-hover-background` ≈ foreground @5.5%).

Garyx already owns that recipe: `styles/menus.css` was extracted 1:1 from the
same Codex renderer and defines `--menu-item-padding-y: 5px`,
`--menu-item-padding-x: 8px`, `--menu-item-radius: var(--radius-lg)` (12.5px),
`--menu-item-hover-bg: var(--color-token-row-hover)`, and
`--menu-surface-padding: 4px`.

So this is not "add more CSS to the search dialog". It is: **the search panel
is a command-palette surface that inherits the shared menu row recipe, and owns
only its own geometry (width, top anchor, content-driven height).** The 58px
two-line row is a local fork of a recipe the app already has, and it goes away.

## Measured reference (Codex, light mode)

Extracted from `webview/assets/app-initial-Czet5G9g.css` inside
`ChatGPT.app/Contents/Resources/app.asar`, cross-checked against live computed
styles. Only the properties needed for this component were taken.

### Panel geometry

```css
.command-menu-dialog {
  --command-menu-list-max-height: min(300px, max(120px, calc(90vh - 64px)));
  --command-menu-max-height: calc(var(--command-menu-list-max-height) + 64px);
  top: max(calc(var(--spacing) * 4), calc((100vh - var(--command-menu-max-height)) / 2));
  width: min(520px, 92vw);
}
.global-command-menu-dialog {
  --command-menu-list-max-height: min(440px, max(120px, calc(90vh - 64px)));
}
```

`--spacing` is `4px`, so the top floor is `16px`. Verified at viewport height
`760`: list cap `min(440, max(120, 684 − 64)) = 440`, panel cap `504`, top
`max(16, (760 − 504)/2) = 128` — matching the measured `y = 128`.

The anchor is computed from the **cap**, not from actual content height. That
is the detail that makes it feel precise: the input never moves. Measured on
the live app, `y` stayed exactly `128` while the panel height went
`487 → 221.6 → 105` as the query narrowed the result set.

### Surface

```css
[cmdk-root] { /* under .command-menu-dialog */
  box-shadow: 0 16px 32px -8px rgba(0, 0, 0, 0.19);
  background-color: <dropdown-background>;  /* opaque; blur explicitly off */
  backdrop-filter: none;
  border-radius: 20px;                      /* radius-2xl */
  border: 1px solid transparent;            /* light mode */
  max-height: var(--command-menu-max-height);
  padding: 4px;
  gap: 4px;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}
```

Overlay: `rgba(0, 0, 0, 0.133)`, no blur.

### Input

```css
[cmdk-input] { padding: 6px 10px }   /* measured box 510×33 */
```

`14px / 21px`, weight `445`, no border, no background, no divider, no icon.
Placeholder is the foreground at 50% alpha.

### Row

```css
[cmdk-item] {
  border-radius: 12.5px;              /* radius-lg */
  padding: 5px 8px;                   /* --padding-row-y/x */
  min-height: 24px;                   /* measured height 31px */
  opacity: 0.75;
  display: flex; flex-direction: row; align-items: center;
  width: 100%;
}
[cmdk-item]:hover:not([aria-disabled='true']),
[cmdk-item][data-selected='true'],
[cmdk-item][aria-selected='true'],
[cmdk-item]:focus-visible,
[cmdk-item]:active:not([aria-disabled='true']) {
  background-color: <list-hover-background>;   /* foreground @5.5% */
  opacity: 1;
}
```

Hover and keyboard highlight are **one rule, one appearance**. Row internals,
measured:

```
[cmdk-item]  h=31, padding 5 8
  └ flex, gap 8, items-center, h=21
      ├ span 20×20 shrink-0                    ← icon/avatar slot (svg is 16×16)
      └ flex-1 min-w-0
          └ flex, gap 8, items-center
              ├ div.truncate flex-1 min-w-0    ← title, 14px/21, w445
              └ ml-auto flex gap-8 items-center
                  ├ div 13px/18.57, fg@49.4%, w=96px, right, truncate  ← subtitle
                  └ span 14px, opacity .8                              ← ⌘-shortcut
```

### Empty state

```css
[cmdk-empty] {
  padding: 6px 10px;
  min-height: 32px;
  color: <description-foreground>;
  text-align: center;
  align-items: center;
  line-height: 1.4;
  display: flex;
}
```

One line. No glyph. Panel collapses to `105px` total (measured).

## Target design

### Ownership

`.thread-search-dialog` keeps its rules in `styles/dialogs.css` (its current
owner, always imported). It consumes the existing `menus.css` row tokens and
adds a small command-palette surface layer. New tokens go in `menus.css` next
to the menu surface they are a sibling of, because "command palette surface" is
a shared concept the app will reuse (a future ⌘P / action palette is the same
surface):

```css
/* menus.css :root */
--palette-surface-radius: 20px;
--palette-surface-shadow: 0 16px 32px -8px rgba(0, 0, 0, 0.19);
--palette-surface-padding: 4px;
--palette-row-font-size: var(--text-md);       /* 14px, vs 13px in menus */
--palette-row-line-height: 21px;
--palette-row-idle-opacity: 0.75;
```

Row padding, radius, and hover wash are **reused, not redeclared**:
`--menu-item-padding-y/x`, `--menu-item-radius`, `--menu-item-hover-bg`.

Do not touch global `--padding-row-y` (`4px`) / `--padding-row-x` (`10px`) —
they differ from Codex's `5px`/`8px` but are used app-wide; the menu tokens
already carry the Codex values for this family.

### Panel

```css
.thread-search-dialog[data-slot='dialog-content'] {
  --palette-list-max-height: min(440px, max(120px, calc(90dvh - 64px)));
  --palette-max-height: calc(var(--palette-list-max-height) + 64px);

  top: max(16px, calc((100dvh - var(--palette-max-height)) / 2));
  transform: none;                    /* overrides .app-dialog-content translateY(-50%) */
  width: min(520px, calc(100dvw - 48px));
  max-width: min(520px, calc(100dvw - 48px));
  height: auto;                       /* content-driven — replaces the pinned 620px */
  min-height: 0;
  max-height: var(--palette-max-height);

  display: flex;
  flex-direction: column;
  gap: var(--palette-surface-padding);
  padding: var(--palette-surface-padding);
  border: 1px solid transparent;
  border-radius: var(--palette-surface-radius);
  background: var(--color-token-bg-primary);
  box-shadow: var(--palette-surface-shadow);
  overflow: hidden;                   /* .app-dialog-content sets overflow-y: auto */
}
```

`grid-template-rows: 73px minmax(0, 1fr)` is deleted — a fixed header track is
what forces the 73px input band.

Backdrop stays Garyx's existing `--app-modal-backdrop-bg`
(`rgba(13, 13, 13, 0.16)`); Codex measures `rgba(0, 0, 0, 0.133)`, same family,
and the app-wide token is not worth forking for a 2.7% alpha delta. Record as
bounded parity.

### Input

```css
.thread-search-input-shell {
  display: block;                     /* no icon column */
  padding: 0;
  border-bottom: 0;                   /* divider removed */
}
.thread-search-input[data-slot='input'] {
  height: 33px;
  padding: 6px 10px;
  border: 0;
  background: transparent;
  box-shadow: none;
  font-size: var(--palette-row-font-size);
  line-height: var(--palette-row-line-height);
  font-weight: 445;
}
```

The `<Search>` glyph is removed from the input row. Rationale: it is redundant
with the placeholder, it is the single heaviest element in the panel at 21px,
and the reference surface has no icon. This is the one deliberate departure
from "keep every Garyx affordance" and it is what buys the 73px → 41px header.

### Row — one line

```
[avatar 20×20]  [title truncate flex-1]  [agent · workspace  →right, truncate]  [time]
                gap 8                     13px fg@49.5%, max-width 180px         13px fg@49.5%
```

```css
.thread-search-result-row {
  display: flex;
  align-items: center;
  gap: 8px;
  width: 100%;
  min-height: 24px;
  padding: var(--menu-item-padding-y) var(--menu-item-padding-x);
  border: 0;
  border-radius: var(--menu-item-radius);
  background: transparent;
  opacity: var(--palette-row-idle-opacity);
  font-size: var(--palette-row-font-size);
  line-height: var(--palette-row-line-height);
  transition:
    background-color var(--duration-fast) var(--ease-standard),
    opacity var(--duration-fast) var(--ease-standard);
}
.thread-search-result-row:hover,
.thread-search-result-row.highlighted {
  background: var(--menu-item-hover-bg);
  opacity: 1;
}
```

Row content changes:

- Avatar drops from `size="default"` (32px) to a 20px surface-local box
  (`.thread-search-result-avatar { width: 20px; height: 20px }`, fallback text
  `9px`). Surface-only choice; no new shared avatar size tier is added because
  nothing else needs 20px yet.
- Title and meta stop being stacked. `agent` and `workspace` join the trailing
  cluster as one `13px` muted segment (`Gary · /Users/…/garyx`), right-aligned,
  `truncate`, `max-width: 180px`, `flex-shrink: 0`.
  - Agent name is **kept**, not dropped for pure Codex symmetry: Garyx thread
    titles collide across agents (`#TASK-… Adversarial review` exists under
    both `Codex` and `Claude` in the measured baseline), so the agent label is
    load-bearing disambiguation, and the avatar alone does not read as text.
- Time keeps its `13px` muted treatment but loses `align-self: start` and its
  `padding-top: 3px` nudge — it is now vertically centered like everything else
  in a one-line row.

Titles keep `truncate` (`overflow hidden` + `text-overflow ellipsis` +
`white-space nowrap`) and `min-width: 0`.

### States — one line each, never a filler block

```css
.thread-search-state {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
  min-height: 32px;
  padding: var(--menu-item-padding-y) var(--menu-item-padding-x);
  color: var(--color-token-description-foreground);
  font-size: var(--palette-row-font-size);
  line-height: 1.4;
  text-align: center;
}
```

- **No query typed** → render no body at all. The panel collapses to
  `4 + 33 + 4 = 41px` plus borders: an input, nothing else. This deletes the
  duplicated `按名称搜索线程` sentence, and it is the honest rendering of
  "there is nothing to show yet."
- **Loading** → one line, `搜索线程中…`, `14px` spinner (down from 24px).
- **Empty** → one line, existing `No threads named "{query}"` copy.
- **Failed** → one line, message plus the inline `Retry` button.

The `24px` decorative `Search` glyph is removed from every state. The
`flex-direction: column` + `height: 100%` + `padding: 32px` block that made the
620px hole is deleted.

### List

```css
.thread-search-results {
  max-height: var(--palette-list-max-height);
  min-height: 0;
  padding: 0;                         /* was 6px — the 4px surface padding is the inset */
  overflow-x: hidden;
  overflow-y: auto;
  overscroll-behavior: contain;
}
```

`height: 100%` is removed; the list must be allowed to be shorter than its cap,
otherwise the panel cannot shrink.

Footer (`loadingMore` / `loadMoreFailure`) aligns to the row grid:
`min-height: 31px`, `padding: 5px 8px`, `font-size: var(--text-base)`.

## Explicitly out of scope

Recorded rather than absorbed (per the scope boundary rule):

- `⌘1…⌘9` quick-pick shortcuts on the first nine rows. Codex has them; adding
  them is new behavior, not visual parity. → `thread-search-review-debt.md`.
- Group headings (`任务` / `推荐` / `Settings`). Codex needs them because its
  palette mixes threads, commands, and settings; Garyx search returns exactly
  one kind of row.
- Content-snippet result rows (Codex's two-line variant with highlighted
  in-body matches). Garyx search is title-only by contract
  (`search_title`, #TASK-2729) — a snippet line would have nothing to show.
- Recent-thread listing on an empty query. Real feature idea, real scope
  increase; the empty panel here is the visual fix only.
- Dark mode. Desktop is light-only per repo direction.

## Verification plan

Reproduce every state in the **packaged** app (`npm run dist:dir`, restart,
attach CDP on `39222`) — a dev renderer is not evidence.

Geometry gates, viewport `1480×940` (also sweep `640×480`, `1080×760`,
`1920×1200`):

| Assertion | Expected |
| --- | --- |
| Panel width | `520` (and `100dvw − 48` below 568px wide) |
| Panel `top` | `max(16, (100dvh − (min(440, max(120, .9·dvh − 64)) + 64))/2)` |
| Panel `top` invariance | identical value across empty / 1 row / overflowing |
| Panel height, no query | `41px` + borders; no body element in the DOM |
| Panel height, overflowing | `min(440, max(120, .9·dvh − 64)) + 64` clamp respected |
| Row height | `31px`; `min-height` `24px`; radius `12.5px`; padding `5px 8px` |
| Row idle opacity | `0.75`; hover **and** `.highlighted` both `1` + `row-hover` bg |
| Input | `33px`, `padding 6px 10px`, no `border-bottom`, no `svg` in the shell |
| States | `min-height 32px`, single line, zero decorative `svg` |
| Surface | radius `20px`, shadow `0 16px 32px -8px rgba(0,0,0,.19)`, opaque bg |

Behavior gates (must not regress): `⌘K` opens and focuses the input, `↑`/`↓`
move the highlight and scroll it into view, `Enter` opens the highlighted
thread, `Escape` and outside click dismiss and return focus, IME composition
does not steal arrow keys, mouse-enter re-highlights, infinite scroll still
fires near the end, `Retry` still works in both failure states, and
`aria-activedescendant` / `role=listbox` / `role=option` wiring is intact.

Tests:

- Extend `thread-search-model.test.mjs` for any presentation change (the
  "prompt" state must now be representable as "render nothing").
- Add a declaration-level contract test pinning the palette recipe and its
  ownership (`dialogs.css` owns `.thread-search-dialog`; `menus.css` owns the
  `--palette-*` tokens; no other stylesheet redeclares them), in the style of
  `menu-design-system.test.mjs`.
- `npm run test:unit` (full desktop suite — shared CSS tokens change),
  `npm run build:ui`, `npm run dist:dir`.

Pixel evidence: same-crop, `scale: 'css'`, same content and state, before/after
in Garyx plus the archived Codex reference crops in
`/tmp/codex-copy-search/evidence/`. Report geometry equality as the hard gate;
declare any antialiasing tolerance explicitly.

## Bounded-parity declarations

Not 1:1 with Codex, on purpose, with reasons:

1. Backdrop alpha `0.16` (Garyx token) vs `0.133` (Codex).
2. Agent name retained in the trailing meta cluster (Codex shows one subtitle
   field); Garyx titles need the disambiguation.
3. No `⌘n` shortcut column, no group headings, no snippet rows (scope).
4. Avatar is a 20px circle with initials/provider art where Codex draws a 16px
   monochrome glyph in a 20px slot — Garyx threads are agent-owned and the
   avatar is the established identity affordance.
