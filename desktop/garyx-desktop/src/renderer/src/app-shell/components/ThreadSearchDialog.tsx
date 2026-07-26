import {
  useEffect,
  useRef,
  useState,
  type KeyboardEvent,
} from "react";
import { LoaderCircle, Search } from "lucide-react";

import type { DesktopThreadSummary } from "@shared/contracts";

import { AgentOptionAvatar } from "./AgentOptionAvatar";
import { Button } from "../../components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogTitle,
} from "../../components/ui/dialog";
import { Input } from "../../components/ui/input";
import { useI18n } from "../../i18n";
import {
  resolveThreadAvatarIdentity,
  type ThreadAvatarCatalog,
} from "../../thread-avatar";
import {
  threadSearchHighlightedItem,
  threadSearchHighlightForRows,
  moveThreadSearchHighlight,
  type ThreadSearchPresentation,
} from "../thread-search-model";

const THREAD_SEARCH_NEAR_END_PX = 160;

type ThreadSearchDialogProps = {
  formatThreadTimestamp: (value?: string | null) => string;
  onClose: () => void;
  onLoadMore: () => void;
  onOpenThread: (threadId: string) => void;
  onQueryChange: (query: string) => void;
  onRetry: () => void;
  open: boolean;
  presentation: ThreadSearchPresentation;
  query: string;
  rows: DesktopThreadSummary[];
  threadAvatarCatalog: ThreadAvatarCatalog;
};

type ThreadSearchResultRowProps = {
  formatThreadTimestamp: (value?: string | null) => string;
  highlighted: boolean;
  index: number;
  onHighlight: (index: number) => void;
  onOpen: (threadId: string) => void;
  rowRef: (node: HTMLButtonElement | null) => void;
  thread: DesktopThreadSummary;
  threadAvatarCatalog: ThreadAvatarCatalog;
};

function isNearListEnd(
  element: Pick<HTMLElement, "clientHeight" | "scrollHeight" | "scrollTop">,
): boolean {
  return (
    element.scrollHeight - element.scrollTop - element.clientHeight <=
    THREAD_SEARCH_NEAR_END_PX
  );
}

function ThreadSearchResultRow({
  formatThreadTimestamp,
  highlighted,
  index,
  onHighlight,
  onOpen,
  rowRef,
  thread,
  threadAvatarCatalog,
}: ThreadSearchResultRowProps) {
  const { t } = useI18n();
  const avatar = resolveThreadAvatarIdentity(thread, threadAvatarCatalog);
  const workspacePath = thread.workspacePath?.trim() || "";
  const workspaceLabel =
    thread.workspaceOrigin === "implicit" || !workspacePath
      ? t("No workspace")
      : workspacePath;
  const timeLabel = formatThreadTimestamp(thread.updatedAt);

  return (
    <button
      aria-label={t("Open {name} thread", { name: thread.title })}
      aria-selected={highlighted}
      className={`thread-search-result-row ${highlighted ? "highlighted" : ""}`}
      data-thread-id={thread.id}
      id={`thread-search-result-${index}`}
      onClick={() => {
        onOpen(thread.id);
      }}
      onMouseDown={(event) => {
        event.preventDefault();
      }}
      onMouseEnter={() => {
        onHighlight(index);
      }}
      ref={rowRef}
      role="option"
      tabIndex={-1}
      type="button"
    >
      <AgentOptionAvatar
        agentId={avatar.agentId}
        avatarDataUrl={avatar.avatarDataUrl}
        className="thread-search-result-avatar"
        kind={avatar.kind}
        label={avatar.label}
        providerIcon={avatar.providerIcon}
        providerType={avatar.providerType}
        size="default"
      />
      <span className="thread-search-result-copy">
        <span className="thread-search-result-title" title={thread.title}>
          {thread.title}
        </span>
        <span className="thread-search-result-meta">
          <span className="thread-search-result-agent">{avatar.label}</span>
          <span aria-hidden className="thread-search-result-separator">
            ·
          </span>
          <span
            className="thread-search-result-workspace"
            title={workspaceLabel}
          >
            {workspaceLabel}
          </span>
        </span>
      </span>
      {timeLabel ? (
        <time
          className="thread-search-result-time"
          dateTime={thread.updatedAt}
          title={new Date(thread.updatedAt).toLocaleString()}
        >
          {timeLabel}
        </time>
      ) : null}
    </button>
  );
}

export function ThreadSearchDialog({
  formatThreadTimestamp,
  onClose,
  onLoadMore,
  onOpenThread,
  onQueryChange,
  onRetry,
  open,
  presentation,
  query,
  rows,
  threadAvatarCatalog,
}: ThreadSearchDialogProps) {
  const { t } = useI18n();
  const inputRef = useRef<HTMLInputElement | null>(null);
  const listRef = useRef<HTMLDivElement | null>(null);
  const rowRefs = useRef<Array<HTMLButtonElement | null>>([]);
  const [highlightedIndex, setHighlightedIndex] = useState(-1);

  useEffect(() => {
    setHighlightedIndex((current) =>
      threadSearchHighlightForRows(current, rows.length),
    );
    rowRefs.current.length = rows.length;
  }, [rows.length]);

  useEffect(() => {
    if (!open || highlightedIndex < 0) {
      return;
    }
    rowRefs.current[highlightedIndex]?.scrollIntoView({ block: "nearest" });
  }, [highlightedIndex, open]);

  useEffect(() => {
    const list = listRef.current;
    if (
      open &&
      presentation.kind === "results" &&
      presentation.canLoadMore &&
      list &&
      isNearListEnd(list)
    ) {
      onLoadMore();
    }
  }, [
    onLoadMore,
    open,
    presentation.canLoadMore,
    presentation.kind,
    rows.length,
  ]);

  function handleInputKeyDown(event: KeyboardEvent<HTMLInputElement>) {
    if (event.nativeEvent.isComposing) {
      return;
    }
    if (event.key === "ArrowDown") {
      event.preventDefault();
      setHighlightedIndex((current) =>
        moveThreadSearchHighlight(current, rows.length, "next"),
      );
      return;
    }
    if (event.key === "ArrowUp") {
      event.preventDefault();
      setHighlightedIndex((current) =>
        moveThreadSearchHighlight(current, rows.length, "previous"),
      );
      return;
    }
    if (
      event.key === "Enter" &&
      !event.metaKey &&
      !event.ctrlKey &&
      !event.altKey
    ) {
      const selected = threadSearchHighlightedItem(rows, highlightedIndex);
      if (!selected) {
        return;
      }
      event.preventDefault();
      onOpenThread(selected.id);
    }
  }

  const activeDescendant =
    highlightedIndex >= 0 && highlightedIndex < rows.length
      ? `thread-search-result-${highlightedIndex}`
      : undefined;

  return (
    <Dialog
      onOpenChange={(nextOpen) => {
        if (!nextOpen) {
          onClose();
        }
      }}
      open={open}
    >
      <DialogContent
        className="thread-search-dialog"
        data-testid="thread-search-dialog"
        onOpenAutoFocus={(event) => {
          event.preventDefault();
          inputRef.current?.focus();
        }}
        showCloseButton={false}
      >
        <DialogTitle className="sr-only">{t("Search threads")}</DialogTitle>
        <DialogDescription className="sr-only">
          {t("Search threads by name")}
        </DialogDescription>

        <div className="thread-search-input-shell" role="search">
          <Search aria-hidden size={21} strokeWidth={1.8} />
          <Input
            aria-activedescendant={activeDescendant}
            aria-autocomplete="list"
            aria-controls="thread-search-results"
            aria-expanded={presentation.kind === "results"}
            aria-label={t("Search threads by name")}
            autoComplete="off"
            className="thread-search-input"
            onChange={(event) => {
              onQueryChange(event.currentTarget.value);
            }}
            onKeyDown={handleInputKeyDown}
            placeholder={t("Search threads by name")}
            ref={inputRef}
            role="combobox"
            spellCheck={false}
            type="text"
            value={query}
          />
        </div>

        <div
          className="thread-search-body"
          data-thread-search-state={presentation.kind}
        >
          {presentation.kind === "prompt" ? (
            <div className="thread-search-state" role="status">
              <Search aria-hidden size={24} strokeWidth={1.6} />
              <span>{t("Search threads by name")}</span>
            </div>
          ) : presentation.kind === "loading" ? (
            <div
              aria-live="polite"
              className="thread-search-state"
              role="status"
            >
              <LoaderCircle
                aria-hidden
                className="thread-search-state-spinner"
                size={24}
                strokeWidth={1.7}
              />
              <span>{t("Searching threads…")}</span>
            </div>
          ) : presentation.kind === "empty" ? (
            <div className="thread-search-state" role="status">
              <Search aria-hidden size={24} strokeWidth={1.6} />
              <span>
                {t('No threads named "{query}"', {
                  query: presentation.query,
                })}
              </span>
            </div>
          ) : presentation.kind === "failed" ? (
            <div className="thread-search-state" role="alert">
              <span>{t("Thread search unavailable")}</span>
              <Button onClick={onRetry} size="sm" type="button" variant="outline">
                {t("Retry")}
              </Button>
            </div>
          ) : (
            <div
              aria-label={t("Thread search results")}
              className="thread-search-results"
              id="thread-search-results"
              onScroll={(event) => {
                if (
                  presentation.canLoadMore &&
                  isNearListEnd(event.currentTarget)
                ) {
                  onLoadMore();
                }
              }}
              ref={listRef}
              role="listbox"
            >
              {rows.map((thread, index) => (
                <ThreadSearchResultRow
                  formatThreadTimestamp={formatThreadTimestamp}
                  highlighted={index === highlightedIndex}
                  index={index}
                  key={thread.id}
                  onHighlight={setHighlightedIndex}
                  onOpen={onOpenThread}
                  rowRef={(node) => {
                    rowRefs.current[index] = node;
                  }}
                  thread={thread}
                  threadAvatarCatalog={threadAvatarCatalog}
                />
              ))}
              {presentation.footerKind === "loadingMore" ? (
                <div
                  aria-live="polite"
                  className="thread-search-results-footer"
                  role="status"
                >
                  <LoaderCircle
                    aria-hidden
                    className="thread-search-state-spinner"
                    size={16}
                    strokeWidth={1.7}
                  />
                  <span>{t("Loading more")}</span>
                </div>
              ) : presentation.footerKind === "loadMoreFailure" ? (
                <div className="thread-search-results-footer" role="alert">
                  <Button
                    onClick={onRetry}
                    size="sm"
                    type="button"
                    variant="outline"
                  >
                    {t("Couldn't load more · Retry")}
                  </Button>
                </div>
              ) : null}
            </div>
          )}
        </div>
      </DialogContent>
    </Dialog>
  );
}
