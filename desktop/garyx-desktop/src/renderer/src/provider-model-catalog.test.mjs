import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

import {
  resolveComposerModelControlState,
} from './composer-model-control.ts';
import { ProviderModelCatalog } from './provider-model-catalog.ts';

const degradedCatalog = JSON.parse(
  readFileSync(
    new URL('./fixtures/provider-models-claude-code-degraded.json', import.meta.url),
    'utf8',
  ),
);
const healthyCatalog = {
  ...degradedCatalog,
  models: [
    {
      id: 'claude-opus-5',
      label: 'Claude Opus 5',
      recommended: true,
      supportedReasoningEfforts: [
        { id: 'low', label: 'Low', recommended: false },
        { id: 'high', label: 'High', recommended: true },
        { id: 'max', label: 'Max', recommended: false },
      ],
    },
  ],
  supportsReasoningEffortSelection: true,
  reasoningEfforts: [
    { id: 'low', label: 'Low', recommended: false },
    { id: 'high', label: 'High', recommended: true },
    { id: 'max', label: 'Max', recommended: false },
  ],
  defaultModel: 'claude-opus-5',
};

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, reject, resolve };
}

test('failed refresh keeps the previous snapshot and exposes no error state', async () => {
  let fail = false;
  const store = new ProviderModelCatalog(async () => {
    if (fail) {
      throw new Error('transient catalog failure');
    }
    return degradedCatalog;
  });
  store.setGatewayScope('gateway-a');

  assert.equal(await store.refresh('claude_code'), true);
  const previous = store.getSnapshot().catalogs.claude_code;
  fail = true;
  assert.equal(await store.refresh('claude_code'), false);

  assert.strictEqual(store.getSnapshot().catalogs.claude_code, previous);
  assert.equal(store.getSnapshot().refreshing.claude_code, false);
  assert.equal('error' in store.getSnapshot(), false);
});

test('foreground refresh retries a known provider after a cold-start failure', async () => {
  let attempts = 0;
  const store = new ProviderModelCatalog(async () => {
    attempts += 1;
    if (attempts === 1) {
      throw new Error('cold-start catalog failure');
    }
    return healthyCatalog;
  });
  store.setGatewayScope('gateway-a');

  assert.equal(await store.refresh('claude_code'), false);
  assert.equal(store.getSnapshot().catalogs.claude_code, undefined);
  await store.refreshKnown();

  assert.equal(attempts, 2);
  assert.strictEqual(
    store.getSnapshot().catalogs.claude_code,
    healthyCatalog,
  );
});

test('successful refresh replaces a degraded snapshot without restarting', async () => {
  let nextCatalog = degradedCatalog;
  const store = new ProviderModelCatalog(async () => nextCatalog);
  store.setGatewayScope('gateway-a');

  await store.refresh('claude_code');
  const degradedState = resolveComposerModelControlState({
    providerModels: store.getSnapshot().catalogs.claude_code,
    effectiveModel: 'claude-opus-5',
    effectiveReasoningEffort: 'max',
    modelFallbackLabel: 'Model',
    thinkingLevelFallbackLabel: 'Thinking level',
    standardServiceTierLabel: 'Standard',
  });
  assert.equal(
    store.getSnapshot().catalogs.claude_code.models.some(
      (model) => model.id === 'claude-opus-5',
    ),
    false,
  );
  assert.equal(degradedState.triggerLabel, 'claude-opus-5 · max');
  assert.equal(degradedState.showsReasoningControl, true);

  nextCatalog = healthyCatalog;
  assert.equal(await store.refresh('claude_code'), true);
  const healthyState = resolveComposerModelControlState({
    providerModels: store.getSnapshot().catalogs.claude_code,
    effectiveModel: 'claude-opus-5',
    effectiveReasoningEffort: 'max',
    modelFallbackLabel: 'Model',
    thinkingLevelFallbackLabel: 'Thinking level',
    standardServiceTierLabel: 'Standard',
  });
  assert.equal(
    store.getSnapshot().catalogs.claude_code.models.find(
      (model) => model.id === 'claude-opus-5',
    )?.label,
    'Claude Opus 5',
  );
  assert.deepEqual(
    store.getSnapshot().catalogs.claude_code.reasoningEfforts.map(
      (effort) => effort.id,
    ),
    ['low', 'high', 'max'],
  );
  assert.equal(healthyState.triggerLabel, 'Claude Opus 5 · Max');
  assert.equal(healthyState.showsReasoningControl, true);
});

test('concurrent triggers for one provider share one in-flight request', async () => {
  const load = deferred();
  let calls = 0;
  const store = new ProviderModelCatalog(() => {
    calls += 1;
    return load.promise;
  });
  store.setGatewayScope('gateway-a');

  const first = store.refresh('claude_code');
  const second = store.refresh('claude_code');
  await Promise.resolve();
  assert.equal(calls, 1);
  assert.equal(store.getSnapshot().refreshing.claude_code, true);

  load.resolve(healthyCatalog);
  assert.deepEqual(await Promise.all([first, second]), [true, true]);
  assert.equal(calls, 1);
  assert.equal(store.getSnapshot().refreshing.claude_code, false);
});

test('refresh-state subscribers reenter the same single-flight request', async () => {
  const load = deferred();
  let calls = 0;
  const store = new ProviderModelCatalog(() => {
    calls += 1;
    return load.promise;
  });
  store.setGatewayScope('gateway-a');

  let reentrant;
  const unsubscribe = store.subscribe(() => {
    if (store.getSnapshot().refreshing.claude_code && !reentrant) {
      reentrant = store.refresh('claude_code');
    }
  });
  const first = store.refresh('claude_code');

  assert.strictEqual(reentrant, first);
  await Promise.resolve();
  assert.equal(calls, 1);
  load.resolve(healthyCatalog);
  assert.deepEqual(await Promise.all([first, reentrant]), [true, true]);
  unsubscribe();
});

test('gateway switch clears the cache and rejects a late old-scope response', async () => {
  const late = deferred();
  let first = true;
  let calls = 0;
  const store = new ProviderModelCatalog(async () => {
    calls += 1;
    if (first) {
      first = false;
      return degradedCatalog;
    }
    return late.promise;
  });
  store.setGatewayScope('gateway-a');
  await store.refresh('claude_code');
  const stale = store.refresh('claude_code');

  store.setGatewayScope('gateway-b');
  assert.deepEqual(store.getSnapshot(), { catalogs: {}, refreshing: {} });
  late.resolve(healthyCatalog);

  assert.equal(await stale, false);
  assert.deepEqual(store.getSnapshot(), { catalogs: {}, refreshing: {} });
  await store.refreshKnown();
  assert.equal(calls, 2);
});
