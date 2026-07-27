use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use garyx_models::codex_models::{
    CodexModelPreset, CodexModelServiceTier, CodexReasoningEffort, CodexReasoningEffortPreset,
    codex_builtin_model_presets,
};
use garyx_models::config::{AgentProviderConfig, GaryxConfig};
use garyx_models::provider::ProviderType;
use serde::Serialize;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::time::timeout;

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ProviderModelOption {
    pub id: String,
    pub label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub recommended: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_reasoning_effort: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub supported_reasoning_efforts: Vec<ProviderReasoningEffortOption>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub service_tiers: Vec<ProviderModelOption>,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ProviderReasoningEffortOption {
    pub id: String,
    pub label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub recommended: bool,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ProviderModelsResponse {
    pub provider_type: ProviderType,
    pub supports_model_selection: bool,
    pub models: Vec<ProviderModelOption>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub supports_reasoning_effort_selection: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub reasoning_efforts: Vec<ProviderReasoningEffortOption>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub supports_service_tier_selection: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub service_tiers: Vec<ProviderModelOption>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_reasoning_effort: Option<String>,
    pub source: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct ProviderCatalogDefault {
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub service_tier: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct ClaudeCatalogScope {
    account_id: Option<String>,
    config_dir: Option<PathBuf>,
}

impl ClaudeCatalogScope {
    pub(crate) fn system() -> Self {
        Self::default()
    }

    pub(crate) fn managed(account_id: String, config_dir: Option<PathBuf>) -> Self {
        Self {
            account_id: Some(account_id),
            config_dir,
        }
    }

    pub(crate) fn cache_key(&self) -> String {
        match self.account_id.as_deref() {
            Some(account_id) => format!("claude_code:{account_id}"),
            None => "claude_code:system".to_owned(),
        }
    }

    #[cfg(test)]
    pub(crate) fn config_dir(&self) -> Option<&Path> {
        self.config_dir.as_deref()
    }

    fn managed_config_dir(&self) -> Result<Option<&Path>, String> {
        match self.account_id.as_ref() {
            Some(_) => self.config_dir.as_deref().map(Some).ok_or_else(|| {
                "Claude managed catalog scope had no validated config directory".to_owned()
            }),
            None => Ok(None),
        }
    }
}

#[derive(Debug, Clone)]
struct ProviderModelDiscovery {
    models: Vec<ProviderModelOption>,
    default_model: Option<String>,
    reasoning_efforts: Vec<ProviderReasoningEffortOption>,
    service_tiers: Vec<ProviderModelOption>,
    source: &'static str,
    error: Option<String>,
}

type CodexModelDiscovery = ProviderModelDiscovery;

pub(crate) async fn list_provider_models(
    config: &GaryxConfig,
    provider_type: ProviderType,
    claude_catalog_scope: ClaudeCatalogScope,
) -> ProviderModelsResponse {
    match provider_type {
        ProviderType::AntigravityCli => {
            let aliases = &["antigravity", "agy", "antigravity_cli"];
            let default_model =
                configured_default_model(config, ProviderType::AntigravityCli, aliases)
                    .unwrap_or_else(garyx_models::provider::default_antigravity_model);
            builtin_model_catalog_response(
                provider_type,
                "antigravity_builtin",
                antigravity_models(),
                &default_model,
                configured_default_reasoning_effort(config, ProviderType::AntigravityCli, aliases),
            )
        }
        ProviderType::ClaudeCode => {
            // The CLI's actual default model is account/plan dependent and not
            // statically knowable unless the gateway config pins one. Without
            // a chosen model, only the levels every model supports are offered.
            let aliases = &["claude", "claude_code", "claude_tty"];
            let default_model = configured_default_model(config, ProviderType::ClaudeCode, aliases);
            let default_reasoning_effort =
                configured_default_reasoning_effort(config, ProviderType::ClaudeCode, aliases);
            let cache_key = claude_catalog_scope.cache_key();
            let mut discovery = match fresh_cached_discovery(&cache_key) {
                Some(discovery) => discovery,
                None => {
                    let result = fetch_claude_code_models(&claude_catalog_scope).await;
                    discover_or_fallback(&cache_key, result, |error| {
                        claude_code_builtin_models(Some(error))
                    })
                }
            };
            discovery.reasoning_efforts =
                reasoning_efforts_for_default_model(&discovery.models, default_model.as_deref());
            let supports_reasoning_effort_selection =
                provider_supports_reasoning_effort_selection(&discovery.models);
            ProviderModelsResponse {
                provider_type,
                supports_model_selection: true,
                supports_reasoning_effort_selection,
                reasoning_efforts: discovery.reasoning_efforts,
                models: discovery.models,
                supports_service_tier_selection: false,
                service_tiers: Vec::new(),
                default_model,
                default_reasoning_effort,
                source: discovery.source,
                error: discovery.error,
            }
        }
        ProviderType::CodexAppServer | ProviderType::Traex => {
            let aliases: &[&str] = if provider_type == ProviderType::Traex {
                &["traex", "trae", "trae_cli", "traecli"]
            } else {
                &["codex", "codex_app_server"]
            };
            // Discover models dynamically from the app-server's `model/list`
            // (reflects the real backend catalog); fall back to the static
            // preset list if the binary is unavailable or discovery fails.
            let source: &'static str = if provider_type == ProviderType::Traex {
                "traex_app_server"
            } else {
                "codex_app_server"
            };
            let configured_default_reasoning_effort =
                configured_default_reasoning_effort(config, provider_type.clone(), aliases);
            let bin = app_server_model_bin(&provider_type);
            let cache_key = if provider_type == ProviderType::Traex {
                TRAEX_CACHE_KEY.to_owned()
            } else {
                CODEX_APP_SERVER_CACHE_KEY.to_owned()
            };
            let mut discovery = match fresh_cached_discovery(&cache_key) {
                Some(discovery) => discovery,
                None => {
                    let result = fetch_app_server_models(bin, source).await;
                    if provider_type == ProviderType::Traex {
                        discover_or_fallback(&cache_key, result, traex_unavailable_models)
                    } else {
                        discover_or_fallback(&cache_key, result, |error| {
                            codex_builtin_models(Some(error))
                        })
                    }
                }
            };
            if let Some(default_model) =
                configured_default_model(config, provider_type.clone(), aliases)
            {
                discovery = apply_default_model_to_codex_discovery(discovery, Some(default_model));
            } else if discovery.source == "codex_builtin" {
                // Builtin presets have no meaningful default; dynamic discovery
                // keeps the backend-reported default.
                discovery.default_model = None;
            }
            let supports_reasoning_effort_selection =
                provider_supports_reasoning_effort_selection(&discovery.models);
            ProviderModelsResponse {
                provider_type,
                supports_model_selection: !discovery.models.is_empty(),
                models: discovery.models,
                // Derive from the full discovered catalog: some providers expose
                // a default model with no effort controls while another model
                // does support them.
                supports_reasoning_effort_selection,
                reasoning_efforts: discovery.reasoning_efforts,
                supports_service_tier_selection: !discovery.service_tiers.is_empty(),
                service_tiers: discovery.service_tiers,
                default_model: discovery.default_model,
                default_reasoning_effort: configured_default_reasoning_effort,
                source: discovery.source,
                error: discovery.error,
            }
        }
        ProviderType::GrokBuild => {
            let aliases = &["grok", "grok_build", "grok-build"];
            let configured_model =
                configured_default_model(config, ProviderType::GrokBuild, aliases);
            let configured_reasoning =
                configured_default_reasoning_effort(config, ProviderType::GrokBuild, aliases);
            let cache_key = GROK_ACP_CACHE_KEY.to_owned();
            let discovery = match fresh_cached_discovery(&cache_key) {
                Some(discovery) => discovery,
                None => discover_or_fallback(
                    &cache_key,
                    fetch_grok_models(config).await,
                    grok_unavailable_models,
                ),
            };
            let default_model = configured_model.or(discovery.default_model.clone());
            let reasoning_efforts =
                reasoning_efforts_for_default_model(&discovery.models, default_model.as_deref());
            ProviderModelsResponse {
                provider_type,
                supports_model_selection: !discovery.models.is_empty(),
                supports_reasoning_effort_selection: provider_supports_reasoning_effort_selection(
                    &discovery.models,
                ),
                models: discovery.models,
                reasoning_efforts,
                supports_service_tier_selection: false,
                service_tiers: Vec::new(),
                default_model,
                default_reasoning_effort: configured_reasoning,
                source: discovery.source,
                error: discovery.error,
            }
        }
    }
}

pub(crate) fn builtin_provider_catalog_default(
    provider_type: ProviderType,
) -> ProviderCatalogDefault {
    match provider_type {
        ProviderType::AntigravityCli => ProviderCatalogDefault {
            model: Some(garyx_models::provider::default_antigravity_model()),
            reasoning_effort: None,
            service_tier: None,
        },
        ProviderType::ClaudeCode
        | ProviderType::CodexAppServer
        | ProviderType::Traex
        | ProviderType::GrokBuild => ProviderCatalogDefault::default(),
    }
}

mod app_server;
mod cache;
mod catalog;
mod claude_code;
mod codex;
mod grok;
pub(crate) mod process_rpc;

use app_server::*;
use cache::*;
use catalog::*;
use claude_code::*;
use codex::*;
use grok::*;
use process_rpc::*;

#[cfg(test)]
pub(crate) fn isolate_provider_model_discovery_cache_for_tests()
-> std::sync::MutexGuard<'static, ()> {
    static TEST_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    let guard = TEST_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    clear_provider_model_discovery_cache_for_tests();
    guard
}

#[cfg(test)]
pub(crate) fn store_claude_catalog_for_tests(scope: &ClaudeCatalogScope, model_id: &str) {
    let supported_reasoning_efforts = reasoning_efforts("high", &["high"]);
    store_discovery(
        &scope.cache_key(),
        ProviderModelDiscovery {
            models: vec![ProviderModelOption {
                id: model_id.to_owned(),
                label: friendly_model_label(model_id),
                description: None,
                recommended: false,
                default_reasoning_effort: Some("high".to_owned()),
                supported_reasoning_efforts: supported_reasoning_efforts.clone(),
                service_tiers: Vec::new(),
            }],
            default_model: None,
            reasoning_efforts: supported_reasoning_efforts,
            service_tiers: Vec::new(),
            source: "claude_code_api",
            error: None,
        },
    );
}

#[cfg(test)]
mod tests;
