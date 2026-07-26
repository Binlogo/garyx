//! Codex device-code login sessions.
//!
//! Unlike Claude's PTY-driven login, Codex auth is a plain subprocess:
//! `codex login --device-auth` prints a verification URL and a one-time user
//! code, the user authorizes from any browser, and the CLI polls until it can
//! write `auth.json` into its `CODEX_HOME` and exit 0. Garyx only parses the
//! URL/code for display and never touches the OAuth exchange or credentials.
//! Device auth binds no local port, so concurrent logins to different managed
//! homes cannot conflict.

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use axum::Json;
use axum::extract::{Path as AxumPath, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::sync::{Mutex, mpsc, oneshot};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::codex_provider_accounts::{self, AccountsApiError, CodexAuthTarget};
use crate::server::AppState;

const AUTH_START_TIMEOUT: Duration = Duration::from_secs(30);
/// Codex device codes expire after 15 minutes; the whole session does too.
const AUTH_SESSION_TIMEOUT: Duration = Duration::from_secs(15 * 60);
const MAX_OUTPUT_TAIL_CHARS: usize = 4000;

#[derive(Default)]
pub struct CodexAuthSessionStore {
    sessions: Mutex<HashMap<String, Arc<CodexAuthSession>>>,
    #[cfg(test)]
    codex_bin_override: Mutex<Option<PathBuf>>,
}

impl CodexAuthSessionStore {
    async fn insert(&self, session: Arc<CodexAuthSession>) {
        self.sessions
            .lock()
            .await
            .insert(session.login_id.clone(), session);
    }

    async fn get(&self, login_id: &str) -> Option<Arc<CodexAuthSession>> {
        self.sessions.lock().await.get(login_id).cloned()
    }

    async fn remove(&self, login_id: &str) -> Option<Arc<CodexAuthSession>> {
        self.sessions.lock().await.remove(login_id)
    }

    #[cfg(test)]
    async fn codex_bin(&self) -> PathBuf {
        self.codex_bin_override
            .lock()
            .await
            .clone()
            .unwrap_or_else(|| PathBuf::from("codex"))
    }

    #[cfg(not(test))]
    async fn codex_bin(&self) -> PathBuf {
        PathBuf::from("codex")
    }

    #[cfg(test)]
    pub async fn set_codex_bin_override_for_test(&self, command: PathBuf) {
        *self.codex_bin_override.lock().await = Some(command);
    }
}

struct CodexAuthSession {
    login_id: String,
    target: CodexAuthTarget,
    state: Mutex<CodexAuthSessionState>,
    cancellation: CancellationToken,
}

impl CodexAuthSession {
    fn new(login_id: String, target: CodexAuthTarget) -> Self {
        Self {
            login_id,
            target,
            state: Mutex::new(CodexAuthSessionState {
                status: CodexAuthLoginStatus::Starting,
                url: None,
                user_code: None,
                identity: None,
                error: None,
                exit_code: None,
            }),
            cancellation: CancellationToken::new(),
        }
    }

    async fn snapshot(&self) -> CodexAuthLoginResponse {
        self.state
            .lock()
            .await
            .to_response(&self.login_id, self.target.account_id.clone())
    }

    async fn update(&self, update: impl FnOnce(&mut CodexAuthSessionState)) {
        let mut state = self.state.lock().await;
        update(&mut state);
    }

    async fn cancel(&self) -> CodexAuthLoginResponse {
        self.update(|state| {
            if !state.status.is_terminal() {
                state.status = CodexAuthLoginStatus::Failed;
                state.error = Some("Codex sign-in was cancelled.".to_owned());
            }
        })
        .await;
        self.cancellation.cancel();
        self.snapshot().await
    }
}

#[derive(Debug, Clone)]
struct CodexAuthSessionState {
    status: CodexAuthLoginStatus,
    url: Option<String>,
    user_code: Option<String>,
    identity: Option<Value>,
    error: Option<String>,
    exit_code: Option<i32>,
}

impl CodexAuthSessionState {
    fn to_response(&self, login_id: &str, account_id: Option<String>) -> CodexAuthLoginResponse {
        CodexAuthLoginResponse {
            login_id: login_id.to_owned(),
            account_id,
            status: self.status,
            url: self.url.clone(),
            user_code: self.user_code.clone(),
            identity: self.identity.clone(),
            error: self.error.clone(),
            exit_code: self.exit_code,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CodexAuthLoginStatus {
    Starting,
    WaitingForAuthorization,
    Succeeded,
    Failed,
}

impl CodexAuthLoginStatus {
    fn is_terminal(self) -> bool {
        matches!(self, Self::Succeeded | Self::Failed)
    }
}

#[derive(Debug, Default, Deserialize)]
pub struct StartCodexAuthRequest {
    /// Present only when creating a new isolated managed account.
    managed_account_name: Option<String>,
    /// Present only when reauthenticating an existing managed account.
    account_id: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct CodexAuthLoginResponse {
    pub login_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub account_id: Option<String>,
    pub status: CodexAuthLoginStatus,
    pub url: Option<String>,
    pub user_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub identity: Option<Value>,
    pub error: Option<String>,
    pub exit_code: Option<i32>,
}

pub async fn start_codex_auth(
    State(state): State<Arc<AppState>>,
    Json(request): Json<StartCodexAuthRequest>,
) -> Result<(StatusCode, Json<CodexAuthLoginResponse>), ApiError> {
    let login_id = Uuid::new_v4().to_string();
    let target = codex_provider_accounts::prepare_codex_auth_target(
        &state,
        request.managed_account_name.as_deref(),
        request.account_id.as_deref(),
    )
    .await
    .map_err(map_accounts_error)?;

    let codex_bin = state.ops.codex_auth_sessions.codex_bin().await;
    let mut command = tokio::process::Command::new(&codex_bin);
    command
        .args(["login", "--device-auth"])
        .envs(target.environment())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            codex_provider_accounts::cleanup_failed_codex_auth_target(&state, &target).await;
            return Err(ApiError::new(
                StatusCode::BAD_GATEWAY,
                "spawn_codex_auth_failed",
                format!("Could not start `{}` login: {error}", codex_bin.display()),
            ));
        }
    };

    let session = Arc::new(CodexAuthSession::new(login_id.clone(), target));
    state
        .ops
        .codex_auth_sessions
        .insert(session.clone())
        .await;
    let (started_tx, started_rx) = oneshot::channel();
    tokio::spawn(drive_codex_auth(
        session.clone(),
        child,
        state.clone(),
        started_tx,
    ));

    match tokio::time::timeout(AUTH_START_TIMEOUT, started_rx).await {
        Ok(Ok(Ok(response))) => Ok((StatusCode::CREATED, Json(response))),
        Ok(Ok(Err(error))) => Err(error),
        Ok(Err(_)) => Err(ApiError::new(
            StatusCode::BAD_GATEWAY,
            "codex_auth_start_interrupted",
            "Codex auth session ended before returning a device code.",
        )),
        Err(_) => {
            session
                .update(|state| {
                    state.status = CodexAuthLoginStatus::Failed;
                    state.error = Some("Timed out waiting for the Codex device code.".to_owned());
                })
                .await;
            session.cancel().await;
            Err(ApiError::new(
                StatusCode::GATEWAY_TIMEOUT,
                "codex_auth_start_timeout",
                "Timed out waiting for the Codex device code.",
            ))
        }
    }
}

pub async fn get_codex_auth(
    State(state): State<Arc<AppState>>,
    AxumPath(login_id): AxumPath<String>,
) -> Result<Json<CodexAuthLoginResponse>, ApiError> {
    let session = state
        .ops
        .codex_auth_sessions
        .get(&login_id)
        .await
        .ok_or_else(|| unknown_session_error(&login_id))?;
    Ok(Json(session.snapshot().await))
}

pub async fn cancel_codex_auth(
    State(state): State<Arc<AppState>>,
    AxumPath(login_id): AxumPath<String>,
) -> Result<Json<CodexAuthLoginResponse>, ApiError> {
    let session = state
        .ops
        .codex_auth_sessions
        .remove(&login_id)
        .await
        .ok_or_else(|| unknown_session_error(&login_id))?;
    Ok(Json(session.cancel().await))
}

async fn drive_codex_auth(
    session: Arc<CodexAuthSession>,
    mut child: tokio::process::Child,
    app_state: Arc<AppState>,
    started_tx: oneshot::Sender<Result<CodexAuthLoginResponse, ApiError>>,
) {
    let mut started_tx = Some(started_tx);
    let (line_tx, mut line_rx) = mpsc::channel::<String>(64);
    if let Some(stdout) = child.stdout.take() {
        tokio::spawn(read_lines(stdout, line_tx.clone()));
    }
    if let Some(stderr) = child.stderr.take() {
        tokio::spawn(read_lines(stderr, line_tx.clone()));
    }
    drop(line_tx);

    let deadline = tokio::time::Instant::now() + AUTH_SESSION_TIMEOUT;
    let mut output_tail = String::new();
    loop {
        tokio::select! {
            _ = session.cancellation.cancelled() => {
                terminate_child(&session, &mut child).await;
                codex_provider_accounts::cleanup_failed_codex_auth_target(&app_state, &session.target)
                    .await;
                return;
            }
            _ = tokio::time::sleep_until(deadline) => {
                session
                    .update(|state| {
                        if !state.status.is_terminal() {
                            state.status = CodexAuthLoginStatus::Failed;
                            state.error =
                                Some("Codex sign-in timed out before authorization.".to_owned());
                        }
                    })
                    .await;
                terminate_child(&session, &mut child).await;
                codex_provider_accounts::cleanup_failed_codex_auth_target(&app_state, &session.target)
                    .await;
                send_start_error_once(
                    &mut started_tx,
                    ApiError::new(
                        StatusCode::GATEWAY_TIMEOUT,
                        "codex_auth_timeout",
                        "Codex sign-in timed out before authorization.",
                    ),
                );
                return;
            }
            line = line_rx.recv() => {
                let Some(line) = line else {
                    break;
                };
                let line = strip_ansi(&line);
                append_tail(&mut output_tail, &line);
                handle_output_line(&session, &line, &mut started_tx).await;
            }
        }
    }

    // Both output streams reached EOF; the process exit follows immediately.
    let exit = tokio::select! {
        _ = session.cancellation.cancelled() => {
            terminate_child(&session, &mut child).await;
            codex_provider_accounts::cleanup_failed_codex_auth_target(&app_state, &session.target)
                .await;
            return;
        }
        exit = child.wait() => exit,
    };

    match exit {
        Ok(status) => {
            let code = status.code();
            if status.success() {
                finalize_success(&session, &app_state, code).await;
            } else {
                session
                    .update(|state| {
                        state.exit_code = code;
                        if !state.status.is_terminal() {
                            state.status = CodexAuthLoginStatus::Failed;
                            state.error = Some(login_failure_message(code, &output_tail));
                        }
                    })
                    .await;
            }
        }
        Err(error) => {
            session
                .update(|state| {
                    state.status = CodexAuthLoginStatus::Failed;
                    state.error = Some(format!("Failed waiting for Codex login: {error}"));
                })
                .await;
        }
    }

    let final_snapshot = session.snapshot().await;
    if final_snapshot.status == CodexAuthLoginStatus::Failed {
        codex_provider_accounts::cleanup_failed_codex_auth_target(&app_state, &session.target).await;
        send_start_error_once(
            &mut started_tx,
            ApiError::new(
                StatusCode::BAD_GATEWAY,
                "codex_auth_failed_before_code",
                final_snapshot
                    .error
                    .clone()
                    .unwrap_or_else(|| "Codex auth failed before returning a device code.".to_owned()),
            ),
        );
    }
}

async fn finalize_success(
    session: &Arc<CodexAuthSession>,
    app_state: &Arc<AppState>,
    exit_code: Option<i32>,
) {
    let Some(auth_json_path) = session.target.auth_json_path(app_state) else {
        session
            .update(|state| {
                state.exit_code = exit_code;
                state.status = CodexAuthLoginStatus::Failed;
                state.error = Some("Could not resolve the Codex home directory.".to_owned());
            })
            .await;
        return;
    };
    // Exit 0 alone is not enough: the credential contract is file storage.
    // A keyring-configured Codex would exit 0 without an auth.json, which
    // must fail loudly instead of committing a credential-less account.
    let identity = match codex_provider_accounts::read_codex_auth_identity(&auth_json_path).await {
        Ok(identity) => identity,
        Err(error) => {
            session
                .update(|state| {
                    state.exit_code = exit_code;
                    state.status = CodexAuthLoginStatus::Failed;
                    state.error = Some(error);
                })
                .await;
            return;
        }
    };
    let completion =
        codex_provider_accounts::complete_codex_auth_target(app_state, &session.target, &identity)
            .await;
    session
        .update(|state| {
            state.exit_code = exit_code;
            match completion {
                Ok(()) => {
                    state.status = CodexAuthLoginStatus::Succeeded;
                    state.identity = Some(json!({
                        "email": identity.email,
                        "plan": identity.plan,
                        "chatgpt_account_id": identity.chatgpt_account_id,
                    }));
                }
                Err(error) => {
                    state.status = CodexAuthLoginStatus::Failed;
                    state.error = Some(error.to_string());
                }
            }
        })
        .await;
}

async fn handle_output_line(
    session: &Arc<CodexAuthSession>,
    line: &str,
    started_tx: &mut Option<oneshot::Sender<Result<CodexAuthLoginResponse, ApiError>>>,
) {
    let url = extract_url(line);
    let user_code = extract_user_code(line);
    if url.is_none() && user_code.is_none() {
        return;
    }
    let mut ready = false;
    session
        .update(|state| {
            if state.status.is_terminal() {
                return;
            }
            if let Some(url) = url
                && state.url.is_none()
            {
                state.url = Some(url);
            }
            if let Some(code) = user_code
                && state.user_code.is_none()
            {
                state.user_code = Some(code);
            }
            if state.url.is_some() && state.user_code.is_some() {
                state.status = CodexAuthLoginStatus::WaitingForAuthorization;
                state.error = None;
                ready = true;
            }
        })
        .await;
    if ready {
        send_start_response_once(started_tx, session.snapshot().await);
    }
}

async fn terminate_child(session: &Arc<CodexAuthSession>, child: &mut tokio::process::Child) {
    if let Err(error) = child.start_kill() {
        tracing::debug!(login_id = %session.login_id, error = %error, "codex login child already finished");
    }
    // Always reap: an unwaited child would linger as a zombie until gateway
    // restart.
    if let Err(error) = child.wait().await {
        tracing::warn!(login_id = %session.login_id, error = %error, "failed reaping codex login child");
    }
}

async fn read_lines(stream: impl tokio::io::AsyncRead + Unpin, tx: mpsc::Sender<String>) {
    let mut lines = BufReader::new(stream).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        if tx.send(line).await.is_err() {
            return;
        }
    }
}

fn append_tail(tail: &mut String, line: &str) {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return;
    }
    if !tail.is_empty() {
        tail.push('\n');
    }
    tail.push_str(trimmed);
    if tail.len() > MAX_OUTPUT_TAIL_CHARS {
        let excess = tail.len() - MAX_OUTPUT_TAIL_CHARS;
        let cut = tail
            .char_indices()
            .map(|(index, _)| index)
            .find(|&index| index >= excess)
            .unwrap_or(0);
        tail.drain(..cut);
    }
}

fn login_failure_message(exit_code: Option<i32>, output_tail: &str) -> String {
    let code = exit_code
        .map(|value| value.to_string())
        .unwrap_or_else(|| "unknown".to_owned());
    let tail = output_tail.trim();
    if tail.is_empty() {
        format!("Codex login exited with code {code}.")
    } else {
        format!("Codex login exited with code {code}: {tail}")
    }
}

/// Remove ANSI CSI color sequences from one output line.
fn strip_ansi(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();
    while let Some(character) = chars.next() {
        if character == '\u{1b}' {
            if chars.peek() == Some(&'[') {
                chars.next();
                while let Some(&next) = chars.peek() {
                    chars.next();
                    if next.is_ascii_alphabetic() {
                        break;
                    }
                }
            }
            continue;
        }
        out.push(character);
    }
    out
}

fn extract_url(line: &str) -> Option<String> {
    line.split_whitespace()
        .find(|token| token.starts_with("https://") || token.starts_with("http://"))
        .map(ToOwned::to_owned)
}

/// A device user code is a standalone dash-separated uppercase token on its
/// own line, e.g. `SAIW-E7TI9`. Parsed tolerantly so cosmetic output changes
/// do not break login.
fn extract_user_code(line: &str) -> Option<String> {
    let mut tokens = line.split_whitespace();
    let token = tokens.next()?;
    if tokens.next().is_some() {
        return None;
    }
    let looks_like_code = token.len() >= 5
        && token.len() <= 32
        && token.contains('-')
        && !token.starts_with('-')
        && !token.ends_with('-')
        && token
            .chars()
            .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '-');
    looks_like_code.then(|| token.to_owned())
}

fn map_accounts_error(error: AccountsApiError) -> ApiError {
    let (status, code, message) = error.into_parts();
    ApiError::new(status, code, message)
}

fn send_start_response_once(
    started_tx: &mut Option<oneshot::Sender<Result<CodexAuthLoginResponse, ApiError>>>,
    response: CodexAuthLoginResponse,
) {
    if let Some(tx) = started_tx.take() {
        let _ = tx.send(Ok(response));
    }
}

fn send_start_error_once(
    started_tx: &mut Option<oneshot::Sender<Result<CodexAuthLoginResponse, ApiError>>>,
    error: ApiError,
) {
    if let Some(tx) = started_tx.take() {
        let _ = tx.send(Err(error));
    }
}

fn unknown_session_error(login_id: &str) -> ApiError {
    ApiError::new(
        StatusCode::NOT_FOUND,
        "unknown_codex_auth_session",
        format!("Codex auth session '{login_id}' was not found."),
    )
}

#[derive(Debug)]
pub struct ApiError {
    status: StatusCode,
    code: &'static str,
    message: String,
}

impl ApiError {
    fn new(status: StatusCode, code: &'static str, message: impl Into<String>) -> Self {
        Self {
            status,
            code,
            message: message.into(),
        }
    }
}

impl IntoResponse for ApiError {
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
