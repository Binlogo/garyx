import assert from "node:assert/strict";
import test from "node:test";

import {
  nextSegmentedValue,
  segmentedContainerAttributes,
  segmentedFillColumns,
  segmentedItemAttributes,
} from "./segmented-control-model.ts";

// These assert the control's actual behaviour contract — the accessibility
// decision and the traversal — through the pure core the component spreads onto
// its elements.
//
// Deliberately NOT by scanning component source: per AGENTS.md guards are
// structural, never textual, and a regex over source cannot distinguish a real
// control from a comment that mentions one. The rendered DOM and the cascaded
// CSS are verified where they actually exist, in the packaged-app walkthrough.

test("tabs semantics announce a real panel relationship", () => {
  assert.deepEqual(segmentedContainerAttributes("tabs"), { role: "tablist" });

  const selected = segmentedItemAttributes("tabs", true, "sidebar-tab-panel");
  assert.deepEqual(selected, {
    role: "tab",
    "aria-selected": true,
    "aria-controls": "sidebar-tab-panel",
    tabIndex: 0,
  });
  // The tabs pattern requires the panel reference on every tab, not just the
  // active one, and an inactive tab must stay out of the Tab sequence.
  const inactive = segmentedItemAttributes("tabs", false, "sidebar-tab-panel");
  assert.deepEqual(inactive, {
    role: "tab",
    "aria-selected": false,
    "aria-controls": "sidebar-tab-panel",
    tabIndex: -1,
  });
  // A tab never carries the radio state.
  for (const attrs of [selected, inactive]) {
    assert.ok(!("aria-checked" in attrs));
  }
});

test("radiogroup semantics never claim a panel that does not exist", () => {
  // Filters and view switches change a container's contents; they do not swap
  // panels. Announcing them as tabs would promise a panel relationship that is
  // not there, and would drop the accurate checked state.
  assert.deepEqual(segmentedContainerAttributes("radiogroup"), {
    role: "radiogroup",
  });

  const checked = segmentedItemAttributes("radiogroup", true);
  assert.deepEqual(checked, {
    role: "radio",
    "aria-checked": true,
    tabIndex: 0,
  });
  const unchecked = segmentedItemAttributes("radiogroup", false);
  assert.deepEqual(unchecked, {
    role: "radio",
    "aria-checked": false,
    tabIndex: -1,
  });
  for (const attrs of [checked, unchecked]) {
    assert.ok(!("aria-selected" in attrs));
    assert.ok(!("aria-controls" in attrs));
  }
});

test("a panel id is ignored by radiogroup even if one is passed", () => {
  // The prop types make this unreachable from TypeScript; the core must still
  // not leak a panel reference into the wrong pattern.
  const attrs = segmentedItemAttributes("radiogroup", true, "some-panel");
  assert.ok(!("aria-controls" in attrs));
});

test("exactly one item is reachable by Tab", () => {
  for (const semantics of ["tabs", "radiogroup"]) {
    const indexes = [true, false, false].map(
      (selected) => segmentedItemAttributes(semantics, selected, "p").tabIndex,
    );
    assert.deepEqual(indexes, [0, -1, -1]);
  }
});

test("the fill layout derives its columns from the option count", () => {
  // Adding a segment must not require a CSS change.
  assert.equal(segmentedFillColumns(2), "repeat(2, minmax(0, 1fr))");
  assert.equal(segmentedFillColumns(3), "repeat(3, minmax(0, 1fr))");
});

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

  assert.equal(nextSegmentedValue(["only"], "only", "ArrowRight"), "only");
});

test("an unknown or absent current value moves nothing", () => {
  assert.equal(nextSegmentedValue(["a", "b"], "zz", "ArrowRight"), null);
  assert.equal(nextSegmentedValue([], "a", "ArrowLeft"), null);
});
