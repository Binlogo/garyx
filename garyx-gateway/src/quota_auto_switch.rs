//! Automatic provider-account switch on quota exhaustion.
//!
//! Design: docs/design/quota-auto-account-switch.md. When a rate-limited run
//! commits and its durable quota-recovery row is registered, this module
//! evaluates whether another configured account of the same provider still
//! has allowance and, if so, commits exactly one selection change through the
//! same guarded path the manual switcher uses. The committed switch's
//! ordinary side effects (provider-wide recovery wake) are what resume every
//! quota-paused thread — this module never invents its own wake mechanism.
//!
//! Evaluations are serialized per provider and are volatile by design: the
//! durable recovery rows keep their timer / manual / manual-switch wakes
//! regardless of whether an evaluation ran.

use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, OnceLock};

use futures_util::future::join_all;
use tokio::sync::Mutex;
use tracing::{debug, info, warn};

use crate::codex_provider_accounts;
use crate::coding_usage::{self, ProviderUsage};
use crate::garyx_db::{QuotaRecoveryJob, QuotaRecoveryState};
use crate::provider_accounts::{self, GuardedSwitchOutcome};
use crate::server::AppState;

/// Providers with managed account profiles. Everything else has no account
/// pool to switch within and never reaches an evaluation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AccountProvider {
    ClaudeCode,
    Codex,
}

impl AccountProvider {
    pub(crate) fn from_canonical(provider: &str) -> Option<Self> {
        match provider {
            "claude_code" => Some(Self::ClaudeCode),
            "codex_app_server" => Some(Self::Codex),
            _ => None,
        }
    }
}

/// Context extracted from one committed rate-limited generation.
#[derive(Debug, Clone)]
pub(crate) struct QuotaBlockContext {
    pub thread_id: String,
    pub provider: AccountProvider,
    /// Durable identity of the generation this evaluation belongs to. The
    /// evaluation re-validates it against SQLite after acquiring the
    /// per-provider queue: a row that settled or was superseded while queued
    /// must not act.
    pub job_id: String,
    pub blocked_run_id: String,
    /// Profile directory the blocked run launched with. The bridge emits an
    /// explicit directory for System default too (`~/.claude` / `~/.codex` or
    /// the ambient override), so `None` only means a pre-enrichment legacy
    /// event; the evaluation then assumes the blocked account is the current
    /// selection.
    pub account_dir: Option<String>,
    /// Model the blocked run was using, for scoped-bucket checks.
    pub model: Option<String>,
}

/// The blocked run's account identity after mapping `account_dir` against the
/// managed-account layout.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum BlockedAccount {
    Managed(String),
    /// A directory outside the managed root is the system/ambient profile.
    SystemDefault,
    /// The event carried no directory (older bridge); assume the current
    /// selection blocked.
    Unknown,
}

pub(crate) fn map_blocked_account(
    account_dir: Option<&str>,
    managed_ids: &[String],
    managed_dir_of: impl Fn(&str) -> std::path::PathBuf,
) -> BlockedAccount {
    let Some(dir) = account_dir.map(str::trim).filter(|value| !value.is_empty()) else {
        return BlockedAccount::Unknown;
    };
    let dir = Path::new(dir);
    for id in managed_ids {
        if managed_dir_of(id) == dir {
            return BlockedAccount::Managed(id.clone());
        }
    }
    BlockedAccount::SystemDefault
}

/// Minimum remaining percentage across every window the policy requires for
/// this account, or `None` when the account is not positively eligible. The
/// policy fails closed: an allowance the reading does not confirm is treated
/// as absent, never as unlimited.
///
/// - Unavailable or stale readings never qualify.
/// - Claude Code requires BOTH the 5-hour session window and the weekly
///   window, present with allowance left; a reading missing either window
///   cannot confirm the account and is ineligible. When the blocked model
///   belongs to a scoped family (`CLAUDE_SCOPED_MODEL_FAMILIES`, e.g. Fable),
///   the account must additionally expose a matching scoped bucket with
///   allowance — an account without the bucket is ineligible for that run.
/// - Codex requires the weekly window, present with allowance left; a
///   reported session window must also have allowance.
pub(crate) fn eligible_remaining(
    provider: AccountProvider,
    usage: &ProviderUsage,
    blocked_model: Option<&str>,
) -> Option<f64> {
    if !usage.available || usage.stale {
        return None;
    }
    let mut min_remaining = match provider {
        AccountProvider::ClaudeCode => {
            let session = usage.session.as_ref()?;
            let weekly = usage.weekly.as_ref()?;
            session.remaining_percent.min(weekly.remaining_percent)
        }
        AccountProvider::Codex => {
            let weekly = usage.weekly.as_ref()?;
            let mut min = weekly.remaining_percent;
            if let Some(session) = usage.session.as_ref() {
                min = min.min(session.remaining_percent);
            }
            min
        }
    };
    if provider == AccountProvider::ClaudeCode
        && let Some(model) = blocked_model
    {
        let model_lower = model.to_lowercase();
        let scoped_family = garyx_models::provider::CLAUDE_SCOPED_MODEL_FAMILIES
            .iter()
            .any(|family| model_lower.contains(family));
        if scoped_family {
            let mut matched = false;
            for scoped in &usage.scoped_limits {
                if scoped_limit_matches_model(&scoped.id, &scoped.name, &model_lower) {
                    matched = true;
                    min_remaining = min_remaining.min(scoped.window.remaining_percent);
                }
            }
            if !matched {
                return None;
            }
        }
    }
    (min_remaining > 0.0).then_some(min_remaining)
}

/// A scoped limit applies to the blocked run when the run's model contains
/// the limit's model scope: `claude-fable-5-...` matches the `Fable` bucket
/// via its display name or the `{kind}:{scope_id}` identity tail.
fn scoped_limit_matches_model(scoped_id: &str, scoped_name: &str, model_lower: &str) -> bool {
    let name = scoped_name.trim().to_lowercase();
    if !name.is_empty() && model_lower.contains(&name) {
        return true;
    }
    scoped_id
        .rsplit(':')
        .next()
        .map(|scope| scope.trim().to_lowercase())
        .filter(|scope| !scope.is_empty())
        .is_some_and(|scope| model_lower.contains(&scope))
}

/// One candidate account with its probed usage.
pub(crate) struct CandidateUsage {
    pub account_id: Option<String>,
    pub name: String,
    pub usage: ProviderUsage,
}

/// Pick the eligible candidate with the most headroom: maximum
/// minimum-remaining across required windows, ties broken by name then id so
/// concurrent evaluations agree on one target.
pub(crate) fn pick_best_candidate<'a>(
    provider: AccountProvider,
    candidates: &'a [CandidateUsage],
    blocked_model: Option<&str>,
) -> Option<&'a CandidateUsage> {
    let mut best: Option<(&CandidateUsage, f64)> = None;
    for candidate in candidates {
        let Some(remaining) = eligible_remaining(provider, &candidate.usage, blocked_model) else {
            continue;
        };
        let better = match &best {
            None => true,
            Some((current, current_remaining)) => {
                remaining > *current_remaining
                    || (remaining == *current_remaining
                        && (candidate.name.as_str(), candidate.account_id.as_deref())
                            < (current.name.as_str(), current.account_id.as_deref()))
            }
        };
        if better {
            best = Some((candidate, remaining));
        }
    }
    best.map(|(candidate, _)| candidate)
}

/// Register interest in one committed rate-limited generation. Fire-and-forget:
/// the evaluation runs on the per-provider queue and must never block the
/// event projection loop. Guards, in order:
/// - only a still-waiting row for the triggering run may enqueue;
/// - each generation is considered at most once per process — an event
///   replay (broadcast lag) of a still-waiting generation must not
///   re-evaluate it after conditions changed;
/// - the evaluation re-validates the row against SQLite after acquiring the
///   provider queue (see `evaluate`).
pub(crate) fn spawn_consideration(
    state: &Arc<AppState>,
    ctx: QuotaBlockContext,
    registered: &QuotaRecoveryJob,
) {
    if registered.state != QuotaRecoveryState::Waiting
        || registered.blocked_run_id != ctx.blocked_run_id
        || registered.job_id != ctx.job_id
    {
        return;
    }
    if !claim_generation_once(&ctx.job_id) {
        debug!(
            thread_id = %ctx.thread_id,
            job_id = %ctx.job_id,
            "quota auto-switch already considered this generation"
        );
        return;
    }
    let state = state.clone();
    tokio::spawn(async move {
        let queue = provider_queue(ctx.provider);
        let _serialized = queue.lock().await;
        evaluate(&state, ctx).await;
    });
}

/// Process-local once-per-generation claim. Bounded: the set is cleared when
/// it grows past a few thousand entries — at one entry per blocked run this
/// takes months, and losing dedup for ancient generations is harmless because
/// their rows have long settled and fail the SQLite re-validation anyway.
fn claim_generation_once(job_id: &str) -> bool {
    static SEEN: OnceLock<std::sync::Mutex<std::collections::HashSet<String>>> = OnceLock::new();
    let seen = SEEN.get_or_init(Default::default);
    let mut guard = seen.lock().expect("quota auto-switch dedup lock poisoned");
    if guard.len() > 4096 {
        guard.clear();
    }
    guard.insert(job_id.to_owned())
}

fn provider_queue(provider: AccountProvider) -> Arc<Mutex<()>> {
    static QUEUES: OnceLock<std::sync::Mutex<HashMap<&'static str, Arc<Mutex<()>>>>> =
        OnceLock::new();
    let key = match provider {
        AccountProvider::ClaudeCode => "claude_code",
        AccountProvider::Codex => "codex_app_server",
    };
    let queues = QUEUES.get_or_init(Default::default);
    let mut guard = queues
        .lock()
        .expect("quota auto-switch queue lock poisoned");
    guard.entry(key).or_default().clone()
}

async fn evaluate(state: &Arc<AppState>, ctx: QuotaBlockContext) {
    // Re-validate the generation now that we own the provider queue: while
    // this evaluation waited, the row may have been claimed by the recovery
    // worker, superseded by a newer blocked run, or settled entirely. A stale
    // evaluation must not act on the world with outdated blocked-account
    // context.
    let job_id = ctx.job_id.clone();
    let row = state
        .ops
        .garyx_db
        .run_blocking(move |db| db.quota_recovery_job(&job_id))
        .await;
    match row {
        Ok(Some(job))
            if job.state == QuotaRecoveryState::Waiting
                && job.blocked_run_id == ctx.blocked_run_id
                && job.thread_id == ctx.thread_id => {}
        Ok(_) => {
            debug!(
                thread_id = %ctx.thread_id,
                job_id = %ctx.job_id,
                "quota auto-switch generation settled while queued; skipping"
            );
            return;
        }
        Err(error) => {
            warn!(
                thread_id = %ctx.thread_id,
                job_id = %ctx.job_id,
                error = %error,
                "quota auto-switch could not re-validate its generation; skipping"
            );
            return;
        }
    }

    let config = state.config_snapshot();
    let (enabled, current, managed): (bool, Option<String>, Vec<(String, String)>) =
        match ctx.provider {
            AccountProvider::ClaudeCode => {
                let accounts = &config.provider_accounts.claude_code;
                (
                    accounts.auto_switch_on_quota_enabled(),
                    accounts.active_account_id.clone(),
                    accounts
                        .accounts
                        .iter()
                        .map(|account| (account.id.clone(), account.name.clone()))
                        .collect(),
                )
            }
            AccountProvider::Codex => {
                let accounts = &config.provider_accounts.codex;
                (
                    accounts.auto_switch_on_quota_enabled(),
                    accounts.active_account_id.clone(),
                    accounts
                        .accounts
                        .iter()
                        .map(|account| (account.id.clone(), account.name.clone()))
                        .collect(),
                )
            }
        };
    let config_path = state.ops.config_path.clone();
    drop(config);

    if !enabled {
        debug!(provider = ?ctx.provider, "quota auto-switch disabled by config");
        return;
    }
    if managed.is_empty() {
        return;
    }

    let managed_ids: Vec<String> = managed.iter().map(|(id, _)| id.clone()).collect();
    let blocked = map_blocked_account(ctx.account_dir.as_deref(), &managed_ids, |id| {
        match ctx.provider {
            AccountProvider::ClaudeCode => {
                provider_accounts::managed_account_dir(config_path.as_deref(), id)
            }
            AccountProvider::Codex => {
                codex_provider_accounts::managed_account_dir(config_path.as_deref(), id)
            }
        }
    });

    // The provider's own verdict beats any cached reading: drop the blocked
    // account's usage entry so a stale "has allowance" value cannot make it a
    // candidate again this round.
    let blocked_identity = match &blocked {
        BlockedAccount::Managed(id) => Some(id.as_str()),
        BlockedAccount::SystemDefault => Some("system"),
        BlockedAccount::Unknown => current.as_deref().or(Some("system")),
    };
    if let Some(identity) = blocked_identity {
        match ctx.provider {
            AccountProvider::ClaudeCode => coding_usage::invalidate_claude_usage_cache(identity),
            AccountProvider::Codex => coding_usage::invalidate_codex_usage_cache(identity),
        }
    }

    let blocked_is_current = match &blocked {
        BlockedAccount::Unknown => true,
        BlockedAccount::SystemDefault => current.is_none(),
        BlockedAccount::Managed(id) => current.as_deref() == Some(id.as_str()),
    };

    if !blocked_is_current {
        // Straggler: a run launched before an earlier switch blocked on the
        // old account. If the current selection has allowance, waking just
        // this thread lets it retry on the new selection.
        let current_usage = probe_usage(state, ctx.provider, current.as_deref()).await;
        if eligible_remaining(ctx.provider, &current_usage, ctx.model.as_deref()).is_some() {
            match crate::quota_resend::expedite_generation_account_switch(
                state,
                &ctx.thread_id,
                &ctx.blocked_run_id,
            )
            .await
            {
                Ok(true) => info!(
                    thread_id = %ctx.thread_id,
                    provider = ?ctx.provider,
                    "quota auto-switch woke a stale-account thread on the current selection"
                ),
                Ok(false) => debug!(
                    thread_id = %ctx.thread_id,
                    "quota auto-switch found no waiting row to wake"
                ),
                Err(error) => warn!(
                    thread_id = %ctx.thread_id,
                    error = %error,
                    "quota auto-switch failed to wake a stale-account thread"
                ),
            }
            return;
        }
    }

    // Candidates: every other account (system default included), minus the
    // blocked account and minus the current selection.
    let mut refs: Vec<(Option<String>, String)> = Vec::with_capacity(managed.len() + 1);
    refs.push((None, "System default".to_owned()));
    for (id, name) in &managed {
        refs.push((Some(id.clone()), name.clone()));
    }
    refs.retain(|(id, _)| {
        let is_blocked = match &blocked {
            BlockedAccount::Managed(blocked_id) => id.as_deref() == Some(blocked_id.as_str()),
            BlockedAccount::SystemDefault => id.is_none(),
            BlockedAccount::Unknown => *id == current,
        };
        let is_current = *id == current;
        !is_blocked && !is_current
    });
    if refs.is_empty() {
        return;
    }

    let candidates: Vec<CandidateUsage> = join_all(refs.into_iter().map(|(id, name)| {
        let state = state.clone();
        async move {
            let usage = probe_usage(&state, ctx.provider, id.as_deref()).await;
            CandidateUsage {
                account_id: id,
                name,
                usage,
            }
        }
    }))
    .await;

    let Some(best) = pick_best_candidate(ctx.provider, &candidates, ctx.model.as_deref()) else {
        info!(
            provider = ?ctx.provider,
            thread_id = %ctx.thread_id,
            candidates = candidates.len(),
            "quota auto-switch found no account with remaining allowance"
        );
        return;
    };

    let target = best.account_id.clone();
    let outcome = match ctx.provider {
        AccountProvider::ClaudeCode => {
            provider_accounts::switch_claude_account_if_current(
                state,
                current.as_deref(),
                target.as_deref(),
            )
            .await
        }
        AccountProvider::Codex => {
            codex_provider_accounts::switch_codex_account_if_current(
                state,
                current.as_deref(),
                target.as_deref(),
            )
            .await
        }
    };
    match outcome {
        Ok(GuardedSwitchOutcome::Switched) => info!(
            provider = ?ctx.provider,
            thread_id = %ctx.thread_id,
            from = %current.as_deref().unwrap_or("system default"),
            to = %target.as_deref().unwrap_or("system default"),
            "quota auto-switch committed an account selection change"
        ),
        Ok(GuardedSwitchOutcome::LostRace) => info!(
            provider = ?ctx.provider,
            thread_id = %ctx.thread_id,
            "quota auto-switch lost the selection race; another switch already committed"
        ),
        Err(error) => warn!(
            provider = ?ctx.provider,
            thread_id = %ctx.thread_id,
            error = %error,
            "quota auto-switch failed to commit the selection change"
        ),
    }
}

async fn probe_usage(
    state: &Arc<AppState>,
    provider: AccountProvider,
    account_id: Option<&str>,
) -> ProviderUsage {
    match provider {
        AccountProvider::ClaudeCode => {
            provider_accounts::claude_account_usage(state, account_id).await
        }
        AccountProvider::Codex => {
            codex_provider_accounts::codex_account_usage(state, account_id).await
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::coding_usage::{ScopedUsageLimit, UsageWindow};

    fn window(remaining_percent: f64) -> UsageWindow {
        UsageWindow {
            used_percent: 100.0 - remaining_percent,
            remaining_percent,
            resets_at: None,
            reset_after_seconds: None,
        }
    }

    fn usage(session: Option<f64>, weekly: Option<f64>) -> ProviderUsage {
        let mut usage = coding_usage::unavailable_claude_usage("seed".to_owned());
        usage.available = true;
        usage.stale = false;
        usage.error = None;
        usage.session = session.map(window);
        usage.weekly = weekly.map(window);
        usage
    }

    fn fable_scope(remaining_percent: f64) -> ScopedUsageLimit {
        ScopedUsageLimit {
            id: "weekly_scoped:fable".to_owned(),
            name: "Fable".to_owned(),
            kind: "weekly_scoped".to_owned(),
            window: window(remaining_percent),
        }
    }

    #[test]
    fn claude_eligibility_requires_both_general_windows_and_fails_closed() {
        let claude = AccountProvider::ClaudeCode;
        assert_eq!(
            eligible_remaining(claude, &usage(Some(20.0), Some(50.0)), None),
            Some(20.0)
        );
        assert_eq!(
            eligible_remaining(claude, &usage(Some(0.0), Some(50.0)), None),
            None
        );
        assert_eq!(
            eligible_remaining(claude, &usage(Some(20.0), Some(0.0)), None),
            None
        );
        // Review #TASK-2781 finding 1: a reading that does not confirm a
        // required window is ineligible — session-only, weekly-only, and
        // windowless readings all fail closed.
        assert_eq!(
            eligible_remaining(claude, &usage(Some(25.0), None), None),
            None
        );
        assert_eq!(
            eligible_remaining(claude, &usage(None, Some(25.0)), None),
            None
        );
        assert_eq!(eligible_remaining(claude, &usage(None, None), None), None);
    }

    #[test]
    fn codex_eligibility_requires_the_weekly_window() {
        let codex = AccountProvider::Codex;
        assert_eq!(
            eligible_remaining(codex, &usage(None, Some(35.0)), None),
            Some(35.0)
        );
        assert_eq!(
            eligible_remaining(codex, &usage(Some(10.0), Some(35.0)), None),
            Some(10.0)
        );
        assert_eq!(
            eligible_remaining(codex, &usage(Some(10.0), None), None),
            None
        );
        assert_eq!(
            eligible_remaining(codex, &usage(None, Some(0.0)), None),
            None
        );
    }

    #[test]
    fn unavailable_or_stale_readings_never_qualify() {
        let mut unavailable = usage(Some(80.0), Some(80.0));
        unavailable.available = false;
        assert_eq!(
            eligible_remaining(AccountProvider::ClaudeCode, &unavailable, None),
            None
        );

        let mut stale = usage(Some(80.0), Some(80.0));
        stale.stale = true;
        assert_eq!(
            eligible_remaining(AccountProvider::ClaudeCode, &stale, None),
            None
        );
    }

    #[test]
    fn scoped_family_requires_a_matching_bucket_with_allowance() {
        let claude = AccountProvider::ClaudeCode;
        let mut with_fable = usage(Some(40.0), Some(60.0));
        with_fable.scoped_limits = vec![fable_scope(0.0)];

        // A Fable run needs the Fable bucket too.
        assert_eq!(
            eligible_remaining(claude, &with_fable, Some("claude-fable-5-20260115")),
            None
        );
        // A non-scoped-family run ignores the exhausted scoped bucket.
        assert_eq!(
            eligible_remaining(claude, &with_fable, Some("claude-sonnet-4")),
            Some(40.0)
        );
        // Unknown model applies no scoped requirement.
        assert_eq!(eligible_remaining(claude, &with_fable, None), Some(40.0));

        // A healthy scoped bucket participates in the headroom minimum.
        let mut healthy = usage(Some(40.0), Some(60.0));
        healthy.scoped_limits = vec![fable_scope(10.0)];
        assert_eq!(
            eligible_remaining(claude, &healthy, Some("claude-fable-5")),
            Some(10.0)
        );

        // Review #TASK-2781 finding 1: an account WITHOUT the scoped bucket
        // cannot be assumed to serve the scoped family — fail closed.
        assert_eq!(
            eligible_remaining(
                claude,
                &usage(Some(40.0), Some(60.0)),
                Some("claude-fable-5")
            ),
            None
        );
    }

    #[test]
    fn scoped_matching_uses_display_name_or_identity_tail() {
        let mut scoped = fable_scope(0.0);
        scoped.name = String::new();
        let mut value = usage(Some(50.0), Some(50.0));
        value.scoped_limits = vec![scoped];
        // Falls back to the `{kind}:{scope_id}` tail when the name is blank.
        assert_eq!(
            eligible_remaining(AccountProvider::ClaudeCode, &value, Some("claude-fable-5")),
            None
        );
    }

    #[test]
    fn best_candidate_ranks_by_headroom_then_name_then_id() {
        let claude = AccountProvider::ClaudeCode;
        let candidates = vec![
            CandidateUsage {
                account_id: Some("b".to_owned()),
                name: "Beta".to_owned(),
                usage: usage(Some(30.0), Some(80.0)),
            },
            CandidateUsage {
                account_id: Some("a".to_owned()),
                name: "Alpha".to_owned(),
                usage: usage(Some(70.0), Some(90.0)),
            },
            CandidateUsage {
                account_id: None,
                name: "System default".to_owned(),
                usage: usage(Some(0.0), Some(100.0)),
            },
        ];
        let best =
            pick_best_candidate(claude, &candidates, None).expect("one candidate is eligible");
        assert_eq!(best.account_id.as_deref(), Some("a"));

        let tied = vec![
            CandidateUsage {
                account_id: Some("z".to_owned()),
                name: "Zulu".to_owned(),
                usage: usage(Some(50.0), Some(50.0)),
            },
            CandidateUsage {
                account_id: Some("m".to_owned()),
                name: "Mike".to_owned(),
                usage: usage(Some(50.0), Some(50.0)),
            },
        ];
        let best = pick_best_candidate(claude, &tied, None).expect("both are eligible");
        assert_eq!(best.account_id.as_deref(), Some("m"));

        assert!(
            pick_best_candidate(
                claude,
                &[CandidateUsage {
                    account_id: Some("x".to_owned()),
                    name: "X".to_owned(),
                    usage: usage(Some(0.0), Some(0.0)),
                }],
                None
            )
            .is_none()
        );
    }

    #[test]
    fn blocked_account_maps_through_the_managed_layout() {
        let managed = vec!["abc".to_owned(), "def".to_owned()];
        let dir_of = |id: &str| {
            std::path::PathBuf::from(format!("/data/provider-accounts/claude-code/{id}"))
        };

        assert_eq!(
            map_blocked_account(None, &managed, dir_of),
            BlockedAccount::Unknown
        );
        assert_eq!(
            map_blocked_account(Some("  "), &managed, dir_of),
            BlockedAccount::Unknown
        );
        assert_eq!(
            map_blocked_account(
                Some("/data/provider-accounts/claude-code/def"),
                &managed,
                dir_of
            ),
            BlockedAccount::Managed("def".to_owned())
        );
        // Any directory outside the managed layout is the system profile —
        // including the explicit `~/.claude` / `~/.codex` identities the
        // bridge now emits for System default runs.
        assert_eq!(
            map_blocked_account(Some("/Users/test/.claude"), &managed, dir_of),
            BlockedAccount::SystemDefault
        );
    }

    #[test]
    fn generation_dedup_claims_each_job_once() {
        // Review #TASK-2781 finding 3: a lag replay of a still-waiting
        // generation must not re-evaluate it.
        let job = format!("quota-recovery:run::{}", uuid::Uuid::new_v4());
        assert!(claim_generation_once(&job));
        assert!(!claim_generation_once(&job));
        assert!(!claim_generation_once(&job));
    }
}
