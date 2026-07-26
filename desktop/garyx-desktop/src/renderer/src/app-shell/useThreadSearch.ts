import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import type { DesktopThreadSummary } from "@shared/contracts";
import {
  threadSearchModel,
  type ThreadSearchDebounceDecision,
  type ThreadSearchPresentation,
  type ThreadSearchRequestTicket,
  type ThreadSearchState,
} from "./thread-search-model";

type ThreadSearchControllerOptions = {
  gatewayScope: string;
};

export type ThreadSearchController = {
  isOpen: boolean;
  state: ThreadSearchState;
  presentation: ThreadSearchPresentation;
  open: () => void;
  close: () => void;
  setQuery: (query: string) => void;
  loadMore: () => void;
  retry: () => void;
  rows: DesktopThreadSummary[];
};

export function useThreadSearch({
  gatewayScope,
}: ThreadSearchControllerOptions): ThreadSearchController {
  const [state, setState] = useState(() =>
    threadSearchModel.createState(gatewayScope),
  );
  const [isOpen, setIsOpen] = useState(false);
  const stateRef = useRef(state);
  const mountedRef = useRef(true);

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  const commit = useCallback(
    (update: (current: ThreadSearchState) => ThreadSearchState) => {
      const current = stateRef.current;
      const next = update(current);
      stateRef.current = next;
      setState(next);
      return next;
    },
    [],
  );

  const execute = useCallback(
    async (ticket: ThreadSearchRequestTicket) => {
      try {
        // Search membership is always global: task threads are included and
        // the IPC contract deliberately has no root-workspace field.
        const page = await window.garyxDesktop.listThreadSummaries({
          gatewayScope: ticket.gatewayScope,
          tasks: "include",
          q: ticket.query,
          limit: ticket.limit,
          cursor: ticket.cursor,
        });
        if (!mountedRef.current) {
          return;
        }
        commit(
          (current) =>
            threadSearchModel.completeRequest(current, ticket, page).state,
        );
      } catch (error) {
        if (!mountedRef.current) {
          return;
        }
        commit((current) =>
          threadSearchModel.failRequest(current, ticket, error),
        );
      }
    },
    [commit],
  );

  const beginFirstPage = useCallback(
    (debounce?: ThreadSearchDebounceDecision) => {
      const decision = threadSearchModel.requestFirstPage(
        stateRef.current,
        debounce,
      );
      if (!decision.ticket) {
        return;
      }
      stateRef.current = decision.state;
      setState(decision.state);
      void execute(decision.ticket);
    },
    [execute],
  );

  const beginLoadMore = useCallback(
    (retry = false) => {
      const decision = threadSearchModel.requestLoadMore(
        stateRef.current,
        retry,
      );
      if (!decision.ticket) {
        return;
      }
      stateRef.current = decision.state;
      setState(decision.state);
      void execute(decision.ticket);
    },
    [execute],
  );

  useEffect(() => {
    commit((current) =>
      threadSearchModel.resetScope(current, gatewayScope),
    );
  }, [commit, gatewayScope]);

  useEffect(() => {
    const decision = threadSearchModel.debounceDecision(state);
    if (!decision) {
      return;
    }
    const timer = window.setTimeout(() => {
      beginFirstPage(decision);
    }, decision.delayMs);
    return () => {
      window.clearTimeout(timer);
    };
  }, [
    beginFirstPage,
    state.gatewayScope,
    state.generation,
    state.headStatus,
    state.query,
  ]);

  const open = useCallback(() => {
    setIsOpen(true);
    commit(threadSearchModel.engage);
  }, [commit]);

  const setQuery = useCallback(
    (query: string) => {
      commit((current) => threadSearchModel.setQuery(current, query));
    },
    [commit],
  );

  const close = useCallback(() => {
    setIsOpen(false);
    commit(threadSearchModel.clear);
  }, [commit]);

  const retry = useCallback(() => {
    const current = stateRef.current;
    if (current.headStatus === "failed") {
      beginFirstPage();
    } else if (current.loadMoreFailure) {
      beginLoadMore(true);
    }
  }, [beginFirstPage, beginLoadMore]);

  // Scope masking is synchronous: a gateway switch must not render the old
  // gateway's search rows for even the frame before the reset effect commits.
  let visibleState = state;
  if (stateRef.current.gatewayScope !== gatewayScope) {
    visibleState = threadSearchModel.resetScope(
      stateRef.current,
      gatewayScope,
    );
    stateRef.current = visibleState;
  } else if (state.gatewayScope !== gatewayScope) {
    // The render state can lag the synchronously masked ref until the scope
    // effect publishes it. Keep rendering the already-aligned ref meanwhile.
    visibleState = stateRef.current;
  }

  const presentation = useMemo(
    () => threadSearchModel.presentation(visibleState),
    [visibleState],
  );

  return {
    isOpen,
    state: visibleState,
    presentation,
    open,
    close,
    setQuery,
    loadMore: beginLoadMore,
    retry,
    rows: visibleState.rows,
  };
}
