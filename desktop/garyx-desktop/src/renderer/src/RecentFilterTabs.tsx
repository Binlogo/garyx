import {
  recentThreadFilterLabel,
  type RecentThreadFilter,
} from "./app-shell/recent-thread-feeds";
import { SegmentedControl } from "./components/SegmentedControl";
import { useI18n } from "./i18n";

/**
 * The All / Chats / Favorites segmented control for the recent thread feed.
 *
 * Owned by the L2 recent rail. The sidebar's Threads tab deliberately has no
 * filter row — that surface IS the Chats feed.
 *
 * This array is the single source of order: arrow-key traversal follows the
 * options it produces, so there is no second ordering constant to keep in sync.
 */
const FILTERS: RecentThreadFilter[] = ["nonTask", "all", "favorites"];

type RecentFilterTabsProps = {
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

  return (
    <SegmentedControl
      ariaLabel={t("Recent filter")}
      className={`recent-filter-tabs ${className ?? ""}`.trim()}
      onChange={onSelectFilter}
      options={FILTERS.map((filter) => ({
        value: filter,
        label: t(recentThreadFilterLabel(filter)),
      }))}
      value={selectedFilter}
    />
  );
}
