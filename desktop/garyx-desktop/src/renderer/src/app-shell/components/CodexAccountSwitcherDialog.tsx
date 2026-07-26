import { Plus } from "lucide-react";

import type {
  DesktopCodexAccount,
  DesktopCodexAccounts,
} from "@shared/contracts";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";

import { useI18n } from "../../i18n";
import { usageResetText } from "../../provider-usage";
import { classNames } from "../../settings/shared";
import {
  providerUsageWindows,
  renderUsageMeter,
  unavailableUsageText,
} from "./provider-account-quota";

type CodexAccountSwitcherDialogProps = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  accounts: DesktopCodexAccounts | null;
  loading: boolean;
  error: string | null;
  mutationId: string | null;
  onSelect: (account: DesktopCodexAccount) => void | Promise<unknown>;
  onAdd?: () => void;
  onReauthenticate?: (account: DesktopCodexAccount) => void;
  onRename?: (account: DesktopCodexAccount) => void;
  onDelete?: (account: DesktopCodexAccount) => void;
  description?: string;
};

/**
 * App-centered Codex account selector, structurally identical to the Claude
 * switcher: every candidate shows its own quota evidence before selection,
 * and management actions stay per-row.
 */
export function CodexAccountSwitcherDialog({
  open,
  onOpenChange,
  accounts,
  loading,
  error,
  mutationId,
  onSelect,
  onAdd,
  onReauthenticate,
  onRename,
  onDelete,
  description,
}: CodexAccountSwitcherDialogProps) {
  const { t } = useI18n();
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="provider-account-dialog" size="form">
        <DialogHeader>
          <DialogTitle>{t("Codex accounts")}</DialogTitle>
          <DialogDescription>
            {description || t("Choose the account for new Codex runs.")}
          </DialogDescription>
        </DialogHeader>
        <div className="provider-account-dialog-body">
          {error ? <div className="provider-account-error">{error}</div> : null}
          {loading && !accounts ? (
            <div className="provider-account-loading">{t("Loading accounts…")}</div>
          ) : null}
          <div className="codex-list-card provider-account-list">
            {(accounts?.accounts || []).map((account) => {
              const accountKey = account.id || "system";
              const windows = providerUsageWindows(account.usage, t);
              return (
                <div
                  className={classNames(
                    "provider-account-option",
                    account.selected && "is-selected",
                  )}
                  key={accountKey}
                >
                  <label className="provider-account-choice">
                    <input
                      aria-label={
                        account.selected
                          ? t("Current account: {name}", { name: account.name })
                          : t("Use account: {name}", { name: account.name })
                      }
                      checked={account.selected}
                      className="provider-account-radio"
                      disabled={Boolean(mutationId)}
                      name="codex-account"
                      onChange={() => {
                        if (!account.selected) void onSelect(account);
                      }}
                      type="radio"
                    />
                    <div className="provider-account-option-content">
                      <div className="provider-account-option-header">
                        <div className="provider-account-option-copy">
                          <div>
                            <strong>{account.name}</strong>
                            {account.selected ? (
                              <Badge variant="outline">{t("Current")}</Badge>
                            ) : null}
                            {account.plan ? (
                              <Badge variant="outline">{account.plan}</Badge>
                            ) : null}
                          </div>
                          <span>
                            {account.email
                              || (account.systemDefault
                                ? t("This Mac’s default Codex login")
                                : t("Added to Garyx"))}
                          </span>
                        </div>
                        {mutationId === accountKey ? <span>{t("Switching…")}</span> : null}
                      </div>
                      <div className="provider-account-option-meters">
                        {account.usage.available && windows.length > 0 ? (
                          windows.map((entry) => (
                            <div key={entry.key}>
                              {renderUsageMeter(
                                entry.label,
                                entry.value.remainingPercent,
                                usageResetText(
                                  entry.value.resetsAt,
                                  entry.value.resetAfterSeconds,
                                  entry.fallback,
                                ),
                                account.usage.stale,
                              )}
                            </div>
                          ))
                        ) : (
                          <span className="provider-card-empty">
                            {unavailableUsageText(account.usage, t)}
                          </span>
                        )}
                      </div>
                    </div>
                  </label>
                  {onReauthenticate || (!account.systemDefault && (onRename || onDelete)) ? (
                    <div className="provider-account-option-actions">
                      {onReauthenticate ? (
                        <button onClick={() => onReauthenticate(account)} type="button">
                          {t("Sign in again")}
                        </button>
                      ) : null}
                      {!account.systemDefault && onRename ? (
                        <button onClick={() => onRename(account)} type="button">
                          {t("Rename")}
                        </button>
                      ) : null}
                      {!account.systemDefault && onDelete ? (
                        <button
                          className="destructive"
                          onClick={() => onDelete(account)}
                          type="button"
                        >
                          {t("Delete")}
                        </button>
                      ) : null}
                    </div>
                  ) : null}
                </div>
              );
            })}
          </div>
        </div>
        {onAdd ? (
          <DialogFooter>
            <Button onClick={onAdd} type="button">
              <Plus aria-hidden size={14} strokeWidth={2} />
              {t("Add Codex account")}
            </Button>
          </DialogFooter>
        ) : null}
      </DialogContent>
    </Dialog>
  );
}
