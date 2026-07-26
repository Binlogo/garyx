import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

import {
  resolveComposerModelControlState,
  shouldClearServiceTierForModelSelection,
} from './composer-model-control.ts';

const degradedProviderModels = JSON.parse(
  readFileSync(
    new URL('./fixtures/provider-models-claude-code-degraded.json', import.meta.url),
    'utf8',
  ),
);

const providerModels = {
  providerType: 'claude_code',
  supportsModelSelection: true,
  models: [
    {
      id: 'claude-opus-4-8',
      label: 'Claude Opus 4.8',
      recommended: false,
      defaultReasoningEffort: 'high',
      supportedReasoningEfforts: [
        { id: 'low', label: 'Low', recommended: false },
        { id: 'medium', label: 'Medium', recommended: false },
        { id: 'high', label: 'High', recommended: true },
        { id: 'xhigh', label: 'Extra High', recommended: false },
        { id: 'max', label: 'Max', recommended: false },
      ],
      serviceTiers: [],
    },
    {
      id: 'claude-haiku-4-5',
      label: 'Claude Haiku 4.5',
      recommended: false,
      defaultReasoningEffort: 'high',
      supportedReasoningEfforts: [
        { id: 'low', label: 'Low', recommended: false },
        { id: 'medium', label: 'Medium', recommended: false },
        { id: 'high', label: 'High', recommended: true },
      ],
      serviceTiers: [],
    },
  ],
  supportsReasoningEffortSelection: true,
  reasoningEfforts: [
    { id: 'low', label: 'Low', recommended: false },
    { id: 'medium', label: 'Medium', recommended: false },
    { id: 'high', label: 'High', recommended: true },
  ],
  supportsServiceTierSelection: false,
  serviceTiers: [],
  defaultModel: null,
  source: 'claude_code_builtin',
};

const capabilityPoorServiceTierCatalog = {
  ...providerModels,
  providerType: 'codex_app_server',
  models: [
    {
      id: 'codex-capable',
      label: 'Codex Capable',
      recommended: true,
      supportedReasoningEfforts: [],
      serviceTiers: [
        { id: 'priority', label: 'Fast', recommended: true },
      ],
    },
  ],
  supportsReasoningEffortSelection: false,
  reasoningEfforts: [],
  supportsServiceTierSelection: false,
  serviceTiers: [],
  defaultModel: 'codex-capable',
  source: 'codex_app_server',
};

function resolve(overrides = {}) {
  return resolveComposerModelControlState({
    providerModels,
    modelFallbackLabel: 'Model',
    thinkingLevelFallbackLabel: 'Thinking level',
    standardServiceTierLabel: 'Standard',
    ...overrides,
  });
}

test('explicit model override is not treated as the default reset row', () => {
  const state = resolve({ selectedModel: 'claude-opus-4-8' });

  assert.equal(state.effectiveModelId, 'claude-opus-4-8');
  assert.equal(state.defaultModelId, '');
  assert.equal(state.defaultModelLabel, 'Model');
  assert.equal(state.triggerLabel, 'Claude Opus 4.8');
  assert.deepEqual(
    state.models.map((option) => option.id),
    ['claude-opus-4-8', 'claude-haiku-4-5'],
  );
  assert.deepEqual(
    state.reasoningEfforts.map((option) => option.id),
    ['low', 'medium', 'high', 'xhigh', 'max'],
  );
});

test('effective model can still act as default when no override is selected', () => {
  const state = resolve({ effectiveModel: 'claude-opus-4-8' });

  assert.equal(state.effectiveModelId, 'claude-opus-4-8');
  assert.equal(state.defaultModelId, 'claude-opus-4-8');
  assert.equal(state.defaultModelLabel, 'Claude Opus 4.8');
  assert.equal(state.triggerLabel, 'Claude Opus 4.8');
});

test('default catalog model labels the trigger before the user selects an override', () => {
  const state = resolve({
    providerModels: {
      ...providerModels,
      defaultModel: 'claude-opus-4-8',
    },
    agentConfiguredModel: null,
    effectiveModel: null,
    selectedModel: null,
  });

  assert.equal(state.effectiveModelId, '');
  assert.equal(state.defaultModelId, 'claude-opus-4-8');
  assert.equal(state.defaultModelLabel, 'Claude Opus 4.8');
  assert.equal(state.triggerLabel, 'Claude Opus 4.8 · High');
});

test('default catalog model supplies its full reasoning effort menu before override', () => {
  const state = resolve({
    providerModels: {
      ...providerModels,
      defaultModel: 'claude-opus-4-8',
    },
    agentConfiguredModel: null,
    effectiveModel: null,
    selectedModel: null,
    effectiveReasoningEffort: null,
    selectedReasoningEffort: null,
  });

  assert.equal(state.effectiveModelId, '');
  assert.deepEqual(
    state.reasoningEfforts.map((option) => option.id),
    ['low', 'medium', 'high', 'xhigh', 'max'],
  );
});

test('default catalog model labels the trigger with its default reasoning effort', () => {
  const state = resolve({
    providerModels: {
      ...providerModels,
      defaultModel: 'claude-opus-4-8',
    },
    agentConfiguredModel: null,
    effectiveModel: null,
    selectedModel: null,
    effectiveReasoningEffort: null,
    selectedReasoningEffort: null,
  });

  assert.equal(state.effectiveModelId, '');
  assert.equal(state.defaultReasoningEffortId, 'high');
  assert.equal(state.triggerLabel, 'Claude Opus 4.8 · High');
});

test('default catalog model prefers supported provider default reasoning effort', () => {
  const state = resolve({
    providerModels: {
      ...providerModels,
      defaultModel: 'claude-opus-4-8',
      defaultReasoningEffort: 'max',
    },
    agentConfiguredModel: null,
    effectiveModel: null,
    selectedModel: null,
    effectiveReasoningEffort: null,
    selectedReasoningEffort: null,
  });

  assert.equal(state.effectiveModelId, '');
  assert.equal(state.defaultReasoningEffortId, 'max');
  assert.equal(state.triggerLabel, 'Claude Opus 4.8 · Max');
});

test('empty provider default reasoning effort falls back to model default', () => {
  const state = resolve({
    providerModels: {
      ...providerModels,
      defaultModel: 'claude-opus-4-8',
      defaultReasoningEffort: '  ',
    },
    agentConfiguredModel: null,
    effectiveModel: null,
    selectedModel: null,
    effectiveReasoningEffort: null,
    selectedReasoningEffort: null,
  });

  assert.equal(state.defaultReasoningEffortId, 'high');
  assert.equal(state.triggerLabel, 'Claude Opus 4.8 · High');
});

test('unsupported provider default reasoning effort falls back to model default', () => {
  const state = resolve({
    providerModels: {
      ...providerModels,
      defaultModel: 'claude-haiku-4-5',
      defaultReasoningEffort: 'max',
    },
    agentConfiguredModel: null,
    effectiveModel: null,
    selectedModel: null,
    effectiveReasoningEffort: null,
    selectedReasoningEffort: null,
  });

  assert.equal(state.defaultReasoningEffortId, 'high');
  assert.equal(state.triggerLabel, 'Claude Haiku 4.5 · High');
});

test('selected reasoning effort labels trigger before provider default', () => {
  const state = resolve({
    providerModels: {
      ...providerModels,
      defaultModel: 'claude-opus-4-8',
      defaultReasoningEffort: 'max',
    },
    agentConfiguredModel: null,
    effectiveModel: null,
    selectedModel: null,
    effectiveReasoningEffort: null,
    selectedReasoningEffort: 'high',
  });

  assert.equal(state.defaultReasoningEffortId, 'max');
  assert.equal(state.effectiveReasoningEffortId, 'high');
  assert.equal(state.triggerLabel, 'Claude Opus 4.8 · High');
});

test('default catalog model keeps the selected reasoning effort suffix', () => {
  const state = resolve({
    providerModels: {
      ...providerModels,
      defaultModel: 'claude-opus-4-8',
    },
    agentConfiguredModel: null,
    effectiveModel: null,
    selectedModel: null,
    selectedReasoningEffort: 'high',
  });

  assert.equal(state.effectiveModelId, '');
  assert.equal(state.effectiveReasoningEffortId, 'high');
  assert.equal(state.triggerLabel, 'Claude Opus 4.8 · High');
});

test('selected haiku model keeps its three reasoning efforts without default suffix', () => {
  const state = resolve({ selectedModel: 'claude-haiku-4-5' });

  assert.equal(state.effectiveModelId, 'claude-haiku-4-5');
  assert.equal(state.triggerLabel, 'Claude Haiku 4.5');
  assert.deepEqual(
    state.reasoningEfforts.map((option) => option.id),
    ['low', 'medium', 'high'],
  );
});

test('selected sonnet model keeps its four reasoning efforts without default suffix', () => {
  const state = resolve({
    providerModels: {
      ...providerModels,
      models: [
        ...providerModels.models,
        {
          id: 'claude-sonnet-4-6',
          label: 'Claude Sonnet 4.6',
          recommended: false,
          defaultReasoningEffort: 'high',
          supportedReasoningEfforts: [
            { id: 'low', label: 'Low', recommended: false },
            { id: 'medium', label: 'Medium', recommended: false },
            { id: 'high', label: 'High', recommended: true },
            { id: 'max', label: 'Max', recommended: false },
          ],
          serviceTiers: [],
        },
      ],
    },
    selectedModel: 'claude-sonnet-4-6',
  });

  assert.equal(state.effectiveModelId, 'claude-sonnet-4-6');
  assert.equal(state.triggerLabel, 'Claude Sonnet 4.6');
  assert.deepEqual(
    state.reasoningEfforts.map((option) => option.id),
    ['low', 'medium', 'high', 'max'],
  );
});

test('selected model supplies reasoning efforts when provider-level efforts are empty', () => {
  const state = resolve({
    providerModels: {
      ...providerModels,
      models: [
        {
          id: 'doubao-empty',
          label: 'Doubao',
          recommended: true,
          supportedReasoningEfforts: [],
          serviceTiers: [],
        },
        {
          id: 'openrouter-3o',
          label: 'openrouter-3o',
          recommended: false,
          supportedReasoningEfforts: [
            { id: 'low', label: 'Low', recommended: false },
            { id: 'medium', label: 'Medium', recommended: false },
            { id: 'high', label: 'High', recommended: false },
            { id: 'xhigh', label: 'Extra High', recommended: false },
            { id: 'max', label: 'Max', recommended: false },
          ],
          serviceTiers: [],
        },
      ],
      reasoningEfforts: [],
      defaultModel: 'doubao-empty',
    },
    selectedModel: 'openrouter-3o',
  });

  assert.equal(state.effectiveModelId, 'openrouter-3o');
  assert.deepEqual(
    state.reasoningEfforts.map((option) => option.id),
    ['low', 'medium', 'high', 'xhigh', 'max'],
  );
});

test('default catalog model without reasoning efforts does not add a trigger suffix', () => {
  const state = resolve({
    providerModels: {
      ...providerModels,
      models: [
        {
          id: 'model-without-effort',
          label: 'Model Without Effort',
          recommended: false,
          supportedReasoningEfforts: [],
          serviceTiers: [],
        },
      ],
      reasoningEfforts: [],
      defaultModel: 'model-without-effort',
    },
    agentConfiguredModel: null,
    effectiveModel: null,
    selectedModel: null,
    effectiveReasoningEffort: null,
    selectedReasoningEffort: null,
  });

  assert.equal(state.effectiveModelId, '');
  assert.equal(state.defaultReasoningEffortId, '');
  assert.equal(state.triggerLabel, 'Model Without Effort');
  assert.deepEqual(
    state.reasoningEfforts.map((option) => option.id),
    [],
  );
});

test('model-less Claude Code menu keeps provider-level reasoning intersection', () => {
  const state = resolve();

  assert.equal(state.effectiveModelId, '');
  assert.equal(state.defaultModelId, '');
  assert.equal(state.triggerLabel, 'Model');
  assert.deepEqual(
    state.reasoningEfforts.map((option) => option.id),
    ['low', 'medium', 'high'],
  );
});

test('degraded catalog keeps the effective thinking-level control visible', () => {
  const state = resolve({
    providerModels: degradedProviderModels,
    effectiveModel: 'claude-opus-5',
    effectiveReasoningEffort: 'max',
  });

  assert.deepEqual(
    state.reasoningEfforts.map((option) => option.id),
    ['max'],
  );
  assert.equal(state.showsReasoningControl, true);
});

test('provider with no thinking levels and no effective value keeps the control hidden', () => {
  const state = resolve({
    providerModels: degradedProviderModels,
    effectiveModel: 'claude-sonnet-4-6',
  });

  assert.deepEqual(state.reasoningEfforts, []);
  assert.equal(state.showsReasoningControl, false);
  assert.deepEqual(state.serviceTiers, []);
  assert.equal(state.showsServiceTierControl, false);
});

test('capability-poor catalog does not expose per-model service tiers as choices', () => {
  const state = resolve({
    providerModels: capabilityPoorServiceTierCatalog,
    effectiveModel: 'codex-capable',
  });

  assert.deepEqual(state.serviceTiers, []);
  assert.equal(state.showsServiceTierControl, false);
});

test('capability-poor per-model tiers cannot clear or widen an effective tier row', () => {
  const state = resolve({
    providerModels: capabilityPoorServiceTierCatalog,
    effectiveModel: 'codex-capable',
    effectiveServiceTier: 'standard',
  });

  assert.deepEqual(
    state.serviceTiers.map((tier) => tier.id),
    ['standard'],
  );
  assert.equal(state.showsServiceTierControl, true);
  assert.equal(
    shouldClearServiceTierForModelSelection({
      providerModels: capabilityPoorServiceTierCatalog,
      models: state.models,
      defaultModelOption: state.defaultModelOption,
      modelId: 'codex-capable',
      effectiveServiceTierId: state.effectiveServiceTierId,
    }),
    false,
  );
});

test('degraded catalog preserves an effective service tier across model selection', () => {
  const state = resolve({
    providerModels: degradedProviderModels,
    effectiveModel: 'claude-opus-5',
    effectiveServiceTier: 'priority',
  });

  assert.deepEqual(
    state.serviceTiers.map((option) => option.id),
    ['priority'],
  );
  assert.equal(state.showsServiceTierControl, true);
  assert.equal(
    shouldClearServiceTierForModelSelection({
      providerModels: degradedProviderModels,
      models: state.models,
      defaultModelOption: state.defaultModelOption,
      modelId: 'claude-sonnet-4-6',
      effectiveServiceTierId: state.effectiveServiceTierId,
    }),
    false,
  );
});

test('healthy catalog still clears a genuinely unsupported service tier', () => {
  const serviceTierCatalog = {
    ...providerModels,
    supportsServiceTierSelection: true,
    serviceTiers: [{ id: 'standard', label: 'Standard', recommended: true }],
    models: providerModels.models.map((model) => ({
      ...model,
      serviceTiers: [{ id: 'standard', label: 'Standard', recommended: true }],
    })),
  };
  const state = resolve({
    providerModels: serviceTierCatalog,
    effectiveModel: 'claude-opus-4-8',
    effectiveServiceTier: 'priority',
  });

  assert.equal(
    shouldClearServiceTierForModelSelection({
      providerModels: serviceTierCatalog,
      models: state.models,
      defaultModelOption: state.defaultModelOption,
      modelId: 'claude-haiku-4-5',
      effectiveServiceTierId: state.effectiveServiceTierId,
    }),
    true,
  );
});

test('healthy service tiers keep their options, labels, selection, and ordering', () => {
  const serviceTiers = [
    { id: 'standard', label: 'Standard', recommended: true },
    { id: 'priority', label: 'Fast', recommended: false },
  ];
  const serviceTierCatalog = {
    ...providerModels,
    supportsServiceTierSelection: true,
    serviceTiers,
    models: providerModels.models.map((model) => ({
      ...model,
      serviceTiers,
    })),
  };
  const state = resolve({
    providerModels: serviceTierCatalog,
    effectiveModel: 'claude-opus-4-8',
    effectiveServiceTier: 'priority',
  });

  assert.deepEqual(
    state.serviceTiers.map(({ id, label }) => ({ id, label })),
    [
      { id: 'standard', label: 'Standard' },
      { id: 'priority', label: 'Fast' },
    ],
  );
  assert.equal(state.effectiveServiceTierId, 'priority');
  assert.equal(state.showsServiceTierControl, true);
  assert.equal(
    shouldClearServiceTierForModelSelection({
      providerModels: serviceTierCatalog,
      models: state.models,
      defaultModelOption: state.defaultModelOption,
      modelId: 'claude-haiku-4-5',
      effectiveServiceTierId: state.effectiveServiceTierId,
    }),
    false,
  );
});
