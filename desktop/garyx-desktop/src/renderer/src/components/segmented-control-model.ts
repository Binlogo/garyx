/**
 * Behaviour core for the shared segmented control.
 *
 * The accessibility contract is a decision, not markup, so it lives here as
 * pure functions the component only spreads onto its elements — testable
 * without a DOM, with the component staying a thin mapping.
 *
 * All four surfaces are radio groups: each picks one of a set of mutually
 * exclusive options while its surrounding container stays put and only the
 * contents change. That includes the sidebar's Threads/Projects switch. The
 * tabs pattern was considered and rejected for it: tabs require every tab to
 * reference its own tabpanel, which means rendering every panel (the W3C
 * examples keep inactive ones `hidden`). The Threads panel holds hundreds of
 * rows, so keeping both mounted to satisfy the pattern would double the
 * sidebar's DOM for no user-visible gain. A single dynamic panel with two tabs
 * pointing at it is worse than either: it tells assistive tech that the
 * inactive tab controls the panel currently labelled by the active one.
 */

export type SegmentedContainerAttributes = {
  role: "radiogroup";
};

export type SegmentedItemAttributes = {
  role: "radio";
  "aria-checked": boolean;
  /** Roving tabIndex: only the checked item is reachable by Tab. */
  tabIndex: 0 | -1;
};

/**
 * Keys that move the selection, per the WAI-ARIA radio group pattern: Right and
 * Down pick the next option, Left and Up the previous one, both wrapping.
 */
export const SEGMENTED_NEXT_KEYS = ["ArrowRight", "ArrowDown"] as const;
export const SEGMENTED_PREVIOUS_KEYS = ["ArrowLeft", "ArrowUp"] as const;

export type SegmentedNavigationKey =
  | (typeof SEGMENTED_NEXT_KEYS)[number]
  | (typeof SEGMENTED_PREVIOUS_KEYS)[number];

export function isSegmentedNavigationKey(
  key: string,
): key is SegmentedNavigationKey {
  return (
    (SEGMENTED_NEXT_KEYS as readonly string[]).includes(key) ||
    (SEGMENTED_PREVIOUS_KEYS as readonly string[]).includes(key)
  );
}

export function segmentedContainerAttributes(): SegmentedContainerAttributes {
  return { role: "radiogroup" };
}

export function segmentedItemAttributes(
  checked: boolean,
): SegmentedItemAttributes {
  return { role: "radio", "aria-checked": checked, tabIndex: checked ? 0 : -1 };
}

/** Column recipe for the `fill` layout; `inline` sizes to its content. */
export function segmentedFillColumns(optionCount: number): string {
  return `repeat(${optionCount}, minmax(0, 1fr))`;
}

export function nextSegmentedValue<T extends string>(
  values: readonly T[],
  current: T,
  key: SegmentedNavigationKey,
): T | null {
  const index = values.indexOf(current);
  if (index < 0 || values.length === 0) {
    return null;
  }
  const delta = (SEGMENTED_NEXT_KEYS as readonly string[]).includes(key)
    ? 1
    : -1;
  return values[(index + delta + values.length) % values.length];
}
