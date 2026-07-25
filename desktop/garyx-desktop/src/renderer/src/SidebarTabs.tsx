import { useRef, type KeyboardEvent } from 'react';

import { useI18n } from './i18n';
import {
  SIDEBAR_TABS,
  sidebarTabForArrowKey,
  sidebarTabLabel,
  type SidebarTab,
} from './sidebar-tab-model';

type SidebarTabsProps = {
  onSelectTab: (tab: SidebarTab) => void;
  selectedTab: SidebarTab;
};

/**
 * The L1 sidebar's Threads / Projects segmented control. Pinned threads sit
 * above this control and belong to neither tab.
 */
export function SidebarTabs({ onSelectTab, selectedTab }: SidebarTabsProps) {
  const { t } = useI18n();
  const tabRefs = useRef<Record<SidebarTab, HTMLButtonElement | null>>({
    threads: null,
    projects: null,
  });

  function handleTabKeyDown(
    event: KeyboardEvent<HTMLButtonElement>,
    tab: SidebarTab,
  ) {
    if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') {
      return;
    }
    event.preventDefault();
    const nextTab = sidebarTabForArrowKey(tab, event.key);
    onSelectTab(nextTab);
    tabRefs.current[nextTab]?.focus();
  }

  return (
    <div aria-label={t('Sidebar sections')} className="sidebar-tabs" role="tablist">
      {SIDEBAR_TABS.map((tab) => {
        const selected = tab === selectedTab;
        return (
          <button
            aria-selected={selected}
            className={selected ? 'active' : undefined}
            key={tab}
            onClick={() => onSelectTab(tab)}
            onKeyDown={(event) => handleTabKeyDown(event, tab)}
            ref={(node) => {
              tabRefs.current[tab] = node;
            }}
            role="tab"
            tabIndex={selected ? 0 : -1}
            type="button"
          >
            {t(sidebarTabLabel(tab))}
          </button>
        );
      })}
    </div>
  );
}
