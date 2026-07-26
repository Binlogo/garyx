use super::*;

pub(super) fn builtin_model_catalog_response(
    provider_type: ProviderType,
    source: &'static str,
    models: Vec<ProviderModelOption>,
    default_model: &str,
    default_reasoning_effort: Option<String>,
) -> ProviderModelsResponse {
    let reasoning_efforts = models
        .iter()
        .find(|model| model.id == default_model)
        .or_else(|| models.first())
        .map(|model| model.supported_reasoning_efforts.clone())
        .unwrap_or_default();
    let supports_reasoning_effort_selection = provider_supports_reasoning_effort_selection(&models);
    ProviderModelsResponse {
        provider_type,
        supports_model_selection: true,
        models,
        supports_reasoning_effort_selection,
        reasoning_efforts,
        supports_service_tier_selection: false,
        service_tiers: Vec::new(),
        default_model: Some(default_model.to_owned()),
        default_reasoning_effort,
        source,
        error: None,
    }
}

pub(super) fn reasoning_efforts(
    default: &str,
    supported: &[&str],
) -> Vec<ProviderReasoningEffortOption> {
    supported
        .iter()
        .copied()
        .filter_map(|id| {
            reasoning_effort_metadata(id).map(|(id, label, description)| {
                ProviderReasoningEffortOption {
                    id: id.to_owned(),
                    label: label.to_owned(),
                    description: Some(description.to_owned()),
                    recommended: id == default,
                }
            })
        })
        .collect()
}

pub(super) fn reasoning_effort_metadata(
    id: &str,
) -> Option<(&'static str, &'static str, &'static str)> {
    match id {
        "off" => Some(("off", "Off", "Disable explicit thinking controls.")),
        "minimal" => Some((
            "minimal",
            "Minimal",
            "Use the smallest explicit reasoning budget.",
        )),
        "low" => Some((
            "low",
            "Low",
            "Prefer lower latency and lower reasoning budget.",
        )),
        "medium" => Some((
            "medium",
            "Medium",
            "Balanced reasoning budget for normal coding tasks.",
        )),
        "high" => Some((
            "high",
            "High",
            "Use a larger reasoning budget for harder tasks.",
        )),
        "xhigh" => Some((
            "xhigh",
            "Extra High",
            "Use the highest supported adaptive reasoning effort.",
        )),
        "max" => Some(("max", "Max", "Maximum capability with deepest reasoning.")),
        "ultra" => Some((
            "ultra",
            "Ultra",
            "Maximum reasoning with automatic task delegation.",
        )),
        _ => None,
    }
}

fn model_option(
    id: &str,
    label: &str,
    description: &str,
    supported_reasoning_efforts: Vec<ProviderReasoningEffortOption>,
) -> ProviderModelOption {
    let default_reasoning_effort = supported_reasoning_efforts
        .iter()
        .find(|effort| effort.recommended)
        .map(|effort| effort.id.clone());
    ProviderModelOption {
        id: id.to_owned(),
        label: label.to_owned(),
        description: Some(description.to_owned()),
        recommended: false,
        default_reasoning_effort,
        supported_reasoning_efforts,
        service_tiers: Vec::new(),
    }
}

/// Reasoning levels supported by every model in the catalog, preserving the
/// first model's ordering. Used when no model is chosen so any selectable
/// level stays valid regardless of which model the CLI resolves.
pub(super) fn common_reasoning_efforts(
    models: &[ProviderModelOption],
) -> Vec<ProviderReasoningEffortOption> {
    let Some(first) = models.first() else {
        return Vec::new();
    };
    first
        .supported_reasoning_efforts
        .iter()
        .filter(|effort| {
            models.iter().all(|model| {
                model
                    .supported_reasoning_efforts
                    .iter()
                    .any(|candidate| candidate.id == effort.id)
            })
        })
        .cloned()
        .collect()
}

/// Current public Claude catalog used only when live discovery is unavailable.
pub(super) fn claude_code_models() -> Vec<ProviderModelOption> {
    let standard_efforts = reasoning_efforts("high", &["low", "medium", "high"]);
    let extended_efforts = reasoning_efforts("high", &["low", "medium", "high", "max"]);
    let deep_efforts = reasoning_efforts("high", &["low", "medium", "high", "xhigh", "max"]);
    vec![
        model_option(
            "claude-opus-5",
            "Claude Opus 5",
            "Most capable Claude model for the hardest and longest-running work.",
            deep_efforts.clone(),
        ),
        model_option(
            "claude-sonnet-5",
            "Claude Sonnet 5",
            "Frontier Claude model for everyday complex work.",
            deep_efforts.clone(),
        ),
        model_option(
            "claude-fable-5",
            "Claude Fable 5",
            "Claude model for complex, long-running work.",
            deep_efforts.clone(),
        ),
        model_option(
            "claude-opus-4-8",
            "Claude Opus 4.8",
            "Highly capable model for hard, long-running tasks.",
            deep_efforts.clone(),
        ),
        model_option(
            "claude-opus-4-7",
            "Claude Opus 4.7",
            "Highly capable model for hard, long-running tasks.",
            deep_efforts.clone(),
        ),
        model_option(
            "claude-sonnet-4-6",
            "Claude Sonnet 4.6",
            "Best for everyday, complex tasks.",
            extended_efforts.clone(),
        ),
        model_option(
            "claude-opus-4-6",
            "Claude Opus 4.6",
            "Capable model for complex tasks.",
            extended_efforts,
        ),
        model_option(
            "claude-opus-4-5",
            "Claude Opus 4.5",
            "Claude model for complex tasks.",
            standard_efforts,
        ),
        model_option(
            "claude-haiku-4-5",
            "Claude Haiku 4.5",
            "Fastest for quick answers.",
            Vec::new(),
        ),
        model_option(
            "claude-sonnet-4-5",
            "Claude Sonnet 4.5",
            "Claude model for everyday tasks.",
            Vec::new(),
        ),
        model_option(
            "claude-opus-4-1",
            "Claude Opus 4.1",
            "Earlier Claude model for complex tasks.",
            Vec::new(),
        ),
    ]
}

pub(super) fn antigravity_models() -> Vec<ProviderModelOption> {
    [
        (
            "Claude Opus 4.6 (Thinking)",
            "Default Antigravity model; uses the Claude backend through the local agy CLI.",
            true,
        ),
        (
            "Claude Sonnet 4.6 (Thinking)",
            "Claude option exposed by the local agy CLI.",
            false,
        ),
        (
            "Gemini 3.6 Flash (Low)",
            "Antigravity Gemini option; may be subject to Google AI Platform location limits.",
            false,
        ),
        (
            "Gemini 3.6 Flash (Medium)",
            "Antigravity Gemini option; may be subject to Google AI Platform location limits.",
            false,
        ),
        (
            "Gemini 3.6 Flash (High)",
            "Antigravity Gemini option; may be subject to Google AI Platform location limits.",
            false,
        ),
        (
            "Gemini 3.5 Flash (Low)",
            "Antigravity Gemini option; may be subject to Google AI Platform location limits.",
            false,
        ),
        (
            "Gemini 3.5 Flash (Medium)",
            "Antigravity Gemini option; may be subject to Google AI Platform location limits.",
            false,
        ),
        (
            "Gemini 3.5 Flash (High)",
            "Antigravity Gemini option; may be subject to Google AI Platform location limits.",
            false,
        ),
        (
            "Gemini 3.1 Pro (Low)",
            "Antigravity Gemini option; may be subject to Google AI Platform location limits.",
            false,
        ),
        (
            "Gemini 3.1 Pro (High)",
            "Antigravity Gemini option; may be subject to Google AI Platform location limits.",
            false,
        ),
        (
            "GPT-OSS 120B (Medium)",
            "Antigravity open model option exposed by the local agy CLI.",
            false,
        ),
    ]
    .into_iter()
    .map(|(id, description, recommended)| ProviderModelOption {
        id: id.to_owned(),
        label: id.to_owned(),
        description: Some(description.to_owned()),
        recommended,
        default_reasoning_effort: None,
        supported_reasoning_efforts: Vec::new(),
        service_tiers: Vec::new(),
    })
    .collect()
}
