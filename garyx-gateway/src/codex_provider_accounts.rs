//! Managed Codex (ChatGPT) account profiles.
//!
//! Mirrors `provider_accounts` (Claude Code) with the Codex-specific
//! materialization model from `docs/design/codex-multi-account-profiles.md`:
//! every managed account directory is a real `CODEX_HOME` whose `auth.json`
//! is written only by the Codex CLI, while shared resources (`config.toml`,
//! `skills`, `sessions`, …) are symlinks into the user's system Codex home so
//! all accounts observe one configuration and one rollout store. Garyx never
//! writes, copies, or refreshes Codex credentials.

use std::collections::HashMap;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use axum::Json;
use axum::extract::{Path as AxumPath, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use chrono::Utc;
use futures_util::future::join_all;
use garyx_models::config::{CodexManagedAccount, GaryxConfig};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::oneshot;
use uuid::Uuid;

use crate::coding_usage::{self, ProviderUsage};
use crate::mcp_config::{ConfigMutateError, mutate_config};
use crate::server::AppState;

const MANAGED_ROOT_COMPONENTS: &[&str] = &["provider-accounts", "codex"];
const OWNERSHIP_MARKER: &str = ".garyx-codex-account";

/// Quota-recovery rows written for Codex runs carry the provider slug of
/// `ProviderType::CodexAppServer`.
const CODEX_RECOVERY_PROVIDER: &str = "codex_app_server";

/// Directory entries of the system Codex home shared into every managed
/// account home via symlink. Directories are created in the system home when
/// absent so Codex can write through the link (a dangling directory symlink
/// would break rollout writes).
const SHARED_HOME_DIR_LINKS: &[&str] = &[
    "skills",
    "plugins",
    "rules",
    "memories",
    "sessions",
    "archived_sessions",
];
/// File entries shared via symlink. Dangling file links behave like a missing
/// file to Codex and light up when the user creates the target.
const SHARED_HOME_FILE_LINKS: &[&str] = &["config.toml", "mcp.json"];

#[derive(Debug, Clone, Serialize)]
pub struct CodexAccountsResponse {
    pub active_account_id: Option<String>,
    pub accounts: Vec<CodexAccountView>,
    pub refreshed_at: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexAccountView {
    pub id: Option<String>,
    pub name: String,
    pub system_default: bool,
    pub selected: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub email: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plan: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chatgpt_account_id: Option<String>,
    pub usage: ProviderUsage,
}

#[derive(Debug, Deserialize)]
pub struct SelectCodexAccountRequest {
    account_id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct RenameCodexAccountRequest {
    name: String,
}

#[derive(Debug, Clone)]
struct AccountUsageSpec {
    id: Option<String>,
    name: String,
    system_default: bool,
    selected: bool,
    email: Option<String>,
    plan: Option<String>,
    chatgpt_account_id: Option<String>,
}

fn spawn_codex_account_switch_effects(
    state: Arc<AppState>,
) -> oneshot::Receiver<Result<crate::garyx_db::QuotaRecoveryExpediteSummary, String>> {
    let (response_tx, response_rx) = oneshot::channel();
    tokio::spawn(async move {
        // Wake rows that are already durable before repairing the narrow
        // transcript-to-SQL projection window, matching the Claude switch
        // path. There is no session reconcile step: managed Codex homes share
        // one rollout store through the `sessions` symlink.
        let recovery =
            crate::quota_resend::expedite_waiting_provider_recoveries(&state, CODEX_RECOVERY_PROVIDER)
                .await;
        if let Err(error) = recovery.as_ref() {
            tracing::warn!(error, "Codex account changed but quota recovery wake failed");
        }

        // Sending the HTTP response is best-effort. Dropping its receiver must
        // never cancel the provider-owned side effect after selection changed.
        let _ = response_tx.send(recovery);

        match crate::quota_resend::repair_and_expedite_provider_recoveries(
            &state,
            CODEX_RECOVERY_PROVIDER,
        )
        .await
        {
            Ok(summary) => {
                tracing::debug!(
                    matched_threads = summary.matched_threads,
                    expedited_threads = summary.expedited_threads,
                    already_claimed_threads = summary.already_claimed_threads,
                    "repaired quota recovery projections after Codex account switch"
                );
            }
            Err(error) => tracing::warn!(
                error,
                "Codex account changed but repaired quota recovery wake failed"
            ),
        }
    });
    response_rx
}

pub(crate) fn managed_accounts_root(config_path: Option<&Path>) -> PathBuf {
    let mut root = config_path
        .and_then(Path::parent)
        .map(Path::to_path_buf)
        .unwrap_or_else(garyx_models::local_paths::gary_home_dir);
    for component in MANAGED_ROOT_COMPONENTS {
        root.push(component);
    }
    root
}

#[cfg(test)]
pub(crate) fn managed_account_dir(config_path: Option<&Path>, account_id: &str) -> PathBuf {
    managed_accounts_root(config_path).join(account_id)
}

/// The Codex home used when no managed account is selected: the Gateway's
/// ambient `CODEX_HOME`, or `~/.codex`.
pub(crate) fn system_codex_home() -> Option<PathBuf> {
    if let Some(dir) = std::env::var("CODEX_HOME")
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
    {
        return Some(PathBuf::from(dir));
    }
    garyx_models::local_paths::home_dir().map(|home| home.join(".codex"))
}

/// Where a System-default login's `auth.json` lands: the ambient Codex home.
/// Tests share the redirected `.test-codex` target so fake binaries and
/// identity reads never touch the real `~/.codex`.
fn system_default_auth_home(state: &AppState) -> Option<PathBuf> {
    #[cfg(test)]
    {
        shared_link_target_home(state)
    }
    #[cfg(not(test))]
    {
        let _ = state;
        system_codex_home()
    }
}

/// System Codex home used as the shared-symlink target. Tests redirect it
/// below the Garyx config parent so account fixtures never touch the real
/// `~/.codex`.
fn shared_link_target_home(state: &AppState) -> Option<PathBuf> {
    #[cfg(test)]
    {
        return Some(
            state
                .ops
                .config_path
                .as_deref()
                .and_then(Path::parent)
                .unwrap_or_else(|| Path::new("."))
                .join(".test-codex"),
        );
    }
    #[cfg(not(test))]
    {
        let _ = state;
        system_codex_home()
    }
}

/// Materialize (or repair) the shared-resource symlinks of one managed home.
/// Never destructive: an entry that is already a real file or directory is
/// left in place and reported as drift.
pub(crate) async fn ensure_shared_home_links(account_dir: &Path, system_home: &Path) {
    for name in SHARED_HOME_DIR_LINKS {
        let target = system_home.join(name);
        if let Err(error) = tokio::fs::create_dir_all(&target).await {
            tracing::warn!(target = %target.display(), error = %error, "could not ensure shared Codex home directory");
            continue;
        }
        ensure_symlink(&account_dir.join(name), &target).await;
    }
    for name in SHARED_HOME_FILE_LINKS {
        ensure_symlink(&account_dir.join(name), &system_home.join(name)).await;
    }
}

async fn ensure_symlink(link: &Path, target: &Path) {
    match tokio::fs::symlink_metadata(link).await {
        Ok(metadata) if metadata.file_type().is_symlink() => {}
        Ok(_) => {
            // Codex replaced the link with a real entry (for example an
            // atomic config.toml rewrite). Repairing would destroy that
            // write, so only report the drift.
            tracing::warn!(
                link = %link.display(),
                "managed Codex home entry is no longer a shared symlink; leaving local copy in place"
            );
        }
        Err(error) if error.kind() == ErrorKind::NotFound => {
            if let Err(error) = tokio::fs::symlink(target, link).await {
                tracing::warn!(
                    link = %link.display(),
                    target = %target.display(),
                    error = %error,
                    "could not create shared Codex home symlink"
                );
            }
        }
        Err(error) => {
            tracing::warn!(link = %link.display(), error = %error, "could not inspect managed Codex home entry");
        }
    }
}

pub(crate) async fn validated_active_codex_home(
    state: &AppState,
    config: &GaryxConfig,
) -> Option<PathBuf> {
    let account_id = config.provider_accounts.codex.active_account_id.clone()?;
    let validation = if config.provider_accounts.codex.account(&account_id).is_some() {
        validate_owned_account_dir(state, &account_id).await
    } else {
        Err(AccountsApiError::not_found(&account_id))
    };
    match validation {
        Ok(path) => {
            // Selection application is the repair point for shared links, so
            // startup, hot reload, and explicit selection all re-assert them.
            if let Some(system_home) = shared_link_target_home(state) {
                ensure_shared_home_links(&path, &system_home).await;
            }
            Some(path)
        }
        Err(error) => isolate_invalid_selection(state, &account_id, &error),
    }
}

fn isolate_invalid_selection(
    state: &AppState,
    account_id: &str,
    error: &AccountsApiError,
) -> Option<PathBuf> {
    // Never answer an invalid managed selection with the system profile: that
    // would silently run work under the wrong account. This fixed, nonexistent
    // quarantine path carries no credentials, and Codex refuses to launch with
    // a nonexistent CODEX_HOME.
    tracing::warn!(account_id, error = %error.message, "invalid active Codex account; isolating future Codex runs");
    Some(
        state
            .ops
            .config_path
            .as_deref()
            .and_then(Path::parent)
            .map(Path::to_path_buf)
            .unwrap_or_else(garyx_models::local_paths::gary_home_dir)
            .join(".invalid-codex-account-selection"),
    )
}

pub async fn list_codex_accounts(
    State(state): State<Arc<AppState>>,
) -> Result<Json<CodexAccountsResponse>, AccountsApiError> {
    let config = state.config_snapshot();
    let active_id = config.provider_accounts.codex.active_account_id.clone();
    let mut specs = Vec::with_capacity(config.provider_accounts.codex.accounts.len() + 1);
    specs.push(AccountUsageSpec {
        id: None,
        name: "System default".to_owned(),
        system_default: true,
        selected: active_id.is_none(),
        email: None,
        plan: None,
        chatgpt_account_id: None,
    });
    specs.extend(
        config
            .provider_accounts
            .codex
            .accounts
            .iter()
            .map(|account| AccountUsageSpec {
                id: Some(account.id.clone()),
                name: account.name.clone(),
                system_default: false,
                selected: active_id.as_deref() == Some(account.id.as_str()),
                email: account.email.clone(),
                plan: account.plan.clone(),
                chatgpt_account_id: account.chatgpt_account_id.clone(),
            }),
    );
    drop(config);

    let accounts = join_all(specs.into_iter().map(|spec| {
        let state = state.clone();
        async move {
            let usage = if let Some(account_id) = spec.id.as_deref() {
                match validate_owned_account_dir(&state, account_id).await {
                    Ok(home) => {
                        coding_usage::resolve_codex_usage_for_home(Some(&home), account_id).await
                    }
                    Err(error) => coding_usage::unavailable_codex_usage(error.message),
                }
            } else {
                coding_usage::resolve_codex_usage_for_home(None, "system").await
            };
            CodexAccountView {
                id: spec.id,
                name: spec.name,
                system_default: spec.system_default,
                selected: spec.selected,
                email: spec.email,
                plan: spec.plan.or_else(|| usage.plan.clone()),
                chatgpt_account_id: spec.chatgpt_account_id,
                usage,
            }
        }
    }))
    .await;

    Ok(Json(CodexAccountsResponse {
        active_account_id: active_id,
        accounts,
        refreshed_at: Utc::now().to_rfc3339(),
    }))
}

pub async fn select_codex_account(
    State(state): State<Arc<AppState>>,
    Json(request): Json<SelectCodexAccountRequest>,
) -> Result<Json<Value>, AccountsApiError> {
    let account_id = normalize_optional_account_id(request.account_id)?;
    if let Some(account_id) = account_id.as_deref() {
        validate_owned_account_dir(&state, account_id).await?;
    }
    let selected = account_id.clone();
    let selection_changed = mutate_config(&state, move |config| {
        if let Some(account_id) = selected.as_deref()
            && config.provider_accounts.codex.account(account_id).is_none()
        {
            return Err(AccountsApiError::not_found(account_id));
        }
        let changed = config.provider_accounts.codex.active_account_id != selected;
        config.provider_accounts.codex.active_account_id = selected.clone();
        Ok(changed)
    })
    .await
    .map_err(map_mutate_error)?;

    let mut response = json!({
        "active_account_id": account_id,
        "selection_changed": selection_changed,
    });
    if selection_changed {
        match spawn_codex_account_switch_effects(state.clone()).await {
            Ok(recovery) => match recovery {
                Ok(summary) => response["recovery"] = json!(summary),
                Err(error) => response["recovery_warning"] = Value::String(error),
            },
            Err(error) => {
                tracing::warn!(
                    error = %error,
                    "Codex account switch effects ended before reporting their initial result"
                );
                response["recovery_warning"] = Value::String(
                    "Quota recovery wake did not report its initial result.".to_owned(),
                );
            }
        }
    } else {
        response["recovery"] = json!(crate::garyx_db::QuotaRecoveryExpediteSummary::default());
    }
    Ok(Json(response))
}

pub async fn rename_codex_account(
    State(state): State<Arc<AppState>>,
    AxumPath(account_id): AxumPath<String>,
    Json(request): Json<RenameCodexAccountRequest>,
) -> Result<Json<Value>, AccountsApiError> {
    let account_id = require_account_id(&account_id)?;
    let name = normalize_account_name(&request.name)?;
    let response_name = name.clone();
    let response_id = account_id.clone();
    mutate_config(&state, move |config| {
        let account = config
            .provider_accounts
            .codex
            .account_mut(&account_id)
            .ok_or_else(|| AccountsApiError::not_found(&account_id))?;
        account.name = name;
        account.updated_at = Utc::now().to_rfc3339();
        Ok(())
    })
    .await
    .map_err(map_mutate_error)?;
    Ok(Json(json!({ "id": response_id, "name": response_name })))
}

pub async fn delete_codex_account(
    State(state): State<Arc<AppState>>,
    AxumPath(account_id): AxumPath<String>,
) -> Result<Json<Value>, AccountsApiError> {
    let account_id = require_account_id(&account_id)?;
    let account_dir = validate_owned_account_dir(&state, &account_id).await?;
    let removed_id = account_id.clone();
    mutate_config(&state, move |config| {
        let accounts = &mut config.provider_accounts.codex;
        let Some(index) = accounts
            .accounts
            .iter()
            .position(|account| account.id == removed_id)
        else {
            return Err(AccountsApiError::not_found(&removed_id));
        };
        accounts.accounts.remove(index);
        if accounts.active_account_id.as_deref() == Some(removed_id.as_str()) {
            accounts.active_account_id = None;
        }
        Ok(())
    })
    .await
    .map_err(map_mutate_error)?;

    coding_usage::invalidate_codex_usage_cache(&account_id);
    // `remove_dir_all` removes the shared-resource symlinks themselves, never
    // their targets in the system Codex home.
    tokio::fs::remove_dir_all(&account_dir).await.map_err(|error| {
        AccountsApiError::internal(format!(
            "Account was removed from Garyx, but its managed directory {} could not be deleted: {error}",
            account_dir.display()
        ))
    })?;
    Ok(Json(json!({ "deleted_account_id": account_id })))
}

#[derive(Debug, Clone)]
pub(crate) struct CodexAuthTarget {
    pub account_id: Option<String>,
    pub codex_home: Option<PathBuf>,
    pub account_name: Option<String>,
    pub is_new: bool,
}

impl CodexAuthTarget {
    pub(crate) fn environment(&self) -> HashMap<String, String> {
        self.codex_home
            .as_ref()
            .map(|home| {
                HashMap::from([(
                    "CODEX_HOME".to_owned(),
                    home.to_string_lossy().into_owned(),
                )])
            })
            .unwrap_or_default()
    }

    /// The `auth.json` the Codex CLI must have produced for this login.
    pub(crate) fn auth_json_path(&self, state: &AppState) -> Option<PathBuf> {
        if let Some(home) = self.codex_home.as_ref() {
            return Some(home.join("auth.json"));
        }
        system_default_auth_home(state).map(|home| home.join("auth.json"))
    }
}

pub(crate) async fn prepare_codex_auth_target(
    state: &Arc<AppState>,
    managed_account_name: Option<&str>,
    account_id: Option<&str>,
) -> Result<CodexAuthTarget, AccountsApiError> {
    if managed_account_name.is_some() && account_id.is_some() {
        return Err(AccountsApiError::bad_request(
            "ambiguous_auth_target",
            "Choose either a new managed account or an existing account to reauthenticate.",
        ));
    }
    if let Some(account_id) = account_id {
        let account_id = require_account_id(account_id)?;
        let config = state.config_snapshot();
        let account = config
            .provider_accounts
            .codex
            .account(&account_id)
            .ok_or_else(|| AccountsApiError::not_found(&account_id))?;
        let account_name = account.name.clone();
        drop(config);
        let codex_home = validate_owned_account_dir(state, &account_id).await?;
        return Ok(CodexAuthTarget {
            account_id: Some(account_id),
            codex_home: Some(codex_home),
            account_name: Some(account_name),
            is_new: false,
        });
    }
    if let Some(name) = managed_account_name {
        let name = normalize_account_name(name)?;
        let account_id = Uuid::new_v4().to_string();
        let codex_home = create_owned_account_dir(state, &account_id).await?;
        return Ok(CodexAuthTarget {
            account_id: Some(account_id),
            codex_home: Some(codex_home),
            account_name: Some(name),
            is_new: true,
        });
    }
    Ok(CodexAuthTarget {
        account_id: None,
        codex_home: None,
        account_name: None,
        is_new: false,
    })
}

pub(crate) async fn complete_codex_auth_target(
    state: &Arc<AppState>,
    target: &CodexAuthTarget,
    identity: &CodexAuthIdentity,
) -> Result<(), AccountsApiError> {
    let Some(account_id) = target.account_id.clone() else {
        coding_usage::invalidate_codex_usage_cache("system");
        return Ok(());
    };
    let now = Utc::now().to_rfc3339();
    let email = identity.email.clone();
    let plan = identity.plan.clone();
    let chatgpt_account_id = identity.chatgpt_account_id.clone();
    let name = target
        .account_name
        .clone()
        .unwrap_or_else(|| "Codex account".to_owned());
    let is_new = target.is_new;
    let cache_identity = account_id.clone();
    mutate_config(state, move |config| {
        let accounts = &mut config.provider_accounts.codex;
        if is_new {
            if accounts.account(&account_id).is_some() {
                return Err(AccountsApiError::conflict(
                    "codex_account_exists",
                    "The managed Codex account already exists.",
                ));
            }
            // Adding an account never changes the active selection; switching
            // is an explicit user action through the select endpoint.
            accounts.accounts.push(CodexManagedAccount {
                id: account_id.clone(),
                name,
                email,
                plan,
                chatgpt_account_id,
                created_at: now.clone(),
                updated_at: now,
            });
        } else {
            let account = accounts
                .account_mut(&account_id)
                .ok_or_else(|| AccountsApiError::not_found(&account_id))?;
            account.email = email;
            account.plan = plan;
            account.chatgpt_account_id = chatgpt_account_id;
            account.updated_at = now;
        }
        Ok(())
    })
    .await
    .map_err(map_mutate_error)?;
    coding_usage::invalidate_codex_usage_cache(&cache_identity);
    Ok(())
}

pub(crate) async fn cleanup_failed_codex_auth_target(state: &Arc<AppState>, target: &CodexAuthTarget) {
    if !target.is_new {
        return;
    }
    let Some(account_id) = target.account_id.as_deref() else {
        return;
    };
    match validate_owned_account_dir(state, account_id).await {
        Ok(path) => {
            if let Err(error) = tokio::fs::remove_dir_all(&path).await {
                tracing::warn!(path = %path.display(), error = %error, "failed to clean up Codex auth profile");
            }
        }
        Err(error) => {
            tracing::warn!(account_id, error = %error.message, "refused unsafe Codex auth profile cleanup");
        }
    }
}

/// Non-secret identity decoded from a Codex `auth.json`. Values come from the
/// `id_token` JWT payload (decoded without signature verification — display
/// metadata only, never an authorization decision).
#[derive(Debug, Clone, Default)]
pub(crate) struct CodexAuthIdentity {
    pub email: Option<String>,
    pub plan: Option<String>,
    pub chatgpt_account_id: Option<String>,
}

pub(crate) async fn read_codex_auth_identity(
    auth_json_path: &Path,
) -> Result<CodexAuthIdentity, String> {
    let contents = tokio::fs::read_to_string(auth_json_path)
        .await
        .map_err(|error| {
            format!(
                "Codex auth file {} was not readable after login: {error}",
                auth_json_path.display()
            )
        })?;
    let value: Value = serde_json::from_str(&contents)
        .map_err(|error| format!("Codex auth file was not valid JSON: {error}"))?;
    let tokens = value
        .get("tokens")
        .ok_or_else(|| "Codex auth file has no ChatGPT tokens.".to_owned())?;
    let mut identity = CodexAuthIdentity {
        email: None,
        plan: None,
        chatgpt_account_id: tokens
            .get("account_id")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|id| !id.is_empty())
            .map(ToOwned::to_owned),
    };
    if let Some(payload) = tokens
        .get("id_token")
        .and_then(Value::as_str)
        .and_then(decode_jwt_payload)
    {
        let auth_claims = payload.get("https://api.openai.com/auth");
        identity.email = claim_string(&payload, "email").or_else(|| {
            payload
                .get("https://api.openai.com/profile")
                .and_then(|profile| claim_string(profile, "email"))
        });
        identity.plan = auth_claims.and_then(|claims| claim_string(claims, "chatgpt_plan_type"));
        if identity.chatgpt_account_id.is_none() {
            identity.chatgpt_account_id =
                auth_claims.and_then(|claims| claim_string(claims, "chatgpt_account_id"));
        }
    }
    Ok(identity)
}

fn decode_jwt_payload(token: &str) -> Option<Value> {
    let payload = token.split('.').nth(1)?;
    let bytes = URL_SAFE_NO_PAD.decode(payload.trim()).ok()?;
    serde_json::from_slice(&bytes).ok()
}

fn claim_string(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

async fn create_owned_account_dir(
    state: &Arc<AppState>,
    account_id: &str,
) -> Result<PathBuf, AccountsApiError> {
    let account_id = require_account_id(account_id)?;
    let root = managed_accounts_root(state.ops.config_path.as_deref());
    ensure_managed_root(&root).await?;
    let account_dir = root.join(&account_id);
    tokio::fs::create_dir(&account_dir).await.map_err(|error| {
        AccountsApiError::internal(format!(
            "Could not create managed Codex account directory {}: {error}",
            account_dir.display()
        ))
    })?;
    let marker = account_dir.join(OWNERSHIP_MARKER);
    if let Err(error) = tokio::fs::write(&marker, format!("{account_id}\n")).await {
        let _ = tokio::fs::remove_dir(&account_dir).await;
        return Err(AccountsApiError::internal(format!(
            "Could not create Codex account ownership marker {}: {error}",
            marker.display()
        )));
    }
    let validated = validate_owned_account_dir(state, &account_id).await?;
    if let Some(system_home) = shared_link_target_home(state) {
        ensure_shared_home_links(&validated, &system_home).await;
    }
    Ok(validated)
}

async fn ensure_managed_root(root: &Path) -> Result<(), AccountsApiError> {
    let container = managed_root_container(root).ok_or_else(|| {
        AccountsApiError::internal(format!(
            "Managed Codex account root {} has an invalid layout.",
            root.display()
        ))
    })?;
    ensure_directory_component(container).await?;
    ensure_directory_component(root).await?;
    canonical_safe_managed_root(root).await.map_err(|error| {
        AccountsApiError::internal(format!(
            "Managed Codex account root {} is not safe: {error}",
            root.display()
        ))
    })?;
    Ok(())
}

async fn ensure_directory_component(path: &Path) -> Result<(), AccountsApiError> {
    match tokio::fs::create_dir(path).await {
        Ok(()) => {}
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {}
        Err(error) => {
            return Err(AccountsApiError::internal(format!(
                "Could not create managed Codex account directory {}: {error}",
                path.display()
            )));
        }
    }
    let metadata = tokio::fs::symlink_metadata(path).await.map_err(|error| {
        AccountsApiError::internal(format!(
            "Could not inspect managed Codex account directory {}: {error}",
            path.display()
        ))
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(AccountsApiError::internal(format!(
            "Managed Codex account directory {} is not a safe directory.",
            path.display()
        )));
    }
    Ok(())
}

fn managed_root_container(root: &Path) -> Option<&Path> {
    root.parent()
}

fn managed_root_anchor(root: &Path) -> Option<&Path> {
    managed_root_container(root)?.parent()
}

async fn canonical_safe_managed_root(root: &Path) -> Result<PathBuf, String> {
    let container = managed_root_container(root)
        .ok_or_else(|| "missing provider-accounts container".to_owned())?;
    let anchor = managed_root_anchor(root).ok_or_else(|| "missing config parent".to_owned())?;
    for path in [container, root] {
        let metadata = tokio::fs::symlink_metadata(path)
            .await
            .map_err(|error| format!("could not inspect {}: {error}", path.display()))?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(format!("{} is not a real directory", path.display()));
        }
    }
    let canonical_anchor = tokio::fs::canonicalize(anchor)
        .await
        .map_err(|error| format!("could not resolve {}: {error}", anchor.display()))?;
    let canonical_container = tokio::fs::canonicalize(container)
        .await
        .map_err(|error| format!("could not resolve {}: {error}", container.display()))?;
    let canonical_root = tokio::fs::canonicalize(root)
        .await
        .map_err(|error| format!("could not resolve {}: {error}", root.display()))?;
    if canonical_container.parent() != Some(canonical_anchor.as_path())
        || canonical_root.parent() != Some(canonical_container.as_path())
    {
        return Err("managed root escaped the Garyx config directory".to_owned());
    }
    Ok(canonical_root)
}

/// Ownership validation for one managed Codex home. The ownership chain
/// (managed root components, the account directory itself, and the marker)
/// must be symlink-free; the shared-resource symlinks *inside* the account
/// directory are expected and are not chain members.
async fn validate_owned_account_dir(
    state: &AppState,
    account_id: &str,
) -> Result<PathBuf, AccountsApiError> {
    let account_id = require_account_id(account_id)?;
    let root = managed_accounts_root(state.ops.config_path.as_deref());
    let account_dir = root.join(&account_id);
    let canonical_root = canonical_safe_managed_root(&root)
        .await
        .map_err(|_| AccountsApiError::unsafe_directory(&account_dir))?;
    let account_metadata = tokio::fs::symlink_metadata(&account_dir)
        .await
        .map_err(|_| AccountsApiError::unsafe_directory(&account_dir))?;
    if account_metadata.file_type().is_symlink() || !account_metadata.is_dir() {
        return Err(AccountsApiError::unsafe_directory(&account_dir));
    }
    let canonical_account = tokio::fs::canonicalize(&account_dir)
        .await
        .map_err(|_| AccountsApiError::unsafe_directory(&account_dir))?;
    if canonical_account.parent() != Some(canonical_root.as_path()) {
        return Err(AccountsApiError::unsafe_directory(&account_dir));
    }
    let marker = account_dir.join(OWNERSHIP_MARKER);
    let marker_metadata = tokio::fs::symlink_metadata(&marker)
        .await
        .map_err(|_| AccountsApiError::unsafe_directory(&account_dir))?;
    if marker_metadata.file_type().is_symlink() || !marker_metadata.is_file() {
        return Err(AccountsApiError::unsafe_directory(&account_dir));
    }
    let marker_value = tokio::fs::read_to_string(&marker)
        .await
        .map_err(|_| AccountsApiError::unsafe_directory(&account_dir))?;
    if marker_value.trim() != account_id {
        return Err(AccountsApiError::unsafe_directory(&account_dir));
    }
    Ok(account_dir)
}

fn normalize_optional_account_id(
    account_id: Option<String>,
) -> Result<Option<String>, AccountsApiError> {
    account_id
        .map(|account_id| require_account_id(&account_id))
        .transpose()
}

fn require_account_id(account_id: &str) -> Result<String, AccountsApiError> {
    let trimmed = account_id.trim();
    if !valid_account_id(trimmed) {
        return Err(AccountsApiError::bad_request(
            "invalid_codex_account_id",
            "Codex account ID is invalid.",
        ));
    }
    Ok(trimmed.to_owned())
}

fn valid_account_id(account_id: &str) -> bool {
    Uuid::parse_str(account_id).is_ok()
}

fn normalize_account_name(name: &str) -> Result<String, AccountsApiError> {
    let name = name.trim();
    if name.is_empty() || name.chars().count() > 60 {
        return Err(AccountsApiError::bad_request(
            "invalid_codex_account_name",
            "Account name must contain 1 to 60 characters.",
        ));
    }
    Ok(name.to_owned())
}

fn map_mutate_error(error: ConfigMutateError<AccountsApiError>) -> AccountsApiError {
    match error {
        ConfigMutateError::Rejected(error) => error,
        ConfigMutateError::Apply(error) => AccountsApiError::internal(error),
    }
}

#[derive(Debug)]
pub(crate) struct AccountsApiError {
    status: StatusCode,
    code: &'static str,
    message: String,
}

impl AccountsApiError {
    pub(crate) fn into_parts(self) -> (StatusCode, &'static str, String) {
        (self.status, self.code, self.message)
    }

    fn bad_request(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            code,
            message: message.into(),
        }
    }

    fn not_found(account_id: &str) -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            code: "codex_account_not_found",
            message: format!("Codex account '{account_id}' was not found."),
        }
    }

    fn conflict(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::CONFLICT,
            code,
            message: message.into(),
        }
    }

    fn unsafe_directory(path: &Path) -> Self {
        Self::conflict(
            "unsafe_codex_account_directory",
            format!(
                "Managed Codex account directory {} failed ownership checks.",
                path.display()
            ),
        )
    }

    fn internal(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            code: "codex_account_operation_failed",
            message: message.into(),
        }
    }
}

impl IntoResponse for AccountsApiError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(json!({
                "error": {
                    "code": self.code,
                    "message": self.message,
                }
            })),
        )
            .into_response()
    }
}

impl std::fmt::Display for AccountsApiError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{}", self.message)
    }
}
