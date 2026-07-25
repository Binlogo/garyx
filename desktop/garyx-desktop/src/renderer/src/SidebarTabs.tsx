import { SegmentedControl } from './components/SegmentedControl';
import { useI18n } from './i18n';
import {
  SIDEBAR_TABS,
  SIDEBAR_TAB_PANEL_ID,
  sidebarTabLabel,
  type SidebarTab,
} from './sidebar-tab-model';

type SidebarTabsProps = {
  onSelectTab: (tab: SidebarTab) => void;
  selectedTab: SidebarTab;
};

/**
 * The L1 sidebar's Threads / Projects switch. Pinned threads sit above this
 * control and belong to neither tab.
 */
export function SidebarTabs({ onSelectTab, selectedTab }: SidebarTabsProps) {
  const { t } = useI18n();

  return (
    <SegmentedControl
      ariaLabel={t('Sidebar sections')}
      className="sidebar-tabs"
      emphasis="strong"
      onChange={onSelectTab}
      panelId={SIDEBAR_TAB_PANEL_ID}
      semantics="tabs"
      options={SIDEBAR_TABS.map((tab) => ({
        value: tab,
        label: t(sidebarTabLabel(tab)),
      }))}
      value={selectedTab}
    />
  );
}
