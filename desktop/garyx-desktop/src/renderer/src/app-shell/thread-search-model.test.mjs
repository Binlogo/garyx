import assert from "node:assert/strict";
import test from "node:test";

import {
  createThreadSearchModel,
  THREAD_SEARCH_DEBOUNCE_MS,
  THREAD_SEARCH_PAGE_LIMIT,
  threadSearchModel,
} from "./thread-search-model.ts";

function summary(id, title = id) {
  return {
    id,
    title,
    threadType: "chat",
    createdAt: "2026-07-20T10:00:00Z",
    updatedAt: "2026-07-20T11:00:00Z",
    lastMessagePreview: "Synthetic preview",
    workspacePath: "/Users/test/project",
    messageCount: 1,
    agentId: "test-agent",
    recentRunId: null,
    runState: null,
    worktree: null,
  };
}

function page({
  gatewayScope = "https://gateway.test",
  threads = [],
  nextCursor = null,
  storeIncarnationId = "incarnation-1",
  serverBootId = "boot-1",
} = {}) {
  return {
    gatewayScope,
    storeIncarnationId,
    serverBootId,
    threads,
    hasMore: nextCursor !== null,
    nextCursor,
  };
}

function beginFirstPage(model, state) {
  const debounce = model.debounceDecision(state);
  assert.ok(debounce);
  const request = model.requestFirstPage(state, debounce);
  assert.ok(request.ticket);
  return request;
}

test("query normalization is injectable while matching normalization stays server-owned", () => {
  let state = threadSearchModel.createState("https://gateway.test");
  state = threadSearchModel.engage(state);
  assert.equal(threadSearchModel.presentation(state).kind, "prompt");

  state = threadSearchModel.setQuery(state, "  Straße  ");
  assert.equal(state.rawQuery, "  Straße  ");
  assert.equal(state.query, "Straße");
  assert.equal(state.headStatus, "debouncing");
  assert.equal(THREAD_SEARCH_DEBOUNCE_MS, 250);
  assert.equal(THREAD_SEARCH_PAGE_LIMIT, 30);

  const injected = createThreadSearchModel({
    normalizeQuery: (value) => value.replaceAll(" ", "").toUpperCase(),
    debounceMs: 17,
    pageLimit: 2,
  });
  let injectedState = injected.createState("https://gateway.test");
  injectedState = injected.setQuery(injectedState, " a b ");
  const decision = injected.debounceDecision(injectedState);
  assert.equal(injectedState.query, "AB");
  assert.equal(decision?.delayMs, 17);
  const request = injected.requestFirstPage(injectedState, decision);
  assert.equal(request.ticket?.limit, 2);
});

test("empty and whitespace-only queries never produce a debounce request", () => {
  let state = threadSearchModel.createState("https://gateway.test");
  state = threadSearchModel.engage(state);
  state = threadSearchModel.setQuery(state, " \n\t ");

  assert.equal(state.engaged, true);
  assert.equal(state.query, "");
  assert.equal(threadSearchModel.debounceDecision(state), null);
  assert.deepEqual(threadSearchModel.presentation(state), {
    kind: "prompt",
    query: "",
    footerKind: "hidden",
    canLoadMore: false,
  });

  state = threadSearchModel.setQuery(state, "");
  assert.equal(state.engaged, false);
  assert.equal(threadSearchModel.debounceDecision(state), null);
});

test("a superseded query generation drops a late first-page response", () => {
  let state = threadSearchModel.createState("https://gateway.test");
  state = threadSearchModel.setQuery(state, "alpha");
  const alpha = beginFirstPage(threadSearchModel, state);
  state = alpha.state;

  state = threadSearchModel.setQuery(state, "beta");
  const beta = beginFirstPage(threadSearchModel, state);
  state = beta.state;

  const lateAlpha = threadSearchModel.completeRequest(
    state,
    alpha.ticket,
    page({ threads: [summary("thread::alpha", "Alpha")] }),
  );
  assert.equal(lateAlpha.action, "dropped");
  assert.strictEqual(lateAlpha.state, state);
  assert.deepEqual(state.rows, []);

  const currentBeta = threadSearchModel.completeRequest(
    state,
    beta.ticket,
    page({ threads: [summary("thread::beta", "Beta")] }),
  );
  assert.equal(currentBeta.action, "applied");
  assert.deepEqual(currentBeta.state.rows.map((row) => row.id), [
    "thread::beta",
  ]);
});

test("changing a query resets rows, cursor, paging failure, and request ownership", () => {
  let state = threadSearchModel.createState("https://gateway.test");
  state = threadSearchModel.setQuery(state, "first");
  const first = beginFirstPage(threadSearchModel, state);
  state = threadSearchModel.completeRequest(
    first.state,
    first.ticket,
    page({
      threads: [summary("thread::first")],
      nextCursor: "cursor-first",
    }),
  ).state;
  const generation = state.generation;

  state = threadSearchModel.setQuery(state, "second");
  assert.equal(state.generation, generation + 1);
  assert.deepEqual(state.rows, []);
  assert.equal(state.nextCursor, null);
  assert.equal(state.loadMoreFailure, null);
  assert.equal(state.activeHeadRequestId, null);
  assert.equal(state.activeLoadMoreRequestId, null);
  assert.equal(state.headStatus, "debouncing");
});

test("pagination appends in server order and deduplicates by thread id", () => {
  let state = threadSearchModel.createState("https://gateway.test");
  state = threadSearchModel.setQuery(state, "thread");
  const first = beginFirstPage(threadSearchModel, state);
  state = threadSearchModel.completeRequest(
    first.state,
    first.ticket,
    page({
      threads: [
        summary("thread::a", "A"),
        summary("thread::b", "B old"),
      ],
      nextCursor: "cursor-next",
    }),
  ).state;

  const more = threadSearchModel.requestLoadMore(state);
  assert.ok(more.ticket);
  state = threadSearchModel.completeRequest(
    more.state,
    more.ticket,
    page({
      threads: [
        summary("thread::b", "B current"),
        summary("thread::c", "C old"),
        summary("thread::c", "C current"),
      ],
    }),
  ).state;

  assert.deepEqual(state.rows.map((row) => row.id), [
    "thread::a",
    "thread::b",
    "thread::c",
  ]);
  assert.equal(state.rows[1].title, "B current");
  assert.equal(state.rows[2].title, "C current");
  assert.equal(state.nextCursor, null);
});

test("presentation derives prompt, loading, results, empty, and failed distinctly", () => {
  const prompt = threadSearchModel.engage(
    threadSearchModel.createState("https://gateway.test"),
  );
  assert.equal(threadSearchModel.presentation(prompt).kind, "prompt");

  const loading = threadSearchModel.setQuery(prompt, "named");
  assert.equal(threadSearchModel.presentation(loading).kind, "loading");

  const resultsRequest = beginFirstPage(threadSearchModel, loading);
  const results = threadSearchModel.completeRequest(
    resultsRequest.state,
    resultsRequest.ticket,
    page({
      threads: [summary("thread::named", "Named")],
      nextCursor: "cursor-more",
    }),
  ).state;
  assert.deepEqual(threadSearchModel.presentation(results), {
    kind: "results",
    query: "named",
    footerKind: "idle",
    canLoadMore: true,
  });

  const emptyLoading = threadSearchModel.setQuery(results, "missing");
  const emptyRequest = beginFirstPage(threadSearchModel, emptyLoading);
  const empty = threadSearchModel.completeRequest(
    emptyRequest.state,
    emptyRequest.ticket,
    page(),
  ).state;
  assert.equal(threadSearchModel.presentation(empty).kind, "empty");

  const failedLoading = threadSearchModel.setQuery(empty, "broken");
  const failedRequest = beginFirstPage(threadSearchModel, failedLoading);
  const failed = threadSearchModel.failRequest(
    failedRequest.state,
    failedRequest.ticket,
    new Error("Synthetic failure"),
  );
  assert.equal(threadSearchModel.presentation(failed).kind, "failed");
});

test("load-more failure stays in results and retries the same cursor", () => {
  let state = threadSearchModel.createState("https://gateway.test");
  state = threadSearchModel.setQuery(state, "named");
  const first = beginFirstPage(threadSearchModel, state);
  state = threadSearchModel.completeRequest(
    first.state,
    first.ticket,
    page({
      threads: [summary("thread::named", "Named")],
      nextCursor: "cursor-more",
    }),
  ).state;

  const more = threadSearchModel.requestLoadMore(state);
  state = threadSearchModel.failRequest(
    more.state,
    more.ticket,
    new Error("Synthetic paging failure"),
  );
  assert.deepEqual(threadSearchModel.presentation(state), {
    kind: "results",
    query: "named",
    footerKind: "loadMoreFailure",
    canLoadMore: false,
  });

  const retry = threadSearchModel.requestLoadMore(state, true);
  assert.equal(retry.ticket?.cursor, "cursor-more");
  assert.equal(
    threadSearchModel.presentation(retry.state).footerKind,
    "loadingMore",
  );
});

test("page identity drift discards the old cursor and starts a fresh generation", () => {
  let state = threadSearchModel.createState("https://gateway.test");
  state = threadSearchModel.setQuery(state, "named");
  const first = beginFirstPage(threadSearchModel, state);
  state = threadSearchModel.completeRequest(
    first.state,
    first.ticket,
    page({
      threads: [summary("thread::named", "Named")],
      nextCursor: "cursor-more",
    }),
  ).state;
  const priorGeneration = state.generation;

  const more = threadSearchModel.requestLoadMore(state);
  const drifted = threadSearchModel.completeRequest(
    more.state,
    more.ticket,
    page({
      threads: [summary("thread::later", "Later")],
      storeIncarnationId: "incarnation-2",
    }),
  );

  assert.equal(drifted.action, "dropped");
  assert.equal(drifted.state.generation, priorGeneration + 1);
  assert.equal(drifted.state.headStatus, "debouncing");
  assert.deepEqual(drifted.state.rows, []);
  assert.equal(drifted.state.nextCursor, null);
  assert.ok(threadSearchModel.debounceDecision(drifted.state));
});

test("a gateway scope change fences old responses even when their query matches", () => {
  let state = threadSearchModel.createState("https://gateway-a.test");
  state = threadSearchModel.setQuery(state, "same");
  const request = beginFirstPage(threadSearchModel, state);
  state = threadSearchModel.resetScope(
    request.state,
    "https://gateway-b.test",
  );

  const completion = threadSearchModel.completeRequest(
    state,
    request.ticket,
    page({
      gatewayScope: "https://gateway-a.test",
      threads: [summary("thread::old", "Old gateway")],
    }),
  );
  assert.equal(completion.action, "dropped");
  assert.deepEqual(completion.state.rows, []);
  assert.equal(completion.state.gatewayScope, "https://gateway-b.test");
});

test("an owned response stamped with another gateway exits loading as failed", () => {
  let state = threadSearchModel.createState("https://gateway-a.test");
  state = threadSearchModel.setQuery(state, "same");
  const request = beginFirstPage(threadSearchModel, state);

  const completion = threadSearchModel.completeRequest(
    request.state,
    request.ticket,
    page({
      gatewayScope: "https://gateway-b.test",
      threads: [summary("thread::wrong", "Wrong gateway")],
    }),
  );
  assert.equal(completion.action, "dropped");
  assert.equal(completion.state.headStatus, "failed");
  assert.equal(completion.state.activeHeadRequestId, null);
  assert.deepEqual(completion.state.rows, []);
});

test("an A to B to A gateway switch still rejects the first A generation", () => {
  let state = threadSearchModel.createState("https://gateway-a.test");
  state = threadSearchModel.setQuery(state, "same");
  const firstA = beginFirstPage(threadSearchModel, state);
  state = threadSearchModel.resetScope(
    firstA.state,
    "https://gateway-b.test",
  );
  state = threadSearchModel.resetScope(state, "https://gateway-a.test");

  const completion = threadSearchModel.completeRequest(
    state,
    firstA.ticket,
    page({
      gatewayScope: "https://gateway-a.test",
      threads: [summary("thread::first-a", "First A")],
    }),
  );
  assert.equal(completion.action, "dropped");
  assert.deepEqual(completion.state.rows, []);
  assert.ok(completion.state.generation > firstA.ticket.generation);
});
