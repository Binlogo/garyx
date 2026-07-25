import { type ReactNode, useEffect, useRef, useState } from 'react';
import { Archive, StarOff } from 'lucide-react';

import { AgentOptionAvatar } from './app-shell/components/AgentOptionAvatar';
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from './components/ui/tooltip';
import { useI18n } from './i18n';
import type { ThreadAvatarIdentity } from './thread-avatar';
import { threadRailIsNearListEnd } from './thread-conversation-sidebar-model';

export type ThreadRailRow = {
  /** Stable React key and inline-confirm key. */
  key: string;
  title: string;
  titleTooltip?: string;
  time?: string | null;
  avatar?: ThreadAvatarIdentity | null;
  /** Translation key for an inline status badge (e.g. bot thread state). */
  badge?: string | null;
  isActive: boolean;
  isBusy?: boolean;
  /** Defaults to true; when false the row is rendered disabled. */
  openable?: boolean;
  onOpen: () => void;
  /** Per-row archive handler. Omit to render the row without an action. */
  onArchive?: () => void;
  /** Favorites-only immediate removal action, rendered before Archive. */
  onUnfavorite?: () => void;
};

type ThreadRailListProps = {
  /** Extra modifier appended to the shared `bot-conversation-list` recipe. */
  className?: string;
  /** Shown when there are no rows. Omit to render an empty list silently. */
  emptyLabel?: string;
  /** Optional domain-owned footer rendered inside the shared scroll area. */
  listFooter?: ReactNode;
  /** Called when the scroll area reaches its near-tail threshold. */
  onNearListEnd?: () => void;
  rowClassName?: string;
  rows: ThreadRailRow[];
  formatThreadTimestamp: (value?: string | null) => string;
};

/**
 * Scrollable thread-row list shared by every rail-style thread surface: the L2
 * bot/workspace drilldown rail, the L2 recent rail, and the L1 sidebar Threads
 * tab. Owns row rendering, the inline archive confirm, and near-tail paging
 * detection. It deliberately owns no header, title, collapse control, or
 * resizer — that chrome belongs to whichever shell composes this list.
 */
export function ThreadRailList({
  className,
  emptyLabel,
  listFooter,
  onNearListEnd,
  rowClassName,
  rows,
  formatThreadTimestamp,
}: ThreadRailListProps) {
  const { t } = useI18n();
  const [confirmKey, setConfirmKey] = useState<string | null>(null);
  const confirmTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const listRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (!confirmKey) {
      return;
    }
    confirmTimerRef.current = setTimeout(() => {
      setConfirmKey(null);
    }, 3000);
    return () => {
      if (confirmTimerRef.current) {
        clearTimeout(confirmTimerRef.current);
      }
    };
  }, [confirmKey]);

  useEffect(() => {
    const list = listRef.current;
    if (onNearListEnd && list && threadRailIsNearListEnd(list)) {
      onNearListEnd();
    }
  }, [listFooter, onNearListEnd, rows.length]);

  return (
    <TooltipProvider>
      <div
        className={`bot-conversation-list ${className ?? ''}`.trim()}
        onScroll={(event) => {
          if (onNearListEnd && threadRailIsNearListEnd(event.currentTarget)) {
            onNearListEnd();
          }
        }}
        ref={listRef}
      >
        {rows.length ? (
          rows.map((row) => {
            const hasAction = Boolean(row.onArchive || row.onUnfavorite);
            const isConfirming = confirmKey === row.key;
            const openable = row.openable !== false;
            return (
              <div
                className={`bot-conversation-row-shell ${rowClassName ?? ''} ${row.isActive ? 'active' : ''} ${hasAction ? '' : 'no-delete'}`
                  .replace(/\s+/g, ' ')
                  .trim()}
                key={row.key}
                onMouseLeave={() => {
                  if (confirmKey === row.key) {
                    setConfirmKey(null);
                  }
                }}
              >
                <button
                  aria-current={row.isActive ? 'page' : undefined}
                  className={`bot-conversation-row ${row.avatar ? 'with-avatar' : ''}`.trim()}
                  disabled={!openable}
                  onClick={() => {
                    if (openable) {
                      row.onOpen();
                    }
                  }}
                  type="button"
                >
                  {row.avatar ? (
                    <span className="thread-row-avatar-wrap">
                      <AgentOptionAvatar
                        agentId={row.avatar.agentId}
                        avatarDataUrl={row.avatar.avatarDataUrl}
                        className="thread-row-agent-avatar"
                        kind={row.avatar.kind}
                        label={row.avatar.label}
                        providerIcon={row.avatar.providerIcon}
                        providerType={row.avatar.providerType}
                        size="default"
                      />
                      {row.isBusy ? (
                        <span aria-label={t('Loading')} className="thread-row-typing-badge" role="status">
                          <span />
                          <span />
                          <span />
                        </span>
                      ) : null}
                    </span>
                  ) : null}
                  <div className="bot-conversation-row-main">
                    <span className="bot-conversation-row-title" title={row.titleTooltip ?? row.title}>
                      {row.title}
                    </span>
                    {row.badge ? <span className="bot-thread-badge">{t(row.badge)}</span> : null}
                  </div>
                  <span className="bot-conversation-row-time">{formatThreadTimestamp(row.time)}</span>
                </button>
                {hasAction ? (
                  <>
                    {row.onUnfavorite && !isConfirming ? (
                      <Tooltip>
                        <TooltipTrigger asChild>
                          <button
                            aria-label={t('Unfavorite conversation')}
                            className="thread-delete-button thread-unfavorite-button"
                            onClick={(event) => {
                              event.stopPropagation();
                              row.onUnfavorite?.();
                            }}
                            tabIndex={-1}
                            type="button"
                          >
                            <StarOff aria-hidden />
                          </button>
                        </TooltipTrigger>
                        <TooltipContent>{t('Unfavorite conversation')}</TooltipContent>
                      </Tooltip>
                    ) : null}
                    {row.onArchive ? (
                      isConfirming ? (
                        <button
                          aria-label={t('Confirm archive {name}', { name: row.title })}
                          className="thread-delete-button confirm"
                          style={{ opacity: 1, pointerEvents: 'auto' }}
                          onClick={(event) => {
                            event.stopPropagation();
                            setConfirmKey(null);
                            row.onArchive?.();
                          }}
                          tabIndex={-1}
                          type="button"
                        >
                          {t('Confirm')}
                        </button>
                      ) : (
                        <Tooltip>
                          <TooltipTrigger asChild>
                            <button
                              aria-label={t('Archive {name}', { name: row.title })}
                              className="thread-delete-button"
                              onClick={(event) => {
                                event.stopPropagation();
                                setConfirmKey(row.key);
                              }}
                              tabIndex={-1}
                              type="button"
                            >
                              <Archive aria-hidden />
                            </button>
                          </TooltipTrigger>
                          <TooltipContent>{t('Archive thread')}</TooltipContent>
                        </Tooltip>
                      )
                    ) : null}
                  </>
                ) : null}
              </div>
            );
          })
        ) : emptyLabel ? (
          <p className="workspace-empty-note">{emptyLabel}</p>
        ) : null}
        {listFooter ?? null}
      </div>
    </TooltipProvider>
  );
}
