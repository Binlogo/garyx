import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";
import esbuild from "esbuild";

import {
  isSegmentedNavigationKey,
  nextSegmentedValue,
  segmentedContainerAttributes,
  segmentedFillColumns,
  segmentedItemAttributes,
} from "./segmented-control-model.ts";

// These render the PRODUCTION component and its real callers, bundled the same
// way as `task-notification-blank-repro.test.mjs`. Asserting only the model
// would pass even if the component stopped spreading its attributes or a caller
// stopped composing it, which is exactly the gap that made the previous version
// of this file worthless. Cascaded CSS is still verified in the real app.

async function loadRenderers() {
  const result = await esbuild.build({
    stdin: {
      contents: [
        'import React from "react";',
        'import { renderToStaticMarkup } from "react-dom/server";',
        'import { SegmentedControl } from "./src/renderer/src/components/SegmentedControl.tsx";',
        'import { SidebarTabs } from "./src/renderer/src/SidebarTabs.tsx";',
        'import { RecentFilterTabs } from "./src/renderer/src/RecentFilterTabs.tsx";',
        'import { I18nProvider } from "./src/renderer/src/i18n/index.tsx";',
        "const wrap = (node) => renderToStaticMarkup(",
        "  React.createElement(I18nProvider, null, node),",
        ");",
        "export const renderControl = (props) =>",
        "  wrap(React.createElement(SegmentedControl, props));",
        "export const renderSidebarTabs = (props) =>",
        "  wrap(React.createElement(SidebarTabs, props));",
        "export const renderRecentFilter = (props) =>",
        "  wrap(React.createElement(RecentFilterTabs, props));",
      ].join("\n"),
      resolveDir: process.cwd(),
      sourcefile: "segmented-control-ssr.mjs",
    },
    alias: {
      "@": path.resolve("src/renderer/src"),
      "@renderer": path.resolve("src/renderer/src"),
      "@shared": path.resolve("src/shared"),
    },
    banner: {
      js: [
        'import { createRequire } from "node:module";',
        'const require = createRequire(process.cwd() + "/package.json");',
      ].join("\n"),
    },
    bundle: true,
    format: "esm",
    jsx: "automatic",
    platform: "node",
    write: false,
  });
  return import(
    `data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString("base64")}`
  );
}

const renderers = await loadRenderers();

const TWO = [
  { value: "threads", label: "Threads" },
  { value: "projects", label: "Projects" },
];

function buttonAttrs(markup) {
  return [...markup.matchAll(/<button\b([^>]*)>/g)].map(([, attrs]) => attrs);
}

test("the rendered control is a radio group with one checked item", () => {
  const markup = renderers.renderControl({
    ariaLabel: "Sidebar sections",
    options: TWO,
    value: "threads",
  });

  assert.match(markup, /role="radiogroup"/);
  assert.match(markup, /aria-label="Sidebar sections"/);
  // No leftover tabs vocabulary: a single dynamic panel cannot honour the tabs
  // pattern's one-tab-per-panel requirement, so it must not be claimed.
  assert.doesNotMatch(markup, /role="tablist"/);
  assert.doesNotMatch(markup, /aria-selected/);
  assert.doesNotMatch(markup, /aria-controls/);

  const buttons = buttonAttrs(markup);
  assert.equal(buttons.length, 2);
  for (const attrs of buttons) {
    assert.match(attrs, /role="radio"/);
  }
  assert.equal(buttons.filter((a) => /aria-checked="true"/.test(a)).length, 1);
  assert.equal(buttons.filter((a) => /aria-checked="false"/.test(a)).length, 1);
  // Roving tabIndex: only the checked item is in the Tab sequence.
  assert.match(buttons[0], /aria-checked="true"/);
  assert.match(buttons[0], /tabindex="0"/i);
  assert.match(buttons[1], /tabindex="-1"/i);
});

test("layout drives the fill column count and inline has none", () => {
  const fill = renderers.renderControl({
    ariaLabel: "Recent filter",
    options: [
      { value: "nonTask", label: "Chats" },
      { value: "all", label: "All" },
      { value: "favorites", label: "Favorites" },
    ],
    value: "nonTask",
  });
  // Adding a segment must not require a CSS change.
  assert.match(fill, /grid-template-columns:repeat\(3, ?minmax\(0, ?1fr\)\)/);
  assert.match(fill, /gx-segmented--fill/);

  const inline = renderers.renderControl({
    ariaLabel: "Task view",
    options: TWO,
    value: "threads",
    layout: "inline",
  });
  assert.match(inline, /gx-segmented--inline/);
  assert.doesNotMatch(inline, /grid-template-columns/);
});

test("emphasis and caller class names compose onto the shared recipe", () => {
  const strong = renderers.renderControl({
    ariaLabel: "Sidebar sections",
    className: "sidebar-tabs",
    emphasis: "strong",
    options: TWO,
    value: "projects",
  });
  assert.match(
    strong,
    /class="gx-segmented gx-segmented--fill gx-segmented--strong sidebar-tabs"/,
  );
  assert.doesNotMatch(
    renderers.renderControl({ ariaLabel: "x", options: TWO, value: "threads" }),
    /gx-segmented--strong/,
  );
});

test("labels and icons render, and only the checked item is marked active", () => {
  const markup = renderers.renderControl({
    ariaLabel: "Task view",
    layout: "inline",
    options: [
      { value: "board", label: "Board", icon: null },
      { value: "list", label: "List" },
    ],
    value: "list",
  });
  assert.match(markup, />Board</);
  assert.match(markup, />List</);
  assert.equal((markup.match(/class="active"/g) ?? []).length, 1);
});

test("the sidebar switch really composes the shared control", () => {
  // Renders the production caller: if SidebarTabs stopped using
  // SegmentedControl, or dropped its own class, this fails.
  const markup = renderers.renderSidebarTabs({
    selectedTab: "projects",
    onSelectTab: () => {},
  });
  assert.match(markup, /role="radiogroup"/);
  assert.match(markup, /gx-segmented--fill/);
  assert.match(markup, /gx-segmented--strong/);
  assert.match(markup, /sidebar-tabs/);
  const buttons = buttonAttrs(markup);
  assert.equal(buttons.length, 2);
  assert.equal(buttons.filter((a) => /aria-checked="true"/.test(a)).length, 1);
  // Second option is the selected one here.
  assert.match(buttons[1], /aria-checked="true"/);
});

test("the recent filter really composes the shared control, with 3 options", () => {
  const markup = renderers.renderRecentFilter({
    selectedFilter: "all",
    onSelectFilter: () => {},
  });
  assert.match(markup, /role="radiogroup"/);
  assert.match(markup, /recent-filter-tabs/);
  assert.match(markup, /grid-template-columns:repeat\(3, ?minmax\(0, ?1fr\)\)/);
  const buttons = buttonAttrs(markup);
  assert.equal(buttons.length, 3);
  assert.equal(buttons.filter((a) => /aria-checked="true"/.test(a)).length, 1);
  assert.doesNotMatch(markup, /aria-selected/);
});

test("the radio group answers all four arrow keys", () => {
  // The WAI-ARIA radio group pattern moves selection with Right/Down and
  // Left/Up. Supporting only Left/Right leaves keyboard users stuck.
  for (const key of ["ArrowRight", "ArrowDown", "ArrowLeft", "ArrowUp"]) {
    assert.equal(isSegmentedNavigationKey(key), true, key);
  }
  for (const key of ["Enter", " ", "Tab", "Home", "End", "a"]) {
    assert.equal(isSegmentedNavigationKey(key), false, key);
  }

  const three = ["nonTask", "all", "favorites"];
  // Down behaves as Next, Up as Previous, both wrapping.
  assert.equal(nextSegmentedValue(three, "nonTask", "ArrowDown"), "all");
  assert.equal(nextSegmentedValue(three, "favorites", "ArrowDown"), "nonTask");
  assert.equal(nextSegmentedValue(three, "nonTask", "ArrowUp"), "favorites");
  assert.equal(nextSegmentedValue(three, "all", "ArrowUp"), "nonTask");
  // Right/Down and Left/Up must agree.
  for (const current of three) {
    assert.equal(
      nextSegmentedValue(three, current, "ArrowRight"),
      nextSegmentedValue(three, current, "ArrowDown"),
    );
    assert.equal(
      nextSegmentedValue(three, current, "ArrowLeft"),
      nextSegmentedValue(three, current, "ArrowUp"),
    );
  }

  const two = ["threads", "projects"];
  assert.equal(nextSegmentedValue(two, "threads", "ArrowDown"), "projects");
  assert.equal(nextSegmentedValue(two, "projects", "ArrowUp"), "threads");
  assert.equal(nextSegmentedValue(["only"], "only", "ArrowDown"), "only");
});

test("an unknown or absent current value moves nothing", () => {
  assert.equal(nextSegmentedValue(["a", "b"], "zz", "ArrowRight"), null);
  assert.equal(nextSegmentedValue([], "a", "ArrowLeft"), null);
});

test("the attribute core has no tabs vocabulary left", () => {
  assert.deepEqual(segmentedContainerAttributes(), { role: "radiogroup" });
  assert.deepEqual(segmentedItemAttributes(true), {
    role: "radio",
    "aria-checked": true,
    tabIndex: 0,
  });
  assert.deepEqual(segmentedItemAttributes(false), {
    role: "radio",
    "aria-checked": false,
    tabIndex: -1,
  });
  assert.equal(segmentedFillColumns(2), "repeat(2, minmax(0, 1fr))");
});
