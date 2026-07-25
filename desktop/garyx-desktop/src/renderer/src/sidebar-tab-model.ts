/**
 * L1 sidebar tab selection. The sidebar splits its body into Threads (the
 * recent chat list) and Projects (bots + workspaces); Pinned stays a separate
 * region above the tabs and belongs to neither.
 *
 * Storage access is injected so the whole model stays pure and testable.
 */

export type SidebarTab = "threads" | "projects";

export const SIDEBAR_TABS: readonly SidebarTab[] = ["threads", "projects"];

export const SIDEBAR_TAB_STORAGE_KEY = "garyx.sidebarTab";

/** Translation keys; render through `t()`. */
const SIDEBAR_TAB_LABELS: Record<SidebarTab, string> = {
  threads: "Threads",
  projects: "Projects",
};

export type SidebarTabReadableStorage = Pick<Storage, "getItem">;
export type SidebarTabWritableStorage = Pick<Storage, "setItem">;

export function sidebarTabLabel(tab: SidebarTab): string {
  return SIDEBAR_TAB_LABELS[tab];
}

/** Anything that is not an exact known tab id falls back to Threads. */
export function normalizeSidebarTab(value: unknown): SidebarTab {
  return value === "projects" ? "projects" : "threads";
}

export function sidebarTabForArrowKey(
  current: SidebarTab,
  key: "ArrowLeft" | "ArrowRight",
): SidebarTab {
  const currentIndex = SIDEBAR_TABS.indexOf(current);
  const delta = key === "ArrowRight" ? 1 : -1;
  return SIDEBAR_TABS[
    (currentIndex + delta + SIDEBAR_TABS.length) % SIDEBAR_TABS.length
  ];
}

export function readStoredSidebarTab(
  storage: SidebarTabReadableStorage | null | undefined,
): SidebarTab {
  if (!storage) {
    return "threads";
  }
  try {
    return normalizeSidebarTab(storage.getItem(SIDEBAR_TAB_STORAGE_KEY));
  } catch {
    // Storage can throw in restricted contexts; the default tab is safe.
    return "threads";
  }
}

export function persistSidebarTab(
  storage: SidebarTabWritableStorage | null | undefined,
  tab: SidebarTab,
): void {
  if (!storage) {
    return;
  }
  try {
    storage.setItem(SIDEBAR_TAB_STORAGE_KEY, tab);
  } catch {
    // Ignore storage failures; the tab choice just will not persist.
  }
}
