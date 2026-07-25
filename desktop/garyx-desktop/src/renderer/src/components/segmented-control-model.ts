/**
 * Arrow-key traversal for the shared segmented control.
 *
 * Kept as a pure function so the wrap-around behaviour is testable without a
 * DOM, and so each surface's option array stays the single source of order.
 */
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
