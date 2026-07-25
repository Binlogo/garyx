import type { ReactNode } from 'react';
import { useRef, type KeyboardEvent } from 'react';

import { nextSegmentedValue } from './segmented-control-model';

/**
 * The app's one segmented control.
 *
 * Four surfaces used to hand-roll this: the sidebar's Threads/Projects tabs,
 * the recent-filter row, the Tasks board/list switch, and the Capsules
 * all/favorites switch. Each had its own CSS block and its own — inconsistent —
 * accessibility: one exposed a full tablist with arrow-key traversal, one only
 * `aria-pressed`, one nothing but a group label. This owns both the recipe and
 * the semantics so a new surface cannot reintroduce a worse variant.
 *
 * Two layouts, because the difference is real and not worth a flag per rule:
 * - `fill`   equal-width columns filling the container (narrow sidebar rails)
 * - `inline` intrinsic width (page toolbars, where it sits beside buttons)
 */

export type SegmentedOption<T extends string> = {
  value: T;
  /** Already-translated label. */
  label: string;
  /** Optional leading glyph; `inline` reserves a gap for it. */
  icon?: ReactNode;
};

type SegmentedControlProps<T extends string> = {
  ariaLabel: string;
  options: readonly SegmentedOption<T>[];
  value: T;
  onChange: (value: T) => void;
  layout?: 'fill' | 'inline';
  /** `strong` bumps the label size where the control switches a whole surface. */
  emphasis?: 'default' | 'strong';
  /** Extra modifier for surface-specific spacing only. */
  className?: string;
};

export function SegmentedControl<T extends string>({
  ariaLabel,
  options,
  value,
  onChange,
  layout = 'fill',
  emphasis = 'default',
  className,
}: SegmentedControlProps<T>) {
  const tabRefs = useRef(new Map<T, HTMLButtonElement | null>());

  function handleKeyDown(event: KeyboardEvent<HTMLButtonElement>, current: T) {
    if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') {
      return;
    }
    event.preventDefault();
    const next = nextSegmentedValue(
      options.map((option) => option.value),
      current,
      event.key,
    );
    if (next === null) {
      return;
    }
    onChange(next);
    tabRefs.current.get(next)?.focus();
  }

  return (
    <div
      aria-label={ariaLabel}
      className={[
        'gx-segmented',
        `gx-segmented--${layout}`,
        emphasis === 'strong' ? 'gx-segmented--strong' : null,
        className,
      ]
        .filter(Boolean)
        .join(' ')}
      role="tablist"
      style={
        layout === 'fill'
          ? { gridTemplateColumns: `repeat(${options.length}, minmax(0, 1fr))` }
          : undefined
      }
    >
      {options.map((option) => {
        const selected = option.value === value;
        return (
          <button
            aria-selected={selected}
            className={selected ? 'active' : undefined}
            key={option.value}
            onClick={() => onChange(option.value)}
            onKeyDown={(event) => handleKeyDown(event, option.value)}
            ref={(node) => {
              tabRefs.current.set(option.value, node);
            }}
            role="tab"
            tabIndex={selected ? 0 : -1}
            type="button"
          >
            {option.icon ?? null}
            {option.label}
          </button>
        );
      })}
    </div>
  );
}
