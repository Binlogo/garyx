import XCTest
@testable import GaryxMobileCore

final class GaryxHomeThreadSearchTests: XCTestCase {
    func testWhitespaceIsPromptAndNonemptyQueryRequestsAfter250Milliseconds() throws {
        var state = GaryxHomeThreadSearchState()

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
        XCTAssertEqual(state.debounceDecision, .none)
    }

    func testLateResponseFromSupersededQueryIsRejected() throws {
        var state = GaryxHomeThreadSearchState()
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
        var state = GaryxHomeThreadSearchState()
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
        var state = GaryxHomeThreadSearchState()
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

    func testAllPresentationAndFooterTransitions() throws {
        var state = GaryxHomeThreadSearchState()
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
