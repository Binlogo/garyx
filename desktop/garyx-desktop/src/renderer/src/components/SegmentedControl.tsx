import type { ReactNode } from 'react';
import { useRef, type KeyboardEvent } from 'react';

import {
  isSegmentedNavigationKey,
  nextSegmentedValue,
  segmentedContainerAttributes,
  segmentedFillColumns,
  segmentedItemAttributes,
} from './segmented-control-model';

/**
 * The app's one segmented control.
 *
 * Four surfaces used to hand-roll this, each with its own CSS block and its own
 * inconsistent accessibility: one exposed a tablist with arrow-key traversal,
 * one only `aria-pressed`, one nothing but a group label. This owns the recipe
 * and the semantics so a new surface cannot reintroduce a worse variant.
 *
 * Every surface here is a radio group — see `segmented-control-model.ts` for why
 * the tabs pattern was rejected even for the sidebar's Threads/Projects switch.
 *
 * Two layouts, because the difference is real:
 * - `fill`   equal-width columns filling the container (narrow sidebar rails)
 * - `inline` intrinsic width (page toolbars, where it sits beside buttons)
 */

export type SegmentedOption<T extends string> = {
  value: T;
  /** Already-translated label. */
  label: string;
  /** Optional leading glyph. */
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
  const itemRefs = useRef(new Map<T, HTMLButtonElement | null>());

  function handleKeyDown(event: KeyboardEvent<HTMLButtonElement>, current: T) {
    if (!isSegmentedNavigationKey(event.key)) {
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
    itemRefs.current.get(next)?.focus();
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
      style={
        layout === 'fill'
          ? { gridTemplateColumns: segmentedFillColumns(options.length) }
          : undefined
      }
      {...segmentedContainerAttributes()}
    >
      {options.map((option) => {
        const checked = option.value === value;
        return (
          <button
            className={checked ? 'active' : undefined}
            key={option.value}
            onClick={() => onChange(option.value)}
            onKeyDown={(event) => handleKeyDown(event, option.value)}
            ref={(node) => {
              itemRefs.current.set(option.value, node);
            }}
            type="button"
            {...segmentedItemAttributes(checked)}
          >
            {option.icon ?? null}
            {option.label}
          </button>
        );
      })}
    </div>
  );
}
