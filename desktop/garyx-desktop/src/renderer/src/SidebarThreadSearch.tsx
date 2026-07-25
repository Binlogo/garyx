import type { RefObject } from "react";
import { Search } from "lucide-react";

import { recentFeedFooter } from "./recent-feed-footer";
import {
  ThreadRailList,
  type ThreadRailRow,
} from "./ThreadRailList";
import { useI18n } from "./i18n";
import type { ThreadSearchPresentation } from "./app-shell/thread-search-model";

type SidebarThreadSearchFieldProps = {
  inputRef: RefObject<HTMLInputElement | null>;
  query: string;
  onChange: (query: string) => void;
  onClear: () => void;
  onFocus: () => void;
  onBlur: () => void;
};

export function SidebarThreadSearchField({
  inputRef,
  query,
  onChange,
  onClear,
  onFocus,
  onBlur,
}: SidebarThreadSearchFieldProps) {
  const { t } = useI18n();

  return (
    <div className="sidebar-thread-search" role="search">
      <Search aria-hidden size={15} strokeWidth={1.8} />
      <input
        aria-label={t("Search threads by name")}
        autoComplete="off"
        className="sidebar-thread-search-input"
        onBlur={onBlur}
        onChange={(event) => {
          onChange(event.currentTarget.value);
        }}
        onFocus={onFocus}
        onKeyDown={(event) => {
          if (event.key !== "Escape") {
            return;
          }
          event.preventDefault();
          event.stopPropagation();
          onClear();
        }}
        placeholder={t("Search...")}
        ref={inputRef}
        spellCheck={false}
        type="search"
        value={query}
      />
    </div>
  );
}

type SidebarThreadSearchResultsProps = {
  formatThreadTimestamp: (value?: string | null) => string;
  onLoadMore: () => void;
  onRetry: () => void;
  presentation: ThreadSearchPresentation;
  rows: ThreadRailRow[];
};

export function SidebarThreadSearchResults({
  formatThreadTimestamp,
  onLoadMore,
  onRetry,
  presentation,
  rows,
}: SidebarThreadSearchResultsProps) {
  const { t } = useI18n();
  const emptyLabel =
    presentation.kind === "prompt"
      ? t("Search threads by name")
      : presentation.kind === "empty"
        ? t('No threads named "{query}"', { query: presentation.query })
        : undefined;

  return (
    <div
      className="sidebar-thread-search-results"
      data-thread-search-state={presentation.kind}
    >
      <ThreadRailList
        className="sidebar-thread-search-rows"
        emptyLabel={emptyLabel}
        formatThreadTimestamp={formatThreadTimestamp}
        listFooter={recentFeedFooter({
          kind: presentation.footerKind,
          onRetry,
          t,
        })}
        onNearListEnd={
          presentation.kind === "results" && presentation.canLoadMore
            ? onLoadMore
            : undefined
        }
        rowClassName="recent-conversation-row-shell"
        rows={rows}
      />
    </div>
  );
}
