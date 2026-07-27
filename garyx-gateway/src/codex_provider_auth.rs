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
                finalizing: false,
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
            if !state.status.is_terminal() && !state.finalizing {
                state.status = CodexAuthLoginStatus::Failed;
                state.error = Some("Codex sign-in was cancelled.".to_owned());
            }
        })
        .await;
        self.cancellation.cancel();
        self.snapshot().await
    }

    /// Atomically claim the right to commit this login's account. Returns
    /// false when the session already reached a terminal state (e.g. a cancel
    /// won the race); the caller must then treat the login as failed and
    /// clean up the reserved target instead of committing it.
    async fn try_claim_finalize(&self) -> bool {
        let mut state = self.state.lock().await;
        if state.status.is_terminal() {
            return false;
        }
        state.finalizing = true;
        true
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
    /// Claimed under the state lock by `finalize_success` just before the
    /// account commit. A cancel that arrives after the claim is too late and
    /// must not flip the session to Failed — the commit is going to land, and
    /// a "cancelled" response over a committed account would strand it.
    finalizing: bool,
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
    if target.codex_home.is_some() {
        // A managed login must produce the managed home's auth.json;
        // inherited auth overrides would outrank it inside the CLI.
        for key in garyx_models::provider::CODEX_AUTH_ENV_OVERRIDES {
            command.env_remove(key);
        }
    }
    // The PATH entry is typically a Node launcher that re-execs the real
    // codex binary. Give the login its own process group so cancellation can
    // terminate the whole tree instead of orphaning the poller.
    #[cfg(unix)]
    command.process_group(0);
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
    state.ops.codex_auth_sessions.insert(session.clone()).await;
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
        codex_provider_accounts::cleanup_failed_codex_auth_target(&app_state, &session.target)
            .await;
        send_start_error_once(
            &mut started_tx,
            ApiError::new(
                StatusCode::BAD_GATEWAY,
                "codex_auth_failed_before_code",
                final_snapshot.error.clone().unwrap_or_else(|| {
                    "Codex auth failed before returning a device code.".to_owned()
                }),
            ),
        );
    }
}

async fn finalize_success(
    session: &Arc<CodexAuthSession>,
    app_state: &Arc<AppState>,
    exit_code: Option<i32>,
) {
    // The CLI exiting 0 races DELETE: a cancel that already marked the
    // session terminal must win, and its reserved target must not be
    // committed. Claiming under the state lock makes the decision atomic —
    // after the claim a late cancel is a no-op instead.
    if !session.try_claim_finalize().await {
        codex_provider_accounts::cleanup_failed_codex_auth_target(app_state, &session.target)
            .await;
        return;
    }
    let Some(auth_json_path) = session.target.auth_json_path(app_state) else {
        session
            .update(|state| {
                state.finalizing = false;
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
                    state.finalizing = false;
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
            state.finalizing = false;
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
    // Kill the whole process group (the child is its own group leader, see
    // spawn): killing only the direct child leaves the launcher's re-exec'd
    // codex poller orphaned and polling forever.
    #[cfg(unix)]
    if let Some(pid) = child.id() {
        let killed = unsafe { libc::killpg(pid as libc::pid_t, libc::SIGKILL) };
        if killed != 0 {
            let error = std::io::Error::last_os_error();
            tracing::debug!(login_id = %session.login_id, %error, "codex login process group already gone");
        }
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::{Body, to_bytes};
    use axum::http::StatusCode;
    use garyx_models::config::GaryxConfig;
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::time::Instant;
    use tempfile::tempdir;
    use tower::ServiceExt;

    /// Fake `codex` CLI: prints the device-auth banner (with ANSI colors,
    /// matching codex-cli 0.144.0 output), then waits for an `authorized` or
    /// `authorized-empty` marker next to itself. `authorized` writes a real
    /// ChatGPT auth.json into CODEX_HOME (or the test system home) before
    /// exiting 0; `authorized-empty` exits 0 without writing credentials.
    fn write_fake_codex(dir: &Path) -> PathBuf {
        let path = dir.join("codex");
        fs::write(
            &path,
            r#"#!/usr/bin/env python3
import base64, json, os, sys, time
from pathlib import Path

args = sys.argv[1:]
if args != ["login", "--device-auth"]:
    print("unexpected args: " + repr(args), file=sys.stderr)
    sys.exit(2)

Path(__file__).with_name("login.pid").write_text(str(os.getpid()), encoding="utf-8")

# Stand-in for the Node launcher's re-exec'd codex poller: a grandchild that
# only dies with the process group. Normal exits reap it explicitly so only
# a SIGKILL'd waiting loop leaves it for killpg.
import subprocess
grandchild = subprocess.Popen(["sleep", "300"])
Path(__file__).with_name("grandchild.pid").write_text(str(grandchild.pid), encoding="utf-8")

def finish(code):
    grandchild.kill()
    sys.exit(code)

print("Welcome to Codex [v\x1b[90m0.144.0\x1b[0m]", flush=True)
print("1. Open this link in your browser and sign in to your account", flush=True)
print("   \x1b[94mhttps://auth.openai.com/codex/device\x1b[0m", flush=True)
print("2. Enter this one-time code (expires in 15 minutes)", flush=True)
print("   \x1b[94mTEST1-CODE9\x1b[0m", flush=True)

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

home = os.environ.get("CODEX_HOME")
target = Path(home) if home else Path(__file__).parent / ".test-codex"
authorized = Path(__file__).with_name("authorized")
authorized_empty = Path(__file__).with_name("authorized-empty")
for _ in range(1500):
    if authorized_empty.exists():
        finish(0)
    if authorized.exists():
        payload = {
            "email": "user@example.com",
            "https://api.openai.com/auth": {
                "chatgpt_plan_type": "pro",
                "chatgpt_account_id": "00000000-0000-4000-8000-000000000001",
            },
        }
        jwt = b64url(b'{"alg":"none"}') + "." + b64url(json.dumps(payload).encode()) + ".sig"
        target.mkdir(parents=True, exist_ok=True)
        (target / "auth.json").write_text(json.dumps({
            "auth_mode": "chatgpt",
            "tokens": {
                "id_token": jwt,
                "access_token": "at",
                "refresh_token": "rt",
                "account_id": "00000000-0000-4000-8000-000000000001",
            },
        }), encoding="utf-8")
        finish(0)
    time.sleep(0.02)
finish(3)
"#,
        )
        .unwrap();
        #[cfg(unix)]
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    async fn poll_status(
        router: &axum::Router,
        login_id: &str,
        want: CodexAuthLoginStatus,
    ) -> CodexAuthLoginResponse {
        let status_uri = format!("/api/providers/codex/auth/{login_id}");
        // Generous budget: under full-suite parallelism the config persist +
        // bridge reload inside completion can take several seconds.
        for _ in 0..750 {
            let response = router
                .clone()
                .oneshot(
                    crate::test_support::authed_request()
                        .method("GET")
                        .uri(&status_uri)
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            let snapshot: CodexAuthLoginResponse =
                serde_json::from_slice(&to_bytes(response.into_body(), usize::MAX).await.unwrap())
                    .unwrap();
            if snapshot.status == want {
                return snapshot;
            }
            assert!(
                !snapshot.status.is_terminal(),
                "session settled at {:?} while waiting for {want:?}: {:?}",
                snapshot.status,
                snapshot.error
            );
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        let response = router
            .clone()
            .oneshot(
                crate::test_support::authed_request()
                    .method("GET")
                    .uri(&status_uri)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let last = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        panic!(
            "auth session never reached {want:?}; last snapshot: {}",
            String::from_utf8_lossy(&last)
        );
    }

    async fn start_auth(router: &axum::Router, body: &str) -> (StatusCode, CodexAuthLoginResponse) {
        let response = router
            .clone()
            .oneshot(
                crate::test_support::authed_request()
                    .method("POST")
                    .uri("/api/providers/codex/auth/start")
                    .header("content-type", "application/json")
                    .body(Body::from(body.to_owned()))
                    .unwrap(),
            )
            .await
            .unwrap();
        let status = response.status();
        let value: CodexAuthLoginResponse =
            serde_json::from_slice(&to_bytes(response.into_body(), usize::MAX).await.unwrap())
                .unwrap();
        (status, value)
    }

    #[tokio::test]
    async fn managed_codex_auth_reports_device_code_then_commits_account_without_selecting_it() {
        let dir = tempdir().unwrap();
        let fake_codex = write_fake_codex(dir.path());
        let config = crate::test_support::with_gateway_auth(GaryxConfig::default());
        let state = crate::server::AppStateBuilder::new(config)
            .with_config_path(dir.path().join("config.yaml"))
            .build();
        state
            .ops
            .codex_auth_sessions
            .set_codex_bin_override_for_test(fake_codex)
            .await;
        let router = crate::route_graph::build_router(state.clone());

        let (status, start) = start_auth(&router, r#"{"managed_account_name":"Work"}"#).await;
        assert_eq!(status, StatusCode::CREATED);
        assert_eq!(start.status, CodexAuthLoginStatus::WaitingForAuthorization);
        assert_eq!(
            start.url.as_deref(),
            Some("https://auth.openai.com/codex/device")
        );
        assert_eq!(start.user_code.as_deref(), Some("TEST1-CODE9"));
        let account_id = start.account_id.clone().expect("managed account id");
        let account_dir = dir.path().join("provider-accounts/codex").join(&account_id);
        assert!(account_dir.is_dir());
        assert!(
            state
                .config_snapshot()
                .provider_accounts
                .codex
                .accounts
                .is_empty(),
            "account must not commit before the CLI succeeds"
        );

        fs::write(dir.path().join("authorized"), "ok").unwrap();
        let succeeded =
            poll_status(&router, &start.login_id, CodexAuthLoginStatus::Succeeded).await;
        assert_eq!(succeeded.exit_code, Some(0));
        assert_eq!(
            succeeded
                .identity
                .as_ref()
                .and_then(|value| value.get("email"))
                .and_then(Value::as_str),
            Some("user@example.com")
        );
        assert!(account_dir.join("auth.json").is_file());

        let config = state.config_snapshot();
        let account = config
            .provider_accounts
            .codex
            .account(&account_id)
            .expect("committed account");
        assert_eq!(account.name, "Work");
        assert_eq!(account.email.as_deref(), Some("user@example.com"));
        assert_eq!(account.plan.as_deref(), Some("pro"));
        // Adding an account never changes the active selection.
        assert!(config.provider_accounts.codex.active_account_id.is_none());
    }

    #[tokio::test]
    async fn cancelling_codex_auth_kills_child_and_removes_uncommitted_home() {
        let dir = tempdir().unwrap();
        let fake_codex = write_fake_codex(dir.path());
        let login_pid_path = dir.path().join("login.pid");
        let config = crate::test_support::with_gateway_auth(GaryxConfig::default());
        let state = crate::server::AppStateBuilder::new(config)
            .with_config_path(dir.path().join("config.yaml"))
            .build();
        state
            .ops
            .codex_auth_sessions
            .set_codex_bin_override_for_test(fake_codex)
            .await;
        let router = crate::route_graph::build_router(state.clone());

        let (status, start) = start_auth(&router, r#"{"managed_account_name":"Cancelled"}"#).await;
        assert_eq!(status, StatusCode::CREATED);
        let account_id = start.account_id.as_deref().expect("managed account id");
        let login_pid = fs::read_to_string(&login_pid_path)
            .unwrap()
            .trim()
            .parse::<libc::pid_t>()
            .unwrap();
        let account_dir = dir.path().join("provider-accounts/codex").join(account_id);
        assert!(account_dir.is_dir());

        let auth_uri = format!("/api/providers/codex/auth/{}", start.login_id);
        let cancel_response = router
            .clone()
            .oneshot(
                crate::test_support::authed_request()
                    .method("DELETE")
                    .uri(&auth_uri)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(cancel_response.status(), StatusCode::OK);
        let cancelled: CodexAuthLoginResponse = serde_json::from_slice(
            &to_bytes(cancel_response.into_body(), usize::MAX)
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(cancelled.status, CodexAuthLoginStatus::Failed);
        assert_eq!(
            cancelled.error.as_deref(),
            Some("Codex sign-in was cancelled.")
        );

        for _ in 0..100 {
            if !account_dir.exists() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert!(!account_dir.exists(), "cancelled profile should be removed");
        assert!(
            state
                .config_snapshot()
                .provider_accounts
                .codex
                .accounts
                .is_empty()
        );
        assert_child_reaped(login_pid).await;
        // The launcher's re-exec'd poller dies with the process group; a
        // direct-child-only kill would orphan it polling for 15 minutes.
        let grandchild_pid = fs::read_to_string(dir.path().join("grandchild.pid"))
            .unwrap()
            .trim()
            .parse::<libc::pid_t>()
            .unwrap();
        assert_process_gone(grandchild_pid).await;

        let status_response = router
            .oneshot(
                crate::test_support::authed_request()
                    .method("GET")
                    .uri(auth_uri)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(status_response.status(), StatusCode::NOT_FOUND);
    }

    /// Write the credentials the fake CLI would have produced, directly in
    /// Rust: a ChatGPT auth.json whose id_token payload decodes to a plan and
    /// account id.
    fn write_valid_auth_json(home: &Path) {
        use base64::Engine as _;
        use base64::engine::general_purpose::URL_SAFE_NO_PAD;
        let payload = serde_json::json!({
            "email": "user@example.com",
            "https://api.openai.com/auth": {
                "chatgpt_plan_type": "pro",
                "chatgpt_account_id": "00000000-0000-4000-8000-000000000001",
            },
        });
        let jwt = format!(
            "{}.{}.sig",
            URL_SAFE_NO_PAD.encode(b"{\"alg\":\"none\"}"),
            URL_SAFE_NO_PAD.encode(payload.to_string().as_bytes()),
        );
        fs::create_dir_all(home).unwrap();
        fs::write(
            home.join("auth.json"),
            serde_json::json!({
                "auth_mode": "chatgpt",
                "tokens": {
                    "id_token": jwt,
                    "access_token": "at",
                    "refresh_token": "rt",
                    "account_id": "00000000-0000-4000-8000-000000000001",
                },
            })
            .to_string(),
        )
        .unwrap();
    }

    /// Finding from review #TASK-2763: a DELETE that lands before the commit
    /// claim must win — the CLI may already have exited 0 with a valid
    /// auth.json, and finalize must still refuse to commit the reserved
    /// account and must clean it up.
    #[tokio::test]
    async fn cancelled_session_never_commits_even_when_the_cli_succeeded() {
        let dir = tempdir().unwrap();
        let config = crate::test_support::with_gateway_auth(GaryxConfig::default());
        let state = crate::server::AppStateBuilder::new(config)
            .with_config_path(dir.path().join("config.yaml"))
            .build();
        let target = codex_provider_accounts::prepare_codex_auth_target(
            &state,
            Some("Cancelled"),
            None,
        )
        .await
        .unwrap();
        let home = target.codex_home.clone().expect("managed home reserved");
        write_valid_auth_json(&home);
        let session = Arc::new(CodexAuthSession::new("login-toctou".to_owned(), target));

        // DELETE landed first...
        let cancelled = session.cancel().await;
        assert_eq!(cancelled.status, CodexAuthLoginStatus::Failed);

        // ...then the already-successful child exit reached finalize.
        finalize_success(&session, &state, Some(0)).await;

        assert_eq!(
            session.snapshot().await.status,
            CodexAuthLoginStatus::Failed,
            "a cancelled session must not flip to Succeeded"
        );
        assert!(
            state
                .config_snapshot()
                .provider_accounts
                .codex
                .accounts
                .is_empty(),
            "a cancelled session must not commit its reserved account"
        );
        assert!(!home.exists(), "the reserved profile must be cleaned up");
    }

    /// The inverse ordering: once finalize claimed the commit, a racing
    /// cancel is too late and must not flip the session while the account
    /// commit lands.
    #[tokio::test]
    async fn cancel_after_the_finalize_claim_is_a_no_op() {
        let dir = tempdir().unwrap();
        let config = crate::test_support::with_gateway_auth(GaryxConfig::default());
        let state = crate::server::AppStateBuilder::new(config)
            .with_config_path(dir.path().join("config.yaml"))
            .build();
        let target = codex_provider_accounts::prepare_codex_auth_target(
            &state,
            Some("Committed"),
            None,
        )
        .await
        .unwrap();
        let home = target.codex_home.clone().expect("managed home reserved");
        let account_id = target.account_id.clone().expect("reserved account id");
        write_valid_auth_json(&home);
        let session = Arc::new(CodexAuthSession::new("login-claimed".to_owned(), target));

        assert!(session.try_claim_finalize().await);
        let raced = session.cancel().await;
        assert_ne!(
            raced.status,
            CodexAuthLoginStatus::Failed,
            "cancel after the claim must not mark the session failed"
        );

        finalize_success(&session, &state, Some(0)).await;
        assert_eq!(
            session.snapshot().await.status,
            CodexAuthLoginStatus::Succeeded
        );
        assert!(
            state
                .config_snapshot()
                .provider_accounts
                .codex
                .account(&account_id)
                .is_some(),
            "the claimed commit must land"
        );
    }

    #[tokio::test]
    async fn codex_auth_exit_zero_without_auth_json_fails_and_cleans_up() {
        let dir = tempdir().unwrap();
        let fake_codex = write_fake_codex(dir.path());
        let config = crate::test_support::with_gateway_auth(GaryxConfig::default());
        let state = crate::server::AppStateBuilder::new(config)
            .with_config_path(dir.path().join("config.yaml"))
            .build();
        state
            .ops
            .codex_auth_sessions
            .set_codex_bin_override_for_test(fake_codex)
            .await;
        let router = crate::route_graph::build_router(state.clone());

        let (status, start) = start_auth(&router, r#"{"managed_account_name":"Keyring"}"#).await;
        assert_eq!(status, StatusCode::CREATED);
        let account_id = start.account_id.clone().expect("managed account id");
        let account_dir = dir.path().join("provider-accounts/codex").join(&account_id);

        fs::write(dir.path().join("authorized-empty"), "ok").unwrap();
        let failed = poll_status(&router, &start.login_id, CodexAuthLoginStatus::Failed).await;
        assert!(
            failed
                .error
                .as_deref()
                .unwrap_or_default()
                .contains("not readable after login"),
            "{:?}",
            failed.error
        );

        for _ in 0..100 {
            if !account_dir.exists() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert!(!account_dir.exists(), "failed profile should be removed");
        assert!(
            state
                .config_snapshot()
                .provider_accounts
                .codex
                .accounts
                .is_empty()
        );
    }

    #[tokio::test]
    async fn ambiguous_codex_auth_target_is_rejected() {
        let dir = tempdir().unwrap();
        let config = crate::test_support::with_gateway_auth(GaryxConfig::default());
        let state = crate::server::AppStateBuilder::new(config)
            .with_config_path(dir.path().join("config.yaml"))
            .build();
        let router = crate::route_graph::build_router(state);

        let response = router
            .oneshot(
                crate::test_support::authed_request()
                    .method("POST")
                    .uri("/api/providers/codex/auth/start")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        r#"{"managed_account_name":"Work","account_id":"00000000-0000-4000-8000-000000000001"}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    }

    #[test]
    fn device_output_parsing_matches_real_codex_output() {
        // Lines captured from codex-cli 0.144.0 `codex login --device-auth`.
        let url_line = strip_ansi("   \u{1b}[94mhttps://auth.openai.com/codex/device\u{1b}[0m");
        assert_eq!(
            extract_url(&url_line).as_deref(),
            Some("https://auth.openai.com/codex/device")
        );
        let code_line = strip_ansi("   \u{1b}[94mSAIW-E7TI9\u{1b}[0m");
        assert_eq!(extract_user_code(&code_line).as_deref(), Some("SAIW-E7TI9"));

        // Banner/step lines must not be misread as codes.
        for line in [
            "Welcome to Codex [v0.144.0]",
            "1. Open this link in your browser and sign in to your account",
            "2. Enter this one-time code (expires in 15 minutes)",
            "",
        ] {
            assert_eq!(extract_user_code(&strip_ansi(line)), None, "{line:?}");
        }
    }

    /// Assert a non-direct descendant (the fake launcher's grandchild) is
    /// gone. It is reparented on its parent's death, so only liveness can be
    /// probed — there is nothing to reap here.
    async fn assert_process_gone(pid: libc::pid_t) {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            let result = unsafe { libc::kill(pid, 0) };
            if result != 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH) {
                return;
            }
            if Instant::now() >= deadline {
                unsafe {
                    libc::kill(pid, libc::SIGKILL);
                }
                panic!("process {pid} survived the process-group kill");
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }

    async fn assert_child_reaped(pid: libc::pid_t) {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            let result = unsafe { libc::kill(pid, 0) };
            if result != 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH) {
                return;
            }
            if Instant::now() >= deadline {
                let mut status = 0;
                let wait_result = unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) };
                if wait_result == 0 {
                    unsafe {
                        libc::kill(pid, libc::SIGKILL);
                        libc::waitpid(pid, &mut status, 0);
                    }
                }
                panic!("codex login child {pid} was not reaped; waitpid returned {wait_result}");
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }
}
