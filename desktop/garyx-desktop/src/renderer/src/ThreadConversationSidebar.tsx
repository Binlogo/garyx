import { type PointerEvent as ReactPointerEvent, type ReactNode } from 'react';
import { PanelLeftClose } from 'lucide-react';

import { ThreadRailList, type ThreadRailRow } from './ThreadRailList';

export type { ThreadRailRow } from './ThreadRailList';

type ThreadConversationSidebarProps = {
  ariaLabel: string;
  /** Extra modifier appended to the shared `bot-conversation-rail` shell. */
  className?: string;
  /** Fully-formed logo node (caller owns any wrapper/styling). */
  logo?: ReactNode;
  title: string;
  titleTooltip?: string;
  collapseLabel: string;
  /** Shown when there are no rows. Omit to render an empty list silently. */
  emptyLabel?: string;
  /** Optional domain-owned control rendered between the title and list. */
  headerAccessory?: ReactNode;
  /** Optional domain-owned footer rendered inside the shared scroll area. */
  listFooter?: ReactNode;
  /** Called when the shared scroll area reaches its near-tail threshold. */
  onNearListEnd?: () => void;
  rowClassName?: string;
  rows: ThreadRailRow[];
  formatThreadTimestamp: (value?: string | null) => string;
  onClose: () => void;
  onRailResizeStart?: (event: ReactPointerEvent<HTMLDivElement>) => void;
  railResizing?: boolean;
};

/**
 * Shared secondary "thread list" rail behind Workspaces, Bots, and Recent.
 * Each caller maps its data into {@link ThreadRailRow}s. This shell owns the
 * L2 rail chrome — logo, title, collapse control, resizer — and delegates the
 * scrollable rows to {@link ThreadRailList}, which the L1 sidebar Threads tab
 * composes without any of this chrome.
 */
export function ThreadConversationSidebar({
  ariaLabel,
  className,
  logo,
  title,
  titleTooltip,
  collapseLabel,
  emptyLabel,
  headerAccessory,
  listFooter,
  onNearListEnd,
  rowClassName,
  rows,
  formatThreadTimestamp,
  onClose,
  onRailResizeStart,
  railResizing,
}: ThreadConversationSidebarProps) {
  return (
    <aside aria-label={ariaLabel} className={`bot-conversation-rail ${className ?? ''}`.trim()}>
      <div className="bot-conversation-header">
        <div className="bot-conversation-heading">
          {logo ?? null}
          <div className="bot-conversation-title-copy">
            <div className="bot-conversation-title" title={titleTooltip ?? title}>
              {title}
            </div>
          </div>
        </div>
        <button
          aria-label={collapseLabel}
          className="bot-conversation-collapse"
          onClick={onClose}
          title={collapseLabel}
          type="button"
        >
          <PanelLeftClose aria-hidden size={15} strokeWidth={1.8} />
        </button>
      </div>

      {headerAccessory ?? null}

      <ThreadRailList
        emptyLabel={emptyLabel}
        formatThreadTimestamp={formatThreadTimestamp}
        listFooter={listFooter}
        onNearListEnd={onNearListEnd}
        rowClassName={rowClassName}
        rows={rows}
      />

      {onRailResizeStart ? (
        <div
          className={`sidebar-resizer ${railResizing ? 'is-resizing' : ''}`}
          onPointerDown={onRailResizeStart}
        >
          <div className="sidebar-resizer-line" />
        </div>
      ) : null}
    </aside>
  );
}
