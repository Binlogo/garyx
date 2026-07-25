/**
 * Behaviour core for the shared segmented control.
 *
 * The accessibility contract is a decision, not markup, so it lives here as
 * pure functions the component only spreads onto its elements. That keeps the
 * contract testable without a DOM — the component stays a thin mapping — and it
 * is why the semantics are computed rather than hard-coded per surface.
 */

/**
 * `tabs` switches structurally different panels, so per the WAI-ARIA tabs
 * pattern every tab must reference the panel it controls. `radiogroup` picks one
 * of a set of mutually exclusive options — a filter or a view switch — where no
 * panel is swapped and claiming one would be a false promise.
 */
export type SegmentedSemantics = "tabs" | "radiogroup";

export type SegmentedContainerAttributes = {
  role: "tablist" | "radiogroup";
};

export type SegmentedItemAttributes = {
  role: "tab" | "radio";
  "aria-selected"?: boolean;
  "aria-checked"?: boolean;
  "aria-controls"?: string;
  /** Roving tabIndex: only the active item is reachable by Tab. */
  tabIndex: 0 | -1;
};

export function segmentedContainerAttributes(
  semantics: SegmentedSemantics,
): SegmentedContainerAttributes {
  return { role: semantics === "tabs" ? "tablist" : "radiogroup" };
}

export function segmentedItemAttributes(
  semantics: SegmentedSemantics,
  selected: boolean,
  panelId?: string,
): SegmentedItemAttributes {
  const tabIndex = selected ? 0 : -1;
  if (semantics === "tabs") {
    return {
      role: "tab",
      "aria-selected": selected,
      "aria-controls": panelId,
      tabIndex,
    };
  }
  return { role: "radio", "aria-checked": selected, tabIndex };
}

/** Column recipe for the `fill` layout; `inline` sizes to its content. */
export function segmentedFillColumns(optionCount: number): string {
  return `repeat(${optionCount}, minmax(0, 1fr))`;
}

export function nextSegmentedValue<T extends string>(
  values: readonly T[],
  current: T,
  key: "ArrowLeft" | "ArrowRight",
): T | null {
  const index = values.indexOf(current);
  if (index < 0 || values.length === 0) {
    return null;
  }
  const delta = key === "ArrowRight" ? 1 : -1;
  return values[(index + delta + values.length) % values.length];
}
