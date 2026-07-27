import type { ReactNode } from "react";

import type { DesktopProviderUsage, DesktopUsageWindow } from "@shared/contracts";

import type { Translate } from "../../i18n";
import {
  clampUsagePercent,
  formatUsageDuration,
  formatUsagePercent,
  usageLevelForRemainingPercent,
} from "../../provider-usage";

/**
 * Shared per-account quota presentation for the provider account switcher
 * dialogs (Claude Code and Codex): identical window ordering, unavailable
 * copy, and compact meter markup for every candidate account.
 */
export function providerUsageWindows(
  usage: DesktopProviderUsage,
  t: Translate,
): Array<{ key: string; label: string; value: DesktopUsageWindow; fallback: string }> {
  const windows = [] as Array<{
    key: string;
    label: string;
    value: DesktopUsageWindow;
    fallback: string;
  }>;
  if (usage.session) {
    windows.push({
      key: "session",
      label: t("Session"),
      value: usage.session,
      fallback: t("session window"),
    });
  }
  if (usage.weekly) {
    windows.push({
      key: "weekly",
      label: t("Weekly"),
      value: usage.weekly,
      fallback: t("weekly window"),
    });
  }
  for (const limit of usage.scopedLimits) {
    windows.push({
      key: `scoped:${limit.id}`,
      label: limit.name,
      value: limit.window,
      fallback: limit.kind.includes("weekly") ? t("weekly window") : t("usage window"),
    });
  }
  return windows;
}

export function unavailableUsageText(usage: DesktopProviderUsage, t: Translate): string {
  switch (usage.errorCode) {
    case "rate_limited":
      return usage.retryAfterSeconds && usage.retryAfterSeconds > 0
        ? t("Try again in {age}", { age: formatUsageDuration(usage.retryAfterSeconds) })
        : t("Quota temporarily rate limited");
    case "reauth_required":
      return t("Sign in again to refresh quota");
    case "credentials_unavailable":
      return t("Account credentials unavailable");
    case "network":
      return t("Quota refresh failed — check connection");
    default:
      return t("Quota temporarily unavailable");
  }
}

export function renderUsageMeter(
  label: string,
  remainingPercent: number,
  caption: string,
  stale: boolean,
): ReactNode {
  const percent = clampUsagePercent(remainingPercent);
  return (
    <div
      className="provider-usage-meter compact"
      data-level={usageLevelForRemainingPercent(percent)}
      data-stale={stale ? "true" : undefined}
    >
      <div className="provider-usage-meter-header">
        <span className="provider-usage-meter-label">{label}</span>
        <span className="provider-usage-meter-percent">{formatUsagePercent(percent)}</span>
      </div>
      <div className="provider-usage-meter-track" aria-hidden>
        <span className="provider-usage-meter-fill" style={{ width: `${percent}%` }} />
      </div>
      {caption ? <div className="provider-usage-meter-caption">{caption}</div> : null}
    </div>
  );
}
