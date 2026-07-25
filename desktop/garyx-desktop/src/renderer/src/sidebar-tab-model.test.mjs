import assert from "node:assert/strict";
import test from "node:test";

import {
  SIDEBAR_TAB_STORAGE_KEY,
  SIDEBAR_TABS,
  normalizeSidebarTab,
  persistSidebarTab,
  readStoredSidebarTab,
  sidebarTabLabel,
} from "./sidebar-tab-model.ts";

function fakeStorage(initial) {
  const map = new Map(Object.entries(initial ?? {}));
  return {
    map,
    getItem(key) {
      return map.has(key) ? map.get(key) : null;
    },
    setItem(key, value) {
      map.set(key, value);
    },
  };
}

function throwingStorage() {
  return {
    getItem() {
      throw new Error("storage disabled");
    },
    setItem() {
      throw new Error("storage disabled");
    },
  };
}

test("the tab order is Threads then Projects", () => {
  assert.deepEqual([...SIDEBAR_TABS], ["threads", "projects"]);
  assert.equal(sidebarTabLabel("threads"), "Threads");
  assert.equal(sidebarTabLabel("projects"), "Projects");
});

test("only exact known ids normalize away from the Threads default", () => {
  assert.equal(normalizeSidebarTab("projects"), "projects");
  assert.equal(normalizeSidebarTab("threads"), "threads");
  for (const value of [
    null,
    undefined,
    "",
    "Projects",
    " projects",
    "recent",
    0,
    {},
  ]) {
    assert.equal(normalizeSidebarTab(value), "threads");
  }
});

test("the tab choice round-trips through storage", () => {
  const storage = fakeStorage();
  assert.equal(readStoredSidebarTab(storage), "threads");

  persistSidebarTab(storage, "projects");
  assert.equal(storage.map.get(SIDEBAR_TAB_STORAGE_KEY), "projects");
  assert.equal(readStoredSidebarTab(storage), "projects");

  persistSidebarTab(storage, "threads");
  assert.equal(readStoredSidebarTab(storage), "threads");
});

test("a stored unknown value falls back without being rewritten", () => {
  const storage = fakeStorage({ [SIDEBAR_TAB_STORAGE_KEY]: "capsules" });
  assert.equal(readStoredSidebarTab(storage), "threads");
  assert.equal(storage.map.get(SIDEBAR_TAB_STORAGE_KEY), "capsules");
});

test("storage failures degrade to the default instead of throwing", () => {
  assert.equal(readStoredSidebarTab(throwingStorage()), "threads");
  assert.equal(readStoredSidebarTab(null), "threads");
  assert.equal(readStoredSidebarTab(undefined), "threads");
  assert.doesNotThrow(() => persistSidebarTab(throwingStorage(), "projects"));
  assert.doesNotThrow(() => persistSidebarTab(null, "projects"));
});
