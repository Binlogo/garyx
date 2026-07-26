import XCTest
@testable import GaryxMobileCore

@MainActor
final class GaryxHomeThreadSearchTests: XCTestCase {
    func testWhitespaceIsPromptAndNonemptyQueryRequestsAfter250Milliseconds() throws {
        var state = makeState()

        XCTAssertEqual(state.presentation, .prompt)
        XCTAssertFalse(state.replaceQuery(" \n\t "))
        XCTAssertEqual(state.debounceDecision, .none)

        XCTAssertTrue(state.replaceQuery("  Project Straße  "))
        XCTAssertEqual(state.query, "Project Straße")
        XCTAssertEqual(state.presentation, .loading)

        let decision = state.debounceDecision
        guard case let .wait(ticket, nanoseconds) = decision else {
            return XCTFail("a non-empty query must be debounced")
        }
        XCTAssertEqual(nanoseconds, 250_000_000)
        XCTAssertEqual(ticket.query, "Project Straße")

        let request = try XCTUnwrap(state.beginDebouncedSearch(ticket))
        XCTAssertEqual(request.query, "Project Straße")
        XCTAssertNil(request.cursor)
        XCTAssertEqual(request.kind, .head)
        XCTAssertEqual(request.gatewayRequestToken, gatewayToken())
        XCTAssertNil(request.endpointRequest.rootWorkspacePath)
        XCTAssertEqual(request.endpointRequest.tasks, .include)
        XCTAssertEqual(request.endpointRequest.limit, 30)
        XCTAssertEqual(state.debounceDecision, .none)
    }

    func testLateResponseFromSupersededQueryIsRejected() throws {
        var state = makeState()
        let oldRequest = try beginDebouncedHead("Alpha", state: &state)

        XCTAssertTrue(state.replaceQuery("Beta"))
        XCTAssertEqual(
            state.complete(
                oldRequest,
                page: page(ids: ["thread::alpha"], cursor: nil)
            ),
            .rejectedStale
        )
        XCTAssertEqual(state.query, "Beta")
        XCTAssertTrue(state.threads.isEmpty)
        XCTAssertEqual(state.presentation, .loading)
    }

    func testChangingQueryResetsCursorAndRejectsOldPage() throws {
        var state = makeState()
        let head = try beginDebouncedHead("First", state: &state)
        XCTAssertEqual(
            state.complete(
                head,
                page: page(ids: ["thread::one"], cursor: "cursor-one")
            ),
            .accepted
        )
        let oldPageRequest = try XCTUnwrap(state.beginLoadMore())

        XCTAssertTrue(state.replaceQuery("Second"))
        XCTAssertNil(state.nextCursor)
        XCTAssertEqual(state.footerState, .hidden)
        XCTAssertEqual(
            state.complete(
                oldPageRequest,
                page: page(ids: ["thread::two"], cursor: nil)
            ),
            .rejectedStale
        )
        XCTAssertTrue(state.threads.isEmpty)
    }

    func testPageMergePreservesOrderDeduplicatesAndUpdatesExistingRows() throws {
        var state = makeState()
        let head = try beginDebouncedHead("Project", state: &state)
        XCTAssertEqual(
            state.complete(
                head,
                page: page(
                    summaries: [
                        summary("thread::one", title: "One"),
                        summary("thread::two", title: "Two"),
                    ],
                    cursor: "cursor-one"
                )
            ),
            .accepted
        )

        let pageRequest = try XCTUnwrap(state.beginLoadMore())
        XCTAssertEqual(state.footerState, .loading)
        XCTAssertEqual(
            state.complete(
                pageRequest,
                page: page(
                    summaries: [
                        summary("thread::two", title: "Two updated"),
                        summary("thread::three", title: "Three old"),
                        summary("thread::three", title: "Three"),
                    ],
                    cursor: nil
                )
            ),
            .accepted
        )

        XCTAssertEqual(
            state.threads.map(\.id),
            ["thread::one", "thread::two", "thread::three"]
        )
        XCTAssertEqual(state.threads[1].title, "Two updated")
        XCTAssertEqual(state.threads[2].title, "Three")
        XCTAssertEqual(state.footerState, .hidden)
    }

    func testPageFromSameStoreAfterServerRestartIsAccepted() throws {
        var state = makeState()
        let head = try beginDebouncedHead("Project", state: &state)
        XCTAssertEqual(
            state.complete(
                head,
                page: page(
                    ids: ["thread::one"],
                    cursor: "cursor-one",
                    storeIncarnationId: "inc-1",
                    serverBootId: "boot-before-restart"
                )
            ),
            .accepted
        )

        let pageRequest = try XCTUnwrap(state.beginLoadMore())
        XCTAssertEqual(
            state.complete(
                pageRequest,
                page: page(
                    ids: ["thread::two"],
                    cursor: nil,
                    storeIncarnationId: "inc-1",
                    serverBootId: "boot-after-restart"
                )
            ),
            .accepted,
            "server boot identity is not part of the thread-summary cursor contract"
        )
        XCTAssertEqual(state.threads.map(\.id), ["thread::one", "thread::two"])
        XCTAssertEqual(state.footerState, .hidden)
    }

    func testStoreIncarnationMismatchRejectsPageWithoutMergingIt() throws {
        var state = makeState()
        let head = try beginDebouncedHead("Project", state: &state)
        XCTAssertEqual(
            state.complete(
                head,
                page: page(
                    ids: ["thread::one"],
                    cursor: "cursor-one",
                    storeIncarnationId: "inc-before"
                )
            ),
            .accepted
        )

        let pageRequest = try XCTUnwrap(state.beginLoadMore())
        XCTAssertEqual(
            state.complete(
                pageRequest,
                page: page(
                    ids: ["thread::two"],
                    cursor: nil,
                    storeIncarnationId: "inc-after"
                )
            ),
            .rejectedStoreIdentity
        )
        XCTAssertEqual(state.threads.map(\.id), ["thread::one"])
        XCTAssertEqual(state.footerState, .failed)
    }

    func testGatewayScopeExitClearsRowsAndActivationRerunsRetainedQuery() throws {
        let firstToken = gatewayToken(identity: "gateway-a", activationSequence: 7)
        var state = GaryxHomeThreadSearchState(gatewayRequestToken: firstToken)
        let head = try beginDebouncedHead("Project", state: &state)
        XCTAssertEqual(
            state.complete(
                head,
                page: page(ids: ["thread::one"], cursor: "cursor-one")
            ),
            .accepted
        )
        let oldPageRequest = try XCTUnwrap(state.beginLoadMore())

        let suspendedToken = gatewayToken(identity: "gateway-a", activationSequence: 8)
        XCTAssertTrue(
            state.replaceGatewayRequestToken(
                suspendedToken,
                isActive: false
            )
        )
        XCTAssertEqual(state.gatewayRequestToken, suspendedToken)
        XCTAssertFalse(state.isGatewayScopeActive)
        XCTAssertEqual(state.query, "Project")
        XCTAssertTrue(state.threads.isEmpty)
        XCTAssertNil(state.nextCursor)
        XCTAssertEqual(state.presentation, .loading)
        XCTAssertEqual(state.debounceDecision, .none)
        XCTAssertNil(state.beginRefresh())
        XCTAssertTrue(state.replaceQuery("Next project"))
        XCTAssertEqual(state.query, "Next project")
        XCTAssertEqual(state.debounceDecision, .none)
        XCTAssertEqual(
            state.complete(
                oldPageRequest,
                page: page(ids: ["thread::two"], cursor: nil)
            ),
            .rejectedStale
        )

        let secondToken = gatewayToken(identity: "gateway-b", activationSequence: 9)
        XCTAssertTrue(
            state.replaceGatewayRequestToken(
                secondToken,
                isActive: true
            )
        )
        XCTAssertEqual(state.gatewayRequestToken, secondToken)
        XCTAssertTrue(state.isGatewayScopeActive)
        XCTAssertEqual(state.query, "Next project")
        XCTAssertTrue(state.threads.isEmpty)
        XCTAssertNil(state.nextCursor)
        XCTAssertEqual(state.presentation, .loading)

        guard case let .wait(ticket, _) = state.debounceDecision else {
            return XCTFail("the retained query must rerun in the new gateway activation")
        }
        let replacementHead = try XCTUnwrap(state.beginDebouncedSearch(ticket))
        XCTAssertEqual(replacementHead.gatewayRequestToken, secondToken)
        XCTAssertEqual(replacementHead.query, "Next project")
        XCTAssertNil(replacementHead.endpointRequest.rootWorkspacePath)
        XCTAssertEqual(replacementHead.endpointRequest.tasks, .include)
    }

    func testAllPresentationAndFooterTransitions() throws {
        var state = makeState()
        XCTAssertEqual(state.presentation, .prompt)

        let emptyHead = try beginDebouncedHead("Missing", state: &state)
        XCTAssertEqual(state.presentation, .loading)
        XCTAssertEqual(
            state.complete(emptyHead, page: page(ids: [], cursor: nil)),
            .accepted
        )
        XCTAssertEqual(state.presentation, .empty(query: "Missing"))

        let failedRefresh = try XCTUnwrap(state.beginRefresh())
        XCTAssertEqual(state.presentation, .loading)
        XCTAssertTrue(state.fail(failedRefresh, message: "Gateway unavailable"))
        XCTAssertEqual(
            state.presentation,
            .failed(query: "Missing", message: "Gateway unavailable")
        )

        let retry = try XCTUnwrap(state.beginRefresh())
        XCTAssertEqual(state.presentation, .loading)
        XCTAssertEqual(
            state.complete(
                retry,
                page: page(ids: ["thread::one"], cursor: "cursor-one")
            ),
            .accepted
        )
        XCTAssertEqual(state.presentation, .results)
        XCTAssertEqual(state.footerState, .idle)

        let failedResultsRefresh = try XCTUnwrap(state.beginRefresh())
        XCTAssertEqual(state.presentation, .results)
        XCTAssertTrue(state.fail(failedResultsRefresh, message: "Refresh unavailable"))
        XCTAssertEqual(state.presentation, .results)
        XCTAssertEqual(state.headFailureMessage, "Refresh unavailable")
        XCTAssertEqual(state.threads.map(\.id), ["thread::one"])
        XCTAssertEqual(state.footerState, .hidden)

        let recoveredResultsRefresh = try XCTUnwrap(state.beginRefresh())
        XCTAssertEqual(
            state.complete(
                recoveredResultsRefresh,
                page: page(ids: ["thread::one"], cursor: "cursor-one")
            ),
            .accepted
        )

        let loadMore = try XCTUnwrap(state.beginLoadMore())
        XCTAssertEqual(state.footerState, .loading)
        XCTAssertTrue(state.fail(loadMore, message: "ignored for footer"))
        XCTAssertEqual(state.presentation, .results)
        XCTAssertEqual(state.footerState, .failed)
        XCTAssertNil(state.beginLoadMore())

        let retryLoadMore = try XCTUnwrap(state.beginLoadMore(retryingFailure: true))
        XCTAssertEqual(state.footerState, .loading)
        XCTAssertEqual(
            state.complete(
                retryLoadMore,
                page: page(ids: ["thread::two"], cursor: nil)
            ),
            .accepted
        )
        XCTAssertEqual(state.presentation, .results)
        XCTAssertEqual(state.footerState, .hidden)

        XCTAssertTrue(state.replaceQuery(""))
        XCTAssertEqual(state.presentation, .prompt)
        XCTAssertTrue(state.threads.isEmpty)
    }

    func testLiveRowsStorePublishesOffWindowFavoriteAndRunState() throws {
        let thread = summary("thread::outside-home-window", title: "Search Result")
        let store = GaryxHomeThreadSearchRowsStore(
            context: GaryxHomeThreadSearchRowsContext(
                gatewayRequestToken: gatewayToken()
            )
        )

        var row = try XCTUnwrap(store.rows(for: [thread]).first)
        XCTAssertFalse(row.presentation.isFavorite)
        XCTAssertFalse(row.presentation.isRunning)
        XCTAssertTrue(row.capabilities.canArchive)
        let baselinePublishCount = store.publishCount

        XCTAssertTrue(store.apply(
            GaryxHomeThreadSearchRowsContext(
                gatewayRequestToken: gatewayToken(),
                favoritedThreadIds: [thread.id],
                runningThreadIds: [thread.id]
            )
        ))
        XCTAssertEqual(store.publishCount, baselinePublishCount + 1)

        row = try XCTUnwrap(store.rows(for: [thread]).first)
        XCTAssertTrue(row.presentation.isFavorite)
        XCTAssertTrue(row.presentation.isRunning)
        XCTAssertFalse(row.capabilities.canArchive)
        XCTAssertEqual(row.capabilities.archiveStrategy, .none)
    }

    private func beginDebouncedHead(
        _ query: String,
        state: inout GaryxHomeThreadSearchState
    ) throws -> GaryxHomeThreadSearchRequest {
        XCTAssertTrue(state.replaceQuery(query))
        guard case let .wait(ticket, _) = state.debounceDecision else {
            throw TestError.missingDebounceTicket
        }
        return try XCTUnwrap(state.beginDebouncedSearch(ticket))
    }

    private func makeState() -> GaryxHomeThreadSearchState {
        GaryxHomeThreadSearchState(gatewayRequestToken: gatewayToken())
    }

    private func gatewayToken(
        identity: String = "gateway-a",
        activationSequence: UInt64 = 7
    ) -> GaryxGatewayRequestToken {
        GaryxGatewayRequestToken(
            scope: GaryxGatewayScope(identity: identity, epoch: 1),
            activationSequence: activationSequence
        )
    }

    private func page(
        ids: [String],
        cursor: String?,
        storeIncarnationId: String = "inc-1",
        serverBootId: String = "boot-1"
    ) -> GaryxThreadSummariesPage {
        page(
            summaries: ids.map { summary($0, title: $0) },
            cursor: cursor,
            storeIncarnationId: storeIncarnationId,
            serverBootId: serverBootId
        )
    }

    private func page(
        summaries: [GaryxThreadSummary],
        cursor: String?,
        storeIncarnationId: String = "inc-1",
        serverBootId: String = "boot-1"
    ) -> GaryxThreadSummariesPage {
        GaryxThreadSummariesPage(
            storeIncarnationId: storeIncarnationId,
            serverBootId: serverBootId,
            threads: summaries,
            hasMore: cursor != nil,
            nextCursor: cursor
        )
    }

    private func summary(_ id: String, title: String) -> GaryxThreadSummary {
        GaryxThreadSummary(
            id: id,
            title: title,
            createdAt: "2026-07-26T00:00:00Z",
            updatedAt: "2026-07-26T00:00:00Z",
            lastMessagePreview: "",
            workspacePath: nil,
            messageCount: nil,
            agentId: nil,
            providerType: nil,
            recentRunId: nil,
            activeRunId: nil,
            runState: nil,
            worktreePath: nil
        )
    }

    private enum TestError: Error {
        case missingDebounceTicket
    }
}
