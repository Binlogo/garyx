import type { ReactNode } from 'react';
import { useRef, type KeyboardEvent } from 'react';

import {
  nextSegmentedValue,
  segmentedContainerAttributes,
  segmentedFillColumns,
  segmentedItemAttributes,
  type SegmentedSemantics,
} from './segmented-control-model';

/**
 * The app's one segmented control: shared visuals, per-surface semantics.
 *
 * Four surfaces used to hand-roll this, each with its own CSS block and its own
 * inconsistent accessibility. Unifying the visuals must not flatten the
 * semantics, because these surfaces are not all the same thing:
 *
 * - `tabs` is for switching between structurally different panels, and per the
 *   WAI-ARIA tabs pattern each tab must point at the panel it controls. Callers
 *   pass `panelId` and render that panel with `role="tabpanel"`.
 * - `radiogroup` is for choosing one of a set of mutually exclusive options —
 *   a filter or a view switch — where the surrounding container stays put and
 *   only its contents change. There is no panel to control, and announcing
 *   these as tabs would promise a panel relationship that does not exist.
 *
 * Keyboard behaviour is identical either way: roving tabIndex plus arrow-key
 * traversal, which both patterns specify.
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
} & (
  | {
      /** Switches structurally different panels; requires the panel's id. */
      semantics: Extract<SegmentedSemantics, 'tabs'>;
      panelId: string;
    }
  | {
      /** Picks one of a set of mutually exclusive options. */
      semantics: Extract<SegmentedSemantics, 'radiogroup'>;
      panelId?: never;
    }
);

export function SegmentedControl<T extends string>({
  ariaLabel,
  options,
  value,
  onChange,
  layout = 'fill',
  emphasis = 'default',
  className,
  semantics,
  panelId,
}: SegmentedControlProps<T>) {
  const itemRefs = useRef(new Map<T, HTMLButtonElement | null>());

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
      {...segmentedContainerAttributes(semantics)}
    >
      {options.map((option) => {
        const selected = option.value === value;
        return (
          <button
            className={selected ? 'active' : undefined}
            key={option.value}
            onClick={() => onChange(option.value)}
            onKeyDown={(event) => handleKeyDown(event, option.value)}
            ref={(node) => {
              itemRefs.current.set(option.value, node);
            }}
            type="button"
            {...segmentedItemAttributes(semantics, selected, panelId)}
          >
            {option.icon ?? null}
            {option.label}
          </button>
        );
      })}
    </div>
  );
}
