import { useRef, type KeyboardEvent } from "react";

import {
  recentThreadFilterLabel,
  type RecentThreadFilter,
} from "./app-shell/recent-thread-feeds";
import { useI18n } from "./i18n";
import { recentFilterForArrowKey } from "./recent-conversation-sidebar-model";

/**
 * The All / Chats / Favorites segmented control for the recent thread feed.
 *
 * Shared by both recent surfaces — the L1 sidebar Threads tab and the L2
 * recent rail — so the accessible tablist semantics and arrow-key traversal
 * exist exactly once. A copy in each surface would drift.
 */

const FILTERS: RecentThreadFilter[] = ["nonTask", "all", "favorites"];

type RecentFilterTabsProps = {
  /** Extra modifier appended to the shared `recent-filter-tabs` recipe. */
  className?: string;
  onSelectFilter: (filter: RecentThreadFilter) => void;
  selectedFilter: RecentThreadFilter;
};

export function RecentFilterTabs({
  className,
  onSelectFilter,
  selectedFilter,
}: RecentFilterTabsProps) {
  const { t } = useI18n();
  const tabRefs = useRef<Record<RecentThreadFilter, HTMLButtonElement | null>>({
    all: null,
    nonTask: null,
    favorites: null,
  });

  function handleTabKeyDown(
    event: KeyboardEvent<HTMLButtonElement>,
    filter: RecentThreadFilter,
  ) {
    if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") {
      return;
    }
    event.preventDefault();
    const nextFilter = recentFilterForArrowKey(filter, event.key);
    onSelectFilter(nextFilter);
    tabRefs.current[nextFilter]?.focus();
  }

  return (
    <div
      aria-label={t("Recent filter")}
      className={`recent-filter-tabs ${className ?? ""}`.trim()}
      role="tablist"
    >
      {FILTERS.map((filter) => {
        const label = t(recentThreadFilterLabel(filter));
        const selected = filter === selectedFilter;
        return (
          <button
            aria-selected={selected}
            className={selected ? "active" : undefined}
            key={filter}
            onClick={() => onSelectFilter(filter)}
            onKeyDown={(event) => handleTabKeyDown(event, filter)}
            ref={(node) => {
              tabRefs.current[filter] = node;
            }}
            role="tab"
            tabIndex={selected ? 0 : -1}
            type="button"
          >
            {label}
          </button>
        );
      })}
    </div>
  );
}
