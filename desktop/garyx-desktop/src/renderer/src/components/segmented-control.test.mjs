import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { readdirSync } from "node:fs";
import test from "node:test";

import { nextSegmentedValue } from "./segmented-control-model.ts";

test("arrow keys walk the given option order and wrap both ways", () => {
  const three = ["nonTask", "all", "favorites"];
  assert.equal(nextSegmentedValue(three, "nonTask", "ArrowRight"), "all");
  assert.equal(nextSegmentedValue(three, "all", "ArrowRight"), "favorites");
  assert.equal(nextSegmentedValue(three, "favorites", "ArrowRight"), "nonTask");
  assert.equal(nextSegmentedValue(three, "nonTask", "ArrowLeft"), "favorites");
  assert.equal(nextSegmentedValue(three, "favorites", "ArrowLeft"), "all");
  assert.equal(nextSegmentedValue(three, "all", "ArrowLeft"), "nonTask");

  const two = ["threads", "projects"];
  assert.equal(nextSegmentedValue(two, "threads", "ArrowRight"), "projects");
  assert.equal(nextSegmentedValue(two, "projects", "ArrowRight"), "threads");
  assert.equal(nextSegmentedValue(two, "projects", "ArrowLeft"), "threads");
  assert.equal(nextSegmentedValue(two, "threads", "ArrowLeft"), "projects");

  // A single option cannot move anywhere but itself.
  assert.equal(nextSegmentedValue(["only"], "only", "ArrowRight"), "only");
});

test("an unknown or absent current value moves nothing", () => {
  assert.equal(nextSegmentedValue(["a", "b"], "zz", "ArrowRight"), null);
  assert.equal(nextSegmentedValue([], "a", "ArrowLeft"), null);
});

test("the segmented recipe is not restated by any surface stylesheet", () => {
  // Four surfaces used to own near-identical copies of this recipe. Callers may
  // position an instance, but the track, pill, and state transitions live once
  // in segmented.css — otherwise the copies drift apart again.
  const stylesDir = new URL("../styles/", import.meta.url);
  const owned = ["segmented.css"];
  const offenders = [];
  for (const fileName of readdirSync(stylesDir)) {
    if (!fileName.endsWith(".css") || owned.includes(fileName)) {
      continue;
    }
    const css = readFileSync(new URL(fileName, stylesDir), "utf8").replace(
      /\/\*[\s\S]*?\*\//g,
      "",
    );
    // A surface may not style the shared control's buttons or its own segmented
    // track; app-shell.css keeps only the drag-region carveout, which has no
    // declaration block of its own beyond `-webkit-app-region`.
    if (/\.gx-segmented[^,{]*button/.test(css)) {
      offenders.push(`${fileName}: styles shared segmented buttons`);
    }
    for (const legacy of [
      "tasks-segmented",
      "capsules-segmented",
      "sidebar-tabs",
    ]) {
      if (new RegExp(`\\.${legacy}\\s*(\\{|,)`).test(css)) {
        offenders.push(`${fileName}: reintroduced .${legacy}`);
      }
    }
  }
  assert.deepEqual(offenders, []);
});

test("every segmented surface renders the shared control", () => {
  const srcDir = new URL("../", import.meta.url);
  const callers = [
    "RecentFilterTabs.tsx",
    "SidebarTabs.tsx",
    "app-shell/components/TasksPanel.tsx",
    "app-shell/components/CapsulesPanel.tsx",
  ];
  for (const caller of callers) {
    const source = readFileSync(new URL(caller, srcDir), "utf8");
    assert.match(source, /<SegmentedControl/, `${caller} must compose the shared control`);
    assert.match(
      source,
      /SegmentedControl['"]/,
      `${caller} must import the shared control`,
    );
  }
});
