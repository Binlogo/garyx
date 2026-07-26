use super::*;
use wiremock::matchers::{header, method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

fn rerun_current_test_with_isolated_default_token(
    child_marker: &'static str,
) -> Option<std::process::Output> {
    if std::env::var_os(child_marker).is_some() {
        return None;
    }

    let isolated_home = tempfile::tempdir().expect("isolated home");
    let test_name = std::thread::current()
        .name()
        .expect("test thread name")
        .to_owned();
    Some(
        std::process::Command::new(std::env::current_exe().expect("current test executable"))
            .arg("--exact")
            .arg(test_name)
            .arg("--nocapture")
            .env(child_marker, "1")
            .env("HOME", isolated_home.path())
            .env_remove("USERPROFILE")
            .env("CLAUDE_CODE_OAUTH_TOKEN", "synthetic-default-token")
            .env_remove("ANTHROPIC_AUTH_TOKEN")
            .env_remove("CLAUDE_OAUTH_TOKEN")
            .output()
            .expect("managed-scope child test"),
    )
}

#[test]
fn maps_codex_presets_with_model_specific_reasoning() {
    let discovery = codex_builtin_models(None);

    assert_eq!(discovery.source, "codex_builtin");
    assert_eq!(discovery.default_model.as_deref(), Some("gpt-5.5"));
    assert_eq!(discovery.models[0].id, "gpt-5.5");
    assert!(discovery.models[0].recommended);
    assert_eq!(discovery.models[0].service_tiers[0].id, "priority");
    assert_eq!(discovery.models[0].service_tiers[0].label, "Fast");
    assert_eq!(
        discovery.models[0].default_reasoning_effort.as_deref(),
        Some("medium")
    );
    assert_eq!(discovery.models[0].supported_reasoning_efforts[0].id, "low");
    assert_eq!(discovery.service_tiers[0].id, "priority");
    assert_eq!(discovery.reasoning_efforts[1].id, "medium");
    assert!(discovery.reasoning_efforts[1].recommended);
}

#[test]
fn codex_configured_unknown_default_model_does_not_reuse_previous_options() {
    let discovery = apply_default_model_to_codex_discovery(
        codex_builtin_models(None),
        Some("gpt-6-turbo".to_owned()),
    );

    assert_eq!(discovery.default_model.as_deref(), Some("gpt-6-turbo"));
    assert!(discovery.reasoning_efforts.is_empty());
    assert!(discovery.service_tiers.is_empty());
}

#[tokio::test]
async fn claude_code_catalog_ignores_empty_configured_provider_default_reasoning_effort() {
    let _cache_guard = isolate_provider_model_discovery_cache_for_tests();
    let mut config = GaryxConfig::default();
    config.agents.insert(
        "claude".to_owned(),
        json!({
            "provider_type": "claude_code",
            "default_model": "claude-opus-4-8",
            "model_reasoning_effort": "  "
        }),
    );

    let response = list_provider_models(
        &config,
        ProviderType::ClaudeCode,
        ClaudeCatalogScope::system(),
    )
    .await;
    let payload = serde_json::to_value(response).expect("provider models response");

    assert_eq!(payload["default_model"], "claude-opus-4-8");
    assert!(payload.get("default_reasoning_effort").is_none());
}

#[tokio::test]
async fn antigravity_model_catalog_defaults_to_claude_opus() {
    let response = list_provider_models(
        &GaryxConfig::default(),
        ProviderType::AntigravityCli,
        ClaudeCatalogScope::system(),
    )
    .await;

    assert_eq!(response.provider_type, ProviderType::AntigravityCli);
    assert!(response.supports_model_selection);
    assert_eq!(response.source, "antigravity_builtin");
    assert_eq!(
        response.default_model.as_deref(),
        Some("Claude Opus 4.6 (Thinking)")
    );
    assert!(
        response
            .models
            .iter()
            .any(|model| model.id == "Claude Sonnet 4.6 (Thinking)")
    );
    assert!(
        response
            .models
            .iter()
            .any(|model| model.id == "Gemini 3.6 Flash (High)")
    );
}

#[tokio::test]
async fn grok_catalog_uses_acp_source_and_configured_defaults() {
    let _cache_guard = isolate_provider_model_discovery_cache_for_tests();
    let mut config = GaryxConfig::default();
    config.agents.insert(
        "grok".to_owned(),
        json!({
            "provider_type": "grok_build",
            "default_model": "grok-test-model",
            "model_reasoning_effort": "high",
            "grok_bin": "/path/that/does/not/exist/grok"
        }),
    );

    let response = list_provider_models(
        &config,
        ProviderType::GrokBuild,
        ClaudeCatalogScope::system(),
    )
    .await;

    assert_eq!(response.provider_type, ProviderType::GrokBuild);
    assert_eq!(response.source, "grok_acp");
    assert_eq!(response.default_model.as_deref(), Some("grok-test-model"));
    assert_eq!(response.default_reasoning_effort.as_deref(), Some("high"));
    assert!(!response.supports_service_tier_selection);
    assert!(response.error.is_some());
}

#[tokio::test]
async fn claude_code_model_catalog_supports_selection_and_reasoning() {
    let _cache_guard = isolate_provider_model_discovery_cache_for_tests();
    let response = list_provider_models(
        &GaryxConfig::default(),
        ProviderType::ClaudeCode,
        ClaudeCatalogScope::system(),
    )
    .await;

    assert_eq!(response.provider_type, ProviderType::ClaudeCode);
    assert!(response.supports_model_selection);
    assert!(response.supports_reasoning_effort_selection);
    assert_eq!(response.source, "claude_code_builtin");
    // The CLI's account default is unknowable, so no default is claimed and
    // the model-less effort list is the intersection every model supports.
    assert_eq!(response.default_model, None);
    let expected: &[(&str, &str, &[&str])] = &[
        (
            "claude-opus-5",
            "Claude Opus 5",
            &["low", "medium", "high", "xhigh", "max"],
        ),
        (
            "claude-sonnet-5",
            "Claude Sonnet 5",
            &["low", "medium", "high", "xhigh", "max"],
        ),
        (
            "claude-fable-5",
            "Claude Fable 5",
            &["low", "medium", "high", "xhigh", "max"],
        ),
        (
            "claude-opus-4-8",
            "Claude Opus 4.8",
            &["low", "medium", "high", "xhigh", "max"],
        ),
        (
            "claude-opus-4-7",
            "Claude Opus 4.7",
            &["low", "medium", "high", "xhigh", "max"],
        ),
        (
            "claude-sonnet-4-6",
            "Claude Sonnet 4.6",
            &["low", "medium", "high", "max"],
        ),
        (
            "claude-opus-4-6",
            "Claude Opus 4.6",
            &["low", "medium", "high", "max"],
        ),
        (
            "claude-opus-4-5",
            "Claude Opus 4.5",
            &["low", "medium", "high"],
        ),
        ("claude-haiku-4-5", "Claude Haiku 4.5", &[]),
        ("claude-sonnet-4-5", "Claude Sonnet 4.5", &[]),
        ("claude-opus-4-1", "Claude Opus 4.1", &[]),
    ];
    assert_eq!(response.models.len(), expected.len());
    for (model, (expected_id, expected_label, expected_efforts)) in
        response.models.iter().zip(expected)
    {
        assert_eq!(&model.id, expected_id);
        assert_eq!(&model.label, expected_label);
        assert_eq!(
            model
                .supported_reasoning_efforts
                .iter()
                .map(|effort| effort.id.as_str())
                .collect::<Vec<_>>(),
            *expected_efforts
        );
        assert_eq!(
            model.default_reasoning_effort.as_deref(),
            (!expected_efforts.is_empty()).then_some("high")
        );
    }
    assert_eq!(
        response
            .reasoning_efforts
            .iter()
            .map(|effort| effort.id.as_str())
            .collect::<Vec<_>>(),
        common_reasoning_efforts(&response.models)
            .iter()
            .map(|effort| effort.id.as_str())
            .collect::<Vec<_>>()
    );
    assert!(response.reasoning_efforts.is_empty());
    assert!(!response.supports_service_tier_selection);
}

#[tokio::test]
async fn claude_code_dynamic_catalog_maps_models_and_efforts() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/v1/models"))
        .and(header("authorization", "Bearer test-claude-token"))
        .and(header("anthropic-version", "2023-06-01"))
        .and(header("anthropic-beta", "oauth-2025-04-20"))
        .and(header("user-agent", crate::claude_oauth::CLAUDE_USER_AGENT))
        .and(header("accept", "application/json"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "data": [
                {
                    "id": "claude-empty-effort-20260101",
                    "display_name": "Claude Empty Effort",
                    "created_at": "2026-01-01T00:00:00Z",
                    "capabilities": {
                        "effort": {
                            "supported": true,
                            "low": { "supported": false },
                            "medium": { "supported": false }
                        }
                    }
                },
                {
                    "id": "claude-opus-4-8-20260201",
                    "display_name": "  Claude Opus 4.8  ",
                    "created_at": "2026-02-01T00:00:00Z",
                    "capabilities": {
                        "effort": {
                            "supported": true,
                            "low": { "supported": true },
                            "medium": { "supported": true },
                            "high": { "supported": true },
                            "xhigh": { "supported": true },
                            "max": { "supported": true }
                        }
                    }
                },
                {
                    "id": "claude-sonnet-4-6-20260115",
                    "display_name": "",
                    "created_at": "2026-01-15T00:00:00Z",
                    "capabilities": {
                        "effort": {
                            "supported": true,
                            "low": { "supported": true },
                            "medium": { "supported": true },
                            "high": { "supported": true }
                        }
                    }
                },
                {
                    "id": "claude-haiku-4-5-20251215",
                    "display_name": "Claude Haiku 4.5",
                    "created_at": "2025-12-15T00:00:00Z",
                    "capabilities": {
                        "effort": {
                            "supported": true,
                            "low": { "supported": true },
                            "medium": { "supported": true },
                            "high": { "supported": true }
                        }
                    }
                },
                {
                    "id": "claude-fable-5-20251201",
                    "display_name": "Claude Fable 5",
                    "created_at": "2025-12-01T00:00:00Z",
                    "capabilities": {
                        "effort": {
                            "supported": true,
                            "low": { "supported": true },
                            "medium": { "supported": true },
                            "high": { "supported": true },
                            "xhigh": { "supported": true },
                            "max": { "supported": true }
                        }
                    }
                },
                {
                    "id": "claude-opus-4-7-20251101",
                    "display_name": "Claude Opus 4.7",
                    "created_at": "2025-11-01T00:00:00Z",
                    "capabilities": {
                        "effort": {
                            "supported": true,
                            "low": { "supported": true },
                            "medium": { "supported": true },
                            "high": { "supported": true },
                            "xhigh": { "supported": true }
                        }
                    }
                },
                {
                    "id": "claude-sonnet-4-5-20251001",
                    "display_name": "Claude Sonnet 4.5",
                    "created_at": "2025-10-01T00:00:00Z",
                    "capabilities": {
                        "effort": {
                            "supported": true,
                            "low": { "supported": true },
                            "medium": { "supported": true },
                            "high": { "supported": true },
                            "max": { "supported": true }
                        }
                    }
                },
                {
                    "id": "claude-no-effort",
                    "display_name": "Claude No Effort",
                    "created_at": null,
                    "capabilities": { "effort": { "supported": false } }
                },
                {
                    "id": "claude-missing-created-b",
                    "display_name": "Claude Missing Created B",
                    "created_at": null,
                    "capabilities": { "effort": { "supported": false } }
                },
                {
                    "id": "",
                    "display_name": "Skipped"
                }
            ]
        })))
        .mount(&server)
        .await;

    let discovery = fetch_claude_code_models_from_endpoint(
        &server.uri(),
        "test-claude-token",
        Duration::from_secs(5),
    )
    .await
    .expect("mock Claude model catalog");

    assert_eq!(discovery.source, "claude_code_api");
    assert_eq!(
        discovery
            .models
            .iter()
            .map(|model| model.id.as_str())
            .collect::<Vec<_>>(),
        vec![
            "claude-opus-4-8-20260201",
            "claude-sonnet-4-6-20260115",
            "claude-empty-effort-20260101",
            "claude-haiku-4-5-20251215",
            "claude-fable-5-20251201",
            "claude-opus-4-7-20251101",
            "claude-sonnet-4-5-20251001",
            "claude-no-effort",
            "claude-missing-created-b",
        ]
    );
    let opus = &discovery.models[0];
    assert_eq!(opus.label, "Claude Opus 4.8");
    assert_eq!(opus.default_reasoning_effort, None);
    assert_eq!(
        opus.supported_reasoning_efforts
            .iter()
            .map(|effort| effort.id.as_str())
            .collect::<Vec<_>>(),
        vec!["low", "medium", "high", "xhigh", "max"]
    );
    let sonnet = &discovery.models[1];
    assert_eq!(sonnet.label, "Claude Sonnet 4 6");
    assert_eq!(
        sonnet
            .supported_reasoning_efforts
            .iter()
            .map(|effort| effort.id.as_str())
            .collect::<Vec<_>>(),
        vec!["low", "medium", "high"]
    );
    assert_eq!(discovery.models.len(), 9);
    assert!(discovery.models[2].supported_reasoning_efforts.is_empty());
    assert!(discovery.models[7].supported_reasoning_efforts.is_empty());
    assert!(discovery.models[8].supported_reasoning_efforts.is_empty());
    assert!(discovery.default_model.is_none());
    assert!(discovery.reasoning_efforts.is_empty());
}

#[tokio::test]
async fn claude_code_effort_blind_catalog_degrades_without_replacing_last_good_cache() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/v1/models"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "data": [
                {
                    "id": "claude-effort-blind",
                    "display_name": "Claude Effort Blind",
                    "created_at": "2026-07-01T00:00:00Z",
                    "capabilities": {
                        "batch": { "supported": true }
                    }
                }
            ]
        })))
        .expect(1)
        .mount(&server)
        .await;
    let effort_blind_result = fetch_claude_code_models_from_endpoint(
        &server.uri(),
        "synthetic-managed-token",
        Duration::from_secs(5),
    )
    .await;

    let _cache_guard = isolate_provider_model_discovery_cache_for_tests();
    let cache_key = "test_claude_effort_floor";
    let last_good = ProviderModelDiscovery {
        models: vec![ProviderModelOption {
            id: "claude-last-good".to_owned(),
            label: "Claude Last Good".to_owned(),
            description: None,
            recommended: false,
            default_reasoning_effort: Some("high".to_owned()),
            supported_reasoning_efforts: reasoning_efforts("high", &["low", "medium", "high"]),
            service_tiers: Vec::new(),
        }],
        default_model: None,
        reasoning_efforts: reasoning_efforts("high", &["low", "medium", "high"]),
        service_tiers: Vec::new(),
        source: "claude_code_api",
        error: None,
    };
    let stored = discover_or_fallback(cache_key, Ok(last_good), |error| {
        claude_code_builtin_models(Some(error))
    });
    assert_eq!(stored.models[0].id, "claude-last-good");
    let degraded = discover_or_fallback(cache_key, effort_blind_result, |error| {
        claude_code_builtin_models(Some(error))
    });
    let cached_after_degradation = cached_discovery(cache_key).expect("last-good cache");
    let blocked_retry = discover_or_fallback(
        cache_key,
        Err("healthy payload blocked".to_owned()),
        |error| claude_code_builtin_models(Some(error)),
    );

    assert_eq!(degraded.models[0].id, "claude-last-good");
    assert_eq!(degraded.source, "claude_code_api");
    assert_eq!(
        degraded.error.as_deref(),
        Some("Claude model catalog response carried no effort capability metadata")
    );
    assert_eq!(cached_after_degradation.models[0].id, "claude-last-good");
    assert_eq!(blocked_retry.models[0].id, "claude-last-good");
}

#[test]
fn claude_code_effort_floor_without_stale_uses_capable_builtin_catalog() {
    let _cache_guard = isolate_provider_model_discovery_cache_for_tests();

    let discovery = discover_or_fallback(
        "test_claude_effort_floor_without_stale",
        Err(CLAUDE_EFFORT_CAPABILITY_FLOOR_ERROR.to_owned()),
        |error| claude_code_builtin_models(Some(error)),
    );

    assert_eq!(discovery.source, "claude_code_builtin");
    assert_eq!(
        discovery.error.as_deref(),
        Some(CLAUDE_EFFORT_CAPABILITY_FLOOR_ERROR)
    );
    assert!(provider_supports_reasoning_effort_selection(
        &discovery.models
    ));
}

#[tokio::test]
async fn claude_code_explicitly_unsupported_effort_remains_authoritative() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/v1/models"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "data": [{
                "id": "claude-explicit-no-effort",
                "display_name": "Claude Explicit No Effort",
                "capabilities": {
                    "effort": { "supported": false }
                }
            }]
        })))
        .expect(1)
        .mount(&server)
        .await;

    let discovery = fetch_claude_code_models_from_endpoint(
        &server.uri(),
        "synthetic-managed-token",
        Duration::from_secs(5),
    )
    .await
    .expect("explicit effort withdrawal is still an effort-aware catalog");

    assert_eq!(discovery.source, "claude_code_api");
    assert_eq!(discovery.models[0].id, "claude-explicit-no-effort");
    assert!(discovery.models[0].supported_reasoning_efforts.is_empty());
}

#[test]
fn claude_code_catalog_cache_does_not_bleed_across_active_accounts() {
    let _cache_guard = isolate_provider_model_discovery_cache_for_tests();
    let account_a_scope = ClaudeCatalogScope::managed(
        "account-a".to_owned(),
        Some(std::path::PathBuf::from(
            "/Users/test/.garyx/provider-accounts/claude-code/account-a",
        )),
    );
    assert_eq!(account_a_scope.cache_key(), "claude_code:account-a");
    assert_eq!(
        ClaudeCatalogScope::system().cache_key(),
        "claude_code:system"
    );
    let account_a_discovery = ProviderModelDiscovery {
        models: vec![ProviderModelOption {
            id: "claude-account-a-only".to_owned(),
            label: "Claude Account A Only".to_owned(),
            description: None,
            recommended: false,
            default_reasoning_effort: Some("high".to_owned()),
            supported_reasoning_efforts: reasoning_efforts("high", &["high"]),
            service_tiers: Vec::new(),
        }],
        default_model: None,
        reasoning_efforts: reasoning_efforts("high", &["high"]),
        service_tiers: Vec::new(),
        source: "claude_code_api",
        error: None,
    };
    discover_or_fallback(
        &account_a_scope.cache_key(),
        Ok(account_a_discovery),
        |error| claude_code_builtin_models(Some(error)),
    );

    let account_b_scope = ClaudeCatalogScope::managed(
        "account-b".to_owned(),
        Some(std::path::PathBuf::from(
            "/Users/test/.garyx/provider-accounts/claude-code/account-b",
        )),
    );
    let account_b_discovery = discover_or_fallback(
        &account_b_scope.cache_key(),
        Err("account B catalog unavailable".to_owned()),
        |error| claude_code_builtin_models(Some(error)),
    );

    assert!(
        account_b_discovery
            .models
            .iter()
            .all(|model| model.id != "claude-account-a-only"),
        "account B must not reuse account A's cached catalog"
    );
    assert_eq!(account_b_discovery.source, "claude_code_builtin");
    assert_eq!(
        account_b_discovery.error.as_deref(),
        Some("account B catalog unavailable")
    );
    assert_eq!(
        cached_discovery(&account_a_scope.cache_key())
            .expect("account A cache")
            .models[0]
            .id,
        "claude-account-a-only"
    );
}

#[tokio::test]
async fn claude_code_system_scope_keeps_the_default_credential_chain() {
    const CHILD_MARKER: &str = "GARYX_TEST_SYSTEM_CATALOG_DEFAULT_CHAIN_CHILD";
    if let Some(output) = rerun_current_test_with_isolated_default_token(CHILD_MARKER) {
        assert!(
            output.status.success(),
            "system credential child failed:\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        return;
    }

    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/v1/models"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "data": [{
                "id": "claude-system-model",
                "display_name": "Claude System Model",
                "capabilities": {
                    "effort": {
                        "supported": true,
                        "high": { "supported": true }
                    }
                }
            }]
        })))
        .expect(1)
        .mount(&server)
        .await;

    let discovery = fetch_claude_code_models_for_scope_from_endpoint(
        &ClaudeCatalogScope::system(),
        &server.uri(),
        Duration::from_secs(5),
    )
    .await
    .expect("system catalog credentials");
    let requests = server
        .received_requests()
        .await
        .expect("received request log");

    assert_eq!(discovery.source, "claude_code_api");
    assert_eq!(discovery.models[0].id, "claude-system-model");
    assert_eq!(requests.len(), 1);
    assert!(requests[0].headers.contains_key("authorization"));
}

#[tokio::test]
async fn claude_code_managed_scope_uses_its_credential_file_for_catalog_fetch() {
    const CHILD_MARKER: &str = "GARYX_TEST_MANAGED_CATALOG_FILE_CHILD";
    if let Some(output) = rerun_current_test_with_isolated_default_token(CHILD_MARKER) {
        assert!(
            output.status.success(),
            "managed credential child failed:\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        return;
    }

    let managed_dir = tempfile::tempdir().expect("managed config dir");
    std::fs::write(
        managed_dir.path().join(".credentials.json"),
        json!({
            "claudeAiOauth": {
                "accessToken": "synthetic-managed-token",
                "subscriptionType": "max"
            }
        })
        .to_string(),
    )
    .expect("managed credentials");
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/v1/models"))
        .and(header("authorization", "Bearer synthetic-managed-token"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "data": [{
                "id": "claude-managed-model",
                "capabilities": {
                    "effort": {
                        "supported": true,
                        "high": { "supported": true }
                    }
                }
            }]
        })))
        .expect(1)
        .mount(&server)
        .await;
    let scope = ClaudeCatalogScope::managed(
        "managed-file-account".to_owned(),
        Some(managed_dir.path().to_path_buf()),
    );

    let discovery = fetch_claude_code_models_for_scope_from_endpoint(
        &scope,
        &server.uri(),
        Duration::from_secs(5),
    )
    .await
    .expect("managed catalog credentials must be used");

    assert_eq!(discovery.models[0].id, "claude-managed-model");
}

#[tokio::test]
async fn claude_code_managed_scope_never_falls_back_to_default_credentials() {
    const CHILD_MARKER: &str = "GARYX_TEST_MANAGED_CATALOG_NO_FALLBACK_CHILD";
    if let Some(output) = rerun_current_test_with_isolated_default_token(CHILD_MARKER) {
        assert!(
            output.status.success(),
            "managed no-fallback child failed:\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        return;
    }

    let managed_root = tempfile::tempdir().expect("managed root");
    let missing_config_dir = managed_root.path().join("missing-managed-account");
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/v1/models"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "data": [{
                "id": "claude-default-chain-model",
                "capabilities": {
                    "effort": {
                        "supported": true,
                        "high": { "supported": true }
                    }
                }
            }]
        })))
        .expect(0)
        .mount(&server)
        .await;
    let scope = ClaudeCatalogScope::managed(
        "missing-managed-account".to_owned(),
        Some(missing_config_dir),
    );

    let result = fetch_claude_code_models_for_scope_from_endpoint(
        &scope,
        &server.uri(),
        Duration::from_secs(5),
    )
    .await;

    assert!(
        result.is_err(),
        "managed scope must fail instead of borrowing default credentials"
    );
}

#[tokio::test]
async fn claude_code_empty_catalog_keeps_the_existing_no_models_fallback() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/v1/models"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "data": [] })))
        .expect(1)
        .mount(&server)
        .await;
    let result = fetch_claude_code_models_from_endpoint(
        &server.uri(),
        "synthetic-managed-token",
        Duration::from_secs(5),
    )
    .await;

    let _cache_guard = isolate_provider_model_discovery_cache_for_tests();
    let discovery = discover_or_fallback("test_claude_empty_models", result, |error| {
        claude_code_builtin_models(Some(error))
    });

    assert_eq!(discovery.source, "claude_code_builtin");
    assert_eq!(
        discovery.error.as_deref(),
        Some("claude_code_api returned no models")
    );
}

#[tokio::test]
async fn claude_code_dynamic_catalog_non_200_and_timeout_are_errors() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/v1/models"))
        .respond_with(ResponseTemplate::new(503).set_body_string("upstream details stay short"))
        .mount(&server)
        .await;

    let error = fetch_claude_code_models_from_endpoint(
        &server.uri(),
        "test-claude-token",
        Duration::from_secs(5),
    )
    .await
    .expect_err("non-200 should error");
    assert!(error.contains("HTTP 503"), "unexpected error: {error}");
    assert!(!error.contains("upstream details stay short"));

    let slow_server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/v1/models"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_delay(Duration::from_millis(50))
                .set_body_json(json!({ "data": [] })),
        )
        .mount(&slow_server)
        .await;
    let error = fetch_claude_code_models_from_endpoint(
        &slow_server.uri(),
        "test-claude-token",
        Duration::from_millis(1),
    )
    .await
    .expect_err("timeout should error");
    assert!(error.contains("timed out"), "unexpected error: {error}");
}

#[test]
fn claude_code_fallback_preserves_nonempty_builtin_catalog() {
    let _cache_guard = isolate_provider_model_discovery_cache_for_tests();

    let discovery = discover_or_fallback(
        "test_claude_fallback",
        Err("Claude OAuth token unavailable".to_owned()),
        |error| claude_code_builtin_models(Some(error)),
    );

    assert_eq!(discovery.source, "claude_code_builtin");
    assert!(discovery.error.as_deref().unwrap_or("").contains("OAuth"));
    assert!(!discovery.models.is_empty());
    assert!(provider_supports_reasoning_effort_selection(
        &discovery.models
    ));
}

#[test]
fn discover_or_fallback_prefers_stale_success_before_builtin_preset() {
    let _cache_guard = isolate_provider_model_discovery_cache_for_tests();
    let cached = ProviderModelDiscovery {
        models: vec![ProviderModelOption {
            id: "claude-stale".to_owned(),
            label: "Claude Stale".to_owned(),
            description: None,
            recommended: false,
            default_reasoning_effort: None,
            supported_reasoning_efforts: reasoning_efforts("low", &["low"]),
            service_tiers: Vec::new(),
        }],
        default_model: None,
        reasoning_efforts: Vec::new(),
        service_tiers: Vec::new(),
        source: "claude_code_api",
        error: None,
    };
    let success = discover_or_fallback("test_claude_stale", Ok(cached), |error| {
        claude_code_builtin_models(Some(error))
    });
    assert_eq!(success.source, "claude_code_api");

    let stale = discover_or_fallback(
        "test_claude_stale",
        Err("network down".to_owned()),
        |error| claude_code_builtin_models(Some(error)),
    );

    assert_eq!(stale.source, "claude_code_api");
    assert_eq!(stale.models[0].id, "claude-stale");
    assert_eq!(stale.error.as_deref(), Some("network down"));
}

#[test]
fn non_claude_discovery_cache_keys_keep_their_contract_names() {
    assert_eq!(CODEX_APP_SERVER_CACHE_KEY, "codex_app_server");
    assert_eq!(TRAEX_CACHE_KEY, "traex");
    assert_eq!(GROK_ACP_CACHE_KEY, "grok_acp");
}

#[tokio::test]
async fn claude_code_catalog_uses_configured_provider_default_model() {
    let _cache_guard = isolate_provider_model_discovery_cache_for_tests();
    let mut config = GaryxConfig::default();
    config.agents.insert(
        "claude".to_owned(),
        json!({
            "provider_type": "claude_code",
            "default_model": "claude-opus-4-8",
            "model_reasoning_effort": "max"
        }),
    );

    let response = list_provider_models(
        &config,
        ProviderType::ClaudeCode,
        ClaudeCatalogScope::system(),
    )
    .await;

    assert_eq!(response.default_model.as_deref(), Some("claude-opus-4-8"));
}

#[tokio::test]
async fn claude_code_catalog_exposes_configured_provider_default_reasoning_effort() {
    let _cache_guard = isolate_provider_model_discovery_cache_for_tests();
    let mut config = GaryxConfig::default();
    config.agents.insert(
        "claude".to_owned(),
        json!({
            "provider_type": "claude_code",
            "default_model": "claude-opus-4-8",
            "model_reasoning_effort": "max"
        }),
    );

    let response = list_provider_models(
        &config,
        ProviderType::ClaudeCode,
        ClaudeCatalogScope::system(),
    )
    .await;
    let payload = serde_json::to_value(response).expect("provider models response");

    assert_eq!(payload["default_reasoning_effort"], "max");
}

#[tokio::test]
async fn codex_app_server_model_catalog_supports_selection_and_reasoning() {
    let _cache_guard = isolate_provider_model_discovery_cache_for_tests();
    let response = list_provider_models(
        &GaryxConfig::default(),
        ProviderType::CodexAppServer,
        ClaudeCatalogScope::system(),
    )
    .await;

    assert_eq!(response.provider_type, ProviderType::CodexAppServer);
    assert!(response.supports_model_selection);
    assert!(response.supports_reasoning_effort_selection);
    assert_eq!(response.source, "codex_builtin");
    assert!(response.default_model.is_none());
    assert!(!response.models.is_empty());
    assert!(!response.reasoning_efforts.is_empty());
}

#[tokio::test]
async fn codex_app_server_catalog_uses_configured_provider_default_model() {
    let _cache_guard = isolate_provider_model_discovery_cache_for_tests();
    let mut config = GaryxConfig::default();
    config.agents.insert(
        "codex".to_owned(),
        json!({
            "provider_type": "codex_app_server",
            "default_model": "gpt-5.4"
        }),
    );

    let response = list_provider_models(
        &config,
        ProviderType::CodexAppServer,
        ClaudeCatalogScope::system(),
    )
    .await;

    assert_eq!(response.default_model.as_deref(), Some("gpt-5.4"));
}

#[test]
fn parse_app_server_models_maps_catalog_and_reasoning() {
    let result = json!({
        "data": [
            {
                "id": "glm-5", "model": "glm-5", "displayName": "GLM-5",
                "description": "smart", "defaultReasoningEffort": "medium",
                "isDefault": false, "hidden": false,
                "supportedReasoningEfforts": [
                    {"reasoningEffort": "low", "description": "lo"},
                    {"reasoningEffort": "medium", "description": "med"}
                ]
            },
            {
                "id": "gpt-5.5", "model": "gpt-5.5", "displayName": "GPT-5.5",
                "description": "", "defaultReasoningEffort": "high",
                "isDefault": true, "hidden": false,
                "supportedReasoningEfforts": [
                    {"reasoningEffort": "high", "description": "hi"}
                ]
            },
            {
                "id": "secret", "model": "secret", "displayName": "Secret",
                "hidden": true, "defaultReasoningEffort": "low",
                "isDefault": false, "supportedReasoningEfforts": []
            }
        ]
    });

    let discovery = parse_app_server_models(&result, "traex_app_server");

    assert_eq!(discovery.source, "traex_app_server");
    // Hidden models are filtered out.
    assert_eq!(discovery.models.len(), 2);
    assert!(!discovery.models.iter().any(|model| model.id == "secret"));
    // Default comes from the `isDefault` flag.
    assert_eq!(discovery.default_model.as_deref(), Some("gpt-5.5"));
    // Top-level reasoning efforts come from the default model.
    assert_eq!(discovery.reasoning_efforts.len(), 1);
    assert_eq!(discovery.reasoning_efforts[0].id, "high");
    assert!(discovery.reasoning_efforts[0].recommended);
    // Per-model reasoning options are mapped with the default marked.
    let glm = discovery
        .models
        .iter()
        .find(|model| model.id == "glm-5")
        .expect("glm-5 present");
    assert_eq!(glm.label, "GLM-5");
    assert_eq!(glm.default_reasoning_effort.as_deref(), Some("medium"));
    assert_eq!(glm.supported_reasoning_efforts.len(), 2);
    assert!(
        glm.supported_reasoning_efforts
            .iter()
            .any(|effort| effort.id == "medium" && effort.recommended)
    );
}

#[test]
fn provider_reasoning_support_uses_any_model_effort() {
    let result = json!({
        "data": [
            {
                "id": "doubao-empty", "model": "doubao-empty", "displayName": "Doubao",
                "isDefault": true, "hidden": false, "supportedReasoningEfforts": []
            },
            {
                "id": "openrouter-3o", "model": "openrouter-3o", "displayName": null,
                "isDefault": false, "hidden": false,
                "supportedReasoningEfforts": [
                    {"reasoningEffort": "low"},
                    {"reasoningEffort": "medium"},
                    {"reasoningEffort": "high"},
                    {"reasoningEffort": "xhigh"},
                    {"reasoningEffort": "max"}
                ]
            }
        ]
    });

    let discovery = parse_app_server_models(&result, "traex_app_server");

    assert!(discovery.reasoning_efforts.is_empty());
    assert!(provider_supports_reasoning_effort_selection(
        &discovery.models
    ));
    let openrouter = discovery
        .models
        .iter()
        .find(|model| model.id == "openrouter-3o")
        .expect("openrouter model");
    assert_eq!(openrouter.label, "openrouter-3o");
    assert_eq!(
        openrouter
            .supported_reasoning_efforts
            .iter()
            .map(|effort| effort.id.as_str())
            .collect::<Vec<_>>(),
        vec!["low", "medium", "high", "xhigh", "max"]
    );
}

#[test]
fn parse_app_server_models_expands_context_window_variants() {
    let result = json!({
        "data": [
            {
                "id": "gpt-5.5", "model": "GPT-5.5", "displayName": "GPT-5.5",
                "description": "frontier", "defaultReasoningEffort": "medium",
                "isDefault": false, "hidden": false, "supportedReasoningEfforts": [],
                "businessMetadata": { "variants": {
                    "standard_key": "gpt-5.5__dev", "standard_context_window": 272000,
                    "max_key": "gpt-5.5__max", "max_context_window": 1000000
                }}
            },
            {
                "id": "glm-5", "model": "glm-5", "displayName": "GLM-5",
                "description": "", "defaultReasoningEffort": "medium",
                "isDefault": false, "hidden": false, "supportedReasoningEfforts": [],
                "businessMetadata": { "variants": {
                    "standard_key": "glm-5__dev", "standard_context_window": 200000,
                    "max_key": null, "max_context_window": null
                }}
            }
        ]
    });

    let discovery = parse_app_server_models(&result, "traex_app_server");
    let ids: Vec<&str> = discovery.models.iter().map(|m| m.id.as_str()).collect();
    // gpt-5.5 has a Max variant -> two options; glm-5 has only Standard -> one.
    assert_eq!(ids, vec!["gpt-5.5__dev", "gpt-5.5__max", "glm-5"]);
    let std = &discovery.models[0];
    assert_eq!(std.label, "GPT-5.5 / Standard");
    assert_eq!(std.description.as_deref(), Some("272K context window"));
    let max = &discovery.models[1];
    assert_eq!(max.label, "GPT-5.5 / Max");
    assert_eq!(max.description.as_deref(), Some("1M context window"));
    // Single-variant model keeps its plain display name.
    assert_eq!(discovery.models[2].label, "GLM-5");
}

// Real end-to-end discovery against the local `traex` binary. Opt-in via
// GARYX_ALLOW_REAL_APP_SERVER_MODEL_FETCH=1 (mirrors the Codex fetch guard)
// because it spawns `traex app-server`.
#[tokio::test]
async fn traex_app_server_real_discovery_lists_models() {
    if std::env::var_os("GARYX_ALLOW_REAL_APP_SERVER_MODEL_FETCH").is_none() {
        return;
    }
    let _cache_guard = isolate_provider_model_discovery_cache_for_tests();
    let response = list_provider_models(
        &GaryxConfig::default(),
        ProviderType::Traex,
        ClaudeCatalogScope::system(),
    )
    .await;
    assert_eq!(response.provider_type, ProviderType::Traex);
    assert_eq!(response.source, "traex_app_server");
    assert!(
        !response.models.is_empty(),
        "expected dynamically discovered traex models"
    );
    assert!(response.supports_model_selection);
    // The picker should be available when any discovered Traex model
    // advertises selectable reasoning efforts, even if the default model does
    // not.
    assert!(response.supports_reasoning_effort_selection);
}

#[tokio::test]
async fn codex_app_server_real_discovery_lists_models_with_reasoning() {
    if std::env::var_os("GARYX_ALLOW_REAL_APP_SERVER_MODEL_FETCH").is_none() {
        return;
    }
    let _cache_guard = isolate_provider_model_discovery_cache_for_tests();
    let response = list_provider_models(
        &GaryxConfig::default(),
        ProviderType::CodexAppServer,
        ClaudeCatalogScope::system(),
    )
    .await;
    assert_eq!(response.provider_type, ProviderType::CodexAppServer);
    assert_eq!(response.source, "codex_app_server");
    assert!(!response.models.is_empty());
    // Codex models advertise reasoning efforts; the picker should be on.
    assert!(response.supports_reasoning_effort_selection);
    // Service tiers are now plumbed to thread/start, so Codex advertises
    // them (e.g. Fast/priority).
    assert!(response.supports_service_tier_selection);
    assert!(!response.service_tiers.is_empty());
}
