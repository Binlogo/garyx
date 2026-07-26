import type {
  DesktopThreadSummariesPage,
  DesktopThreadSummary,
} from "@shared/contracts";
import type { RecentFeedFooterKind } from "../recent-conversation-sidebar-model";
import { compactPathLabel } from "./workspace-helpers.ts";

export const THREAD_SEARCH_DEBOUNCE_MS = 250;
export const THREAD_SEARCH_PAGE_LIMIT = 30;

export type ThreadSearchHighlightDirection = "next" | "previous";

export function threadSearchHighlightForRows(
  current: number,
  rowCount: number,
): number {
  const count = Math.max(0, Math.trunc(rowCount));
  if (count === 0) {
    return -1;
  }
  return current >= 0 && current < count ? current : 0;
}

export function moveThreadSearchHighlight(
  current: number,
  rowCount: number,
  direction: ThreadSearchHighlightDirection,
): number {
  const count = Math.max(0, Math.trunc(rowCount));
  if (count === 0) {
    return -1;
  }
  if (direction === "previous") {
    return current <= 0 || current >= count ? count - 1 : current - 1;
  }
  return current < 0 || current >= count - 1 ? 0 : current + 1;
}

export function threadSearchHighlightedItem<T>(
  rows: readonly T[],
  highlightedIndex: number,
): T | null {
  if (
    !Number.isInteger(highlightedIndex) ||
    highlightedIndex < 0 ||
    highlightedIndex >= rows.length
  ) {
    return null;
  }
  return rows[highlightedIndex] ?? null;
}

export type ThreadSearchRowMeta = {
  text: string;
  tooltip: string;
};

/**
 * Builds the trailing "agent · workspace" segment of a palette result row.
 *
 * The one-line row caps this segment, and every absolute workspace path shares
 * the same long prefix, so truncating the full path would keep only the
 * characters each row has in common and leave the column with no distinguishing
 * information. The visible copy therefore uses the workspace's last path
 * segment while the tooltip keeps the full path.
 *
 * Both strings come from this one function so the visible text and its tooltip
 * cannot drift apart.
 */
export function threadSearchRowMeta(
  thread: Pick<
    DesktopThreadSummary,
    "rootWorkspacePath" | "workspacePath" | "workspaceOrigin"
  >,
  agentLabel: string,
  noWorkspaceLabel: string,
): ThreadSearchRowMeta {
  const workspacePath =
    (thread.rootWorkspacePath ?? thread.workspacePath)?.trim() || "";
  const hasWorkspace =
    thread.workspaceOrigin !== "implicit" && Boolean(workspacePath);
  const visibleWorkspace = hasWorkspace
    ? compactPathLabel(workspacePath)
    : noWorkspaceLabel;
  const fullWorkspace = hasWorkspace ? workspacePath : noWorkspaceLabel;
  return {
    text: `${agentLabel} · ${visibleWorkspace}`,
    tooltip: `${agentLabel} · ${fullWorkspace}`,
  };
}

export type ThreadSearchHeadStatus =
  | "idle"
  | "debouncing"
  | "loading"
  | "ready"
  | "failed";

export interface ThreadSearchState {
  gatewayScope: string;
  rawQuery: string;
  query: string;
  engaged: boolean;
  generation: number;
  nextRequestId: number;
  headStatus: ThreadSearchHeadStatus;
  rows: DesktopThreadSummary[];
  nextCursor: string | null;
  isLoadingMore: boolean;
  loadMoreFailure: string | null;
  activeHeadRequestId: number | null;
  activeLoadMoreRequestId: number | null;
  storeIncarnationId: string | null;
  serverBootId: string | null;
}

export interface ThreadSearchDebounceDecision {
  gatewayScope: string;
  generation: number;
  query: string;
  delayMs: number;
}

interface ThreadSearchRequestTicketBase {
  gatewayScope: string;
  generation: number;
  requestId: number;
  query: string;
  limit: number;
  cursor: string | null;
}

export interface ThreadSearchFirstPageTicket
  extends ThreadSearchRequestTicketBase {
  kind: "firstPage";
  cursor: null;
}

export interface ThreadSearchLoadMoreTicket
  extends ThreadSearchRequestTicketBase {
  kind: "loadMore";
  cursor: string;
}

export type ThreadSearchRequestTicket =
  | ThreadSearchFirstPageTicket
  | ThreadSearchLoadMoreTicket;

export interface ThreadSearchRequestDecision<
  Ticket extends ThreadSearchRequestTicket,
> {
  state: ThreadSearchState;
  ticket: Ticket | null;
}

export interface ThreadSearchCompletion {
  state: ThreadSearchState;
  action: "applied" | "dropped";
}

export type ThreadSearchResultsFooterKind = Extract<
  RecentFeedFooterKind,
  "hidden" | "loadingMore" | "loadMoreFailure" | "idle"
>;

export type ThreadSearchPresentation =
  | {
      kind: "prompt";
      query: "";
      footerKind: "hidden";
      canLoadMore: false;
      renderBody: false;
    }
  | {
      kind: "loading";
      query: string;
      footerKind: "initialLoading";
      canLoadMore: false;
      renderBody: true;
    }
  | {
      kind: "results";
      query: string;
      footerKind: ThreadSearchResultsFooterKind;
      canLoadMore: boolean;
      renderBody: true;
    }
  | {
      kind: "empty";
      query: string;
      footerKind: "hidden";
      canLoadMore: false;
      renderBody: true;
    }
  | {
      kind: "failed";
      query: string;
      footerKind: "initialFailure";
      canLoadMore: false;
      renderBody: true;
    };

export interface ThreadSearchModelDependencies {
  normalizeQuery: (value: string) => string;
  debounceMs: number;
  pageLimit: number;
}

function defaultNormalizeQuery(value: string): string {
  // Matching normalization (NFKC + Unicode case-fold) belongs to the Gateway.
  // The client only distinguishes empty/whitespace input from a real query.
  return value.trim();
}

function createState(gatewayScope = ""): ThreadSearchState {
  return {
    gatewayScope: gatewayScope.trim(),
    rawQuery: "",
    query: "",
    engaged: false,
    generation: 0,
    nextRequestId: 1,
    headStatus: "idle",
    rows: [],
    nextCursor: null,
    isLoadingMore: false,
    loadMoreFailure: null,
    activeHeadRequestId: null,
    activeLoadMoreRequestId: null,
    storeIncarnationId: null,
    serverBootId: null,
  };
}

function resetPageState(
  state: ThreadSearchState,
  input: {
    rawQuery: string;
    query: string;
    engaged: boolean;
    generation: number;
    headStatus: ThreadSearchHeadStatus;
    gatewayScope?: string;
  },
): ThreadSearchState {
  return {
    ...state,
    gatewayScope: input.gatewayScope ?? state.gatewayScope,
    rawQuery: input.rawQuery,
    query: input.query,
    engaged: input.engaged,
    generation: input.generation,
    headStatus: input.headStatus,
    rows: [],
    nextCursor: null,
    isLoadingMore: false,
    loadMoreFailure: null,
    activeHeadRequestId: null,
    activeLoadMoreRequestId: null,
    storeIncarnationId: null,
    serverBootId: null,
  };
}

function mergeRows(
  existing: readonly DesktopThreadSummary[],
  incoming: readonly DesktopThreadSummary[],
): DesktopThreadSummary[] {
  const rows = [...existing];
  const indexById = new Map(rows.map((row, index) => [row.id, index]));
  for (const row of incoming) {
    const id = row.id.trim();
    if (!id) {
      continue;
    }
    const existingIndex = indexById.get(id);
    if (existingIndex === undefined) {
      indexById.set(id, rows.length);
      rows.push(row);
    } else {
      rows[existingIndex] = row;
    }
  }
  return rows;
}

function requestIsOwned(
  state: ThreadSearchState,
  ticket: ThreadSearchRequestTicket,
): boolean {
  return (
    state.gatewayScope === ticket.gatewayScope &&
    state.generation === ticket.generation &&
    state.query === ticket.query &&
    (ticket.kind === "firstPage"
      ? state.activeHeadRequestId === ticket.requestId
      : state.activeLoadMoreRequestId === ticket.requestId)
  );
}

export function createThreadSearchModel(
  overrides: Partial<ThreadSearchModelDependencies> = {},
) {
  const dependencies: ThreadSearchModelDependencies = {
    normalizeQuery: overrides.normalizeQuery ?? defaultNormalizeQuery,
    debounceMs: overrides.debounceMs ?? THREAD_SEARCH_DEBOUNCE_MS,
    pageLimit: overrides.pageLimit ?? THREAD_SEARCH_PAGE_LIMIT,
  };

  function engage(state: ThreadSearchState): ThreadSearchState {
    return state.engaged ? state : { ...state, engaged: true };
  }

  function setQuery(
    state: ThreadSearchState,
    rawQuery: string,
  ): ThreadSearchState {
    const query = dependencies.normalizeQuery(rawQuery);
    const engaged = rawQuery.length > 0;
    if (query === state.query) {
      if (state.rawQuery === rawQuery && state.engaged === engaged) {
        return state;
      }
      return { ...state, rawQuery, engaged };
    }
    return resetPageState(state, {
      rawQuery,
      query,
      engaged: engaged || query.length > 0,
      generation: state.generation + 1,
      headStatus: query
        ? state.gatewayScope
          ? "debouncing"
          : "failed"
        : "idle",
    });
  }

  function clear(state: ThreadSearchState): ThreadSearchState {
    if (
      state.rawQuery.length === 0 &&
      state.query.length === 0 &&
      !state.engaged
    ) {
      return state;
    }
    return resetPageState(state, {
      rawQuery: "",
      query: "",
      engaged: false,
      generation: state.generation + (state.query ? 1 : 0),
      headStatus: "idle",
    });
  }

  function resetScope(
    state: ThreadSearchState,
    gatewayScope: string,
  ): ThreadSearchState {
    const nextScope = gatewayScope.trim();
    if (nextScope === state.gatewayScope) {
      return state;
    }
    return resetPageState(state, {
      gatewayScope: nextScope,
      rawQuery: state.rawQuery,
      query: state.query,
      engaged: state.engaged,
      generation: state.generation + 1,
      headStatus: state.query
        ? nextScope
          ? "debouncing"
          : "failed"
        : "idle",
    });
  }

  function debounceDecision(
    state: ThreadSearchState,
  ): ThreadSearchDebounceDecision | null {
    if (
      !state.engaged ||
      !state.gatewayScope ||
      !state.query ||
      state.headStatus !== "debouncing"
    ) {
      return null;
    }
    return {
      gatewayScope: state.gatewayScope,
      generation: state.generation,
      query: state.query,
      delayMs: dependencies.debounceMs,
    };
  }

  function requestFirstPage(
    state: ThreadSearchState,
    debounce?: ThreadSearchDebounceDecision,
  ): ThreadSearchRequestDecision<ThreadSearchFirstPageTicket> {
    if (
      !state.engaged ||
      !state.gatewayScope ||
      !state.query ||
      state.activeHeadRequestId !== null ||
      state.activeLoadMoreRequestId !== null ||
      (state.headStatus !== "debouncing" && state.headStatus !== "failed")
    ) {
      return { state, ticket: null };
    }
    if (
      debounce &&
      (debounce.gatewayScope !== state.gatewayScope ||
        debounce.generation !== state.generation ||
        debounce.query !== state.query)
    ) {
      return { state, ticket: null };
    }
    const requestId = state.nextRequestId;
    const ticket: ThreadSearchFirstPageTicket = {
      kind: "firstPage",
      gatewayScope: state.gatewayScope,
      generation: state.generation,
      requestId,
      query: state.query,
      limit: dependencies.pageLimit,
      cursor: null,
    };
    return {
      ticket,
      state: {
        ...state,
        nextRequestId: requestId + 1,
        headStatus: "loading",
        rows: [],
        nextCursor: null,
        isLoadingMore: false,
        loadMoreFailure: null,
        activeHeadRequestId: requestId,
        activeLoadMoreRequestId: null,
        storeIncarnationId: null,
        serverBootId: null,
      },
    };
  }

  function requestLoadMore(
    state: ThreadSearchState,
    retry = false,
  ): ThreadSearchRequestDecision<ThreadSearchLoadMoreTicket> {
    const gateAllowsRequest = retry
      ? state.loadMoreFailure !== null
      : state.loadMoreFailure === null;
    if (
      state.headStatus !== "ready" ||
      !state.gatewayScope ||
      !state.query ||
      state.rows.length === 0 ||
      state.nextCursor === null ||
      state.isLoadingMore ||
      state.activeHeadRequestId !== null ||
      state.activeLoadMoreRequestId !== null ||
      !gateAllowsRequest
    ) {
      return { state, ticket: null };
    }
    const requestId = state.nextRequestId;
    const ticket: ThreadSearchLoadMoreTicket = {
      kind: "loadMore",
      gatewayScope: state.gatewayScope,
      generation: state.generation,
      requestId,
      query: state.query,
      limit: dependencies.pageLimit,
      cursor: state.nextCursor,
    };
    return {
      ticket,
      state: {
        ...state,
        nextRequestId: requestId + 1,
        isLoadingMore: true,
        loadMoreFailure: null,
        activeLoadMoreRequestId: requestId,
      },
    };
  }

  function failRequest(
    state: ThreadSearchState,
    ticket: ThreadSearchRequestTicket,
    error: unknown,
  ): ThreadSearchState {
    if (!requestIsOwned(state, ticket)) {
      return state;
    }
    const message =
      error instanceof Error
        ? error.message
        : typeof error === "string"
          ? error
          : "Thread search request failed";
    if (ticket.kind === "firstPage") {
      return {
        ...state,
        headStatus: "failed",
        activeHeadRequestId: null,
      };
    }
    return {
      ...state,
      isLoadingMore: false,
      loadMoreFailure: message,
      activeLoadMoreRequestId: null,
    };
  }

  function completeRequest(
    state: ThreadSearchState,
    ticket: ThreadSearchRequestTicket,
    page: DesktopThreadSummariesPage,
  ): ThreadSearchCompletion {
    if (!requestIsOwned(state, ticket)) {
      return { state, action: "dropped" };
    }
    if (page.gatewayScope !== ticket.gatewayScope) {
      return {
        state: failRequest(
          state,
          ticket,
          new Error("Thread search response belongs to another Gateway"),
        ),
        action: "dropped",
      };
    }
    if (
      ticket.kind === "loadMore" &&
      (page.storeIncarnationId !== state.storeIncarnationId ||
        page.serverBootId !== state.serverBootId)
    ) {
      return {
        state: resetPageState(state, {
          rawQuery: state.rawQuery,
          query: state.query,
          engaged: state.engaged,
          generation: state.generation + 1,
          headStatus: state.gatewayScope ? "debouncing" : "failed",
        }),
        action: "dropped",
      };
    }
    if (ticket.kind === "firstPage") {
      return {
        action: "applied",
        state: {
          ...state,
          headStatus: "ready",
          rows: mergeRows([], page.threads),
          nextCursor: page.nextCursor,
          isLoadingMore: false,
          loadMoreFailure: null,
          activeHeadRequestId: null,
          storeIncarnationId: page.storeIncarnationId,
          serverBootId: page.serverBootId,
        },
      };
    }
    return {
      action: "applied",
      state: {
        ...state,
        rows: mergeRows(state.rows, page.threads),
        nextCursor: page.nextCursor,
        isLoadingMore: false,
        loadMoreFailure: null,
        activeLoadMoreRequestId: null,
      },
    };
  }

  function presentation(state: ThreadSearchState): ThreadSearchPresentation {
    if (!state.query) {
      return {
        kind: "prompt",
        query: "",
        footerKind: "hidden",
        canLoadMore: false,
        renderBody: false,
      };
    }
    if (
      state.headStatus === "debouncing" ||
      state.headStatus === "loading" ||
      state.headStatus === "idle"
    ) {
      return {
        kind: "loading",
        query: state.query,
        footerKind: "initialLoading",
        canLoadMore: false,
        renderBody: true,
      };
    }
    if (state.headStatus === "failed") {
      return {
        kind: "failed",
        query: state.query,
        footerKind: "initialFailure",
        canLoadMore: false,
        renderBody: true,
      };
    }
    if (state.rows.length === 0) {
      return {
        kind: "empty",
        query: state.query,
        footerKind: "hidden",
        canLoadMore: false,
        renderBody: true,
      };
    }
    const footerKind: ThreadSearchResultsFooterKind = state.isLoadingMore
      ? "loadingMore"
      : state.loadMoreFailure
        ? "loadMoreFailure"
        : state.nextCursor
          ? "idle"
          : "hidden";
    return {
      kind: "results",
      query: state.query,
      footerKind,
      canLoadMore:
        state.nextCursor !== null &&
        !state.isLoadingMore &&
        state.loadMoreFailure === null,
      renderBody: true,
    };
  }

  return {
    debounceMs: dependencies.debounceMs,
    pageLimit: dependencies.pageLimit,
    createState,
    engage,
    setQuery,
    clear,
    resetScope,
    debounceDecision,
    requestFirstPage,
    requestLoadMore,
    failRequest,
    completeRequest,
    presentation,
    mergeRows,
  };
}

export const threadSearchModel = createThreadSearchModel();

export type ThreadSearchModel = ReturnType<typeof createThreadSearchModel>;
