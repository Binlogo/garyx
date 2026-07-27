import XCTest
@testable import GaryxMobileCore

final class GaryxRecentThreadFeedsTests: XCTestCase {
    func testFilterWireMappingAndDefaults() {
        XCTAssertEqual(GaryxRecentThreadFilter.all.tasksQueryValue, "include")
        XCTAssertEqual(GaryxRecentThreadFilter.nonTask.tasksQueryValue, "exclude")
        XCTAssertNil(GaryxRecentThreadFilter.favorites.tasksQueryValue)
        XCTAssertEqual(GaryxRecentThreadFilter.all.displayName, "All")
        XCTAssertEqual(GaryxRecentThreadFilter.nonTask.displayName, "Chats")
        XCTAssertEqual(GaryxRecentThreadFilter.favorites.displayName, "Favorites")
        XCTAssertEqual(GaryxRecentThreadFilter.homeMenuOptions, [.all, .nonTask, .favorites])
        XCTAssertNil(GaryxRecentThreadFilter.all.activeStatusLabel)
        XCTAssertEqual(GaryxRecentThreadFilter.nonTask.activeStatusLabel, "Chats")
        XCTAssertEqual(GaryxRecentThreadFilter.favorites.activeStatusLabel, "Favorites")

        let feeds = makeFeeds()
        XCTAssertEqual(feeds.selectedFilter, .all)
        XCTAssertFalse(feeds.allFeed.isPrimed)
        XCTAssertFalse(feeds.nonTaskFeed.isPrimed)
    }

    func testFavoritesSelectionHasNoRecentPagerOrTransportTicket() {
        var feeds = makeFeeds()
        feeds.select(.favorites)

        XCTAssertEqual(feeds.selectedFilter, .favorites)
        XCTAssertNil(feeds.selectedPager)
        XCTAssertNil(
            feeds.selectedPresentation,
            "Recent must not fabricate a phase for the Favorites domain"
        )
        XCTAssertNil(feeds.feed(for: .favorites))
        XCTAssertNil(feeds.testRequestHead())
        XCTAssertNil(feeds.requestLoadMore(trigger: .footer))
        XCTAssertNil(feeds.retryLoadMore())
        XCTAssertTrue(feeds.visibleRecentThreadIds.isEmpty)
    }

    func testLateCompletionWritesTicketFilterNotCurrentSelection() throws {
        var feeds = makeFeeds()
        let all = try XCTUnwrap(feeds.testRequestHead(filter: .all))
        feeds.select(.nonTask)
        let chats = try XCTUnwrap(feeds.testRequestHead())
        feeds.select(.all)

        XCTAssertEqual(
            feeds.testCompleteHead(
                chats,
                bundle: bundle(page([("chat-a", 20), ("chat-b", 19)]))
            ),
            .applied
        )
        XCTAssertEqual(feeds.nonTaskFeed.orderedThreadIds, ["chat-a", "chat-b"])
        XCTAssertTrue(feeds.allFeed.orderedThreadIds.isEmpty)
        XCTAssertEqual(
            feeds.testCompleteHead(
                all,
                bundle: bundle(page([("task", 30), ("chat-a", 20)]))
            ),
            .applied
        )
        XCTAssertEqual(feeds.allFeed.orderedThreadIds, ["task", "chat-a"])
    }

    func testResetAbandonsOldEpochAndPreservesSelection() throws {
        var feeds = makeFeeds()
        feeds.select(.nonTask)
        let ticket = try XCTUnwrap(feeds.testRequestHead())
        let effects = feeds.resetFeedData()
        XCTAssertEqual(
            feeds.nonTaskFeed.headPhase,
            .primingOwed(.supersededByReset, .immediate)
        )
        XCTAssertTrue(effects.contains { effect in
            guard case .requestHead(let request) = effect else { return false }
            return request.filter == .nonTask
        })
        XCTAssertEqual(
            feeds.testCompleteHead(ticket, bundle: bundle(page([("old", 1)]))),
            .abandonedStaleEpoch
        )
        XCTAssertEqual(feeds.selectedFilter, .nonTask)
        XCTAssertTrue(feeds.visibleRecentThreadIds.isEmpty)
    }

    func testEmptySuccessPrimesAndFailurePreservesCachedRows() throws {
        var feeds = makeFeeds()
        let empty = try XCTUnwrap(feeds.testRequestHead(filter: .all))
        XCTAssertEqual(
            feeds.testCompleteHead(empty, bundle: bundle(page([]))),
            .applied
        )
        XCTAssertTrue(feeds.allFeed.isPrimed)
        XCTAssertFalse(feeds.allFeed.headFailure)

        adoptHead(&feeds, filter: .nonTask, rows: [("chat", 10)])
        let failed = try XCTUnwrap(feeds.testRequestHead(filter: .nonTask))
        feeds.testFailHead(failed)
        XCTAssertEqual(feeds.nonTaskFeed.orderedThreadIds, ["chat"])
        XCTAssertTrue(feeds.nonTaskFeed.headFailure)
    }

    func testRefreshBlockedByLoadMoreTrailsImmediatelyAfterCompletion() throws {
        var feeds = makeFeeds()
        adoptHead(&feeds, filter: .all, rows: [("old", 100)], hasMore: true)
        let refresh = try XCTUnwrap(feeds.testRequestHead(filter: .all))
        XCTAssertNil(feeds.requestLoadMore(trigger: .footer))
        feeds.testFailHead(refresh)
        let load = try XCTUnwrap(feeds.requestLoadMore(trigger: .footer))
        let blockedEffects = feeds.requestHeadEffects(
            filter: .all,
            source: .userPullToRefresh
        )
        XCTAssertTrue(blockedEffects.isEmpty)
        XCTAssertNotNil(feeds.allFeed.pendingHeadRequest)

        let trailingEffects = feeds.failLoadMore(load)
        let trailingRequest = try XCTUnwrap(
            trailingEffects.compactMap { effect -> GaryxRecentHeadRequest? in
                guard case .requestHead(let request) = effect else { return nil }
                return request
            }.first
        )
        XCTAssertEqual(trailingRequest.source, .userPullToRefresh)
        XCTAssertNotNil(
            feeds.beginHeadRequest(
                trailingRequest,
                gatewayScope: "https://gateway.example.test",
                runtimeEpoch: 1
            )
        )
    }

    func testInterruptLoadMoreDrainsOwnedTrailingHeadRequest() throws {
        var feeds = makeFeeds()
        adoptHead(&feeds, filter: .all, rows: [("old", 100)], hasMore: true)
        let load = try XCTUnwrap(feeds.requestLoadMore(trigger: .footer))
        XCTAssertTrue(
            feeds.requestHeadEffects(
                filter: .all,
                source: .userPullToRefresh
            ).isEmpty
        )
        XCTAssertEqual(
            feeds.allFeed.pendingHeadRequest?.source,
            .userPullToRefresh
        )

        let effects = feeds.interruptLoadMore(load)
        let requests = effects.compactMap { effect -> GaryxRecentHeadRequest? in
            guard case .requestHead(let request) = effect else { return nil }
            return request
        }
        XCTAssertEqual(
            effects.reduce(into: 0) { count, effect in
                if case .publish = effect { count += 1 }
            },
            1
        )
        XCTAssertEqual(requests.map(\.filter), [.all])
        XCTAssertEqual(requests.map(\.source), [.userPullToRefresh])
        XCTAssertFalse(feeds.allFeed.pager.isLoadingMore)
        XCTAssertEqual(
            feeds.allFeed.headPhase,
            .readyStale(.interrupted, .immediate)
        )
    }

    func testLoadMoreUsesCursorAndDeduplicates() throws {
        var feeds = makeFeeds()
        adoptHead(
            &feeds,
            filter: .all,
            rows: [("a", 100), ("b", 99)],
            hasMore: true,
            cursor: "cursor-99"
        )
        let load = try XCTUnwrap(feeds.requestLoadMore(trigger: .footer))
        XCTAssertEqual(load.cursor, "cursor-99")
        XCTAssertEqual(
            feeds.testCompleteLoadMore(
                load,
                page: page(
                    [("b", 99), ("c", 98)],
                    hasMore: false,
                    cursor: nil
                )
            ),
            .applied
        )
        XCTAssertEqual(feeds.allFeed.orderedThreadIds, ["a", "b", "c"])
        XCTAssertEqual(feeds.allFeed.presentation.footerState, .hidden)
    }

    func testSeqRangeFillWalksToOldHeadAndPreservesLoadedTail() throws {
        var feeds = makeFeeds()
        adoptHead(
            &feeds,
            filter: .all,
            rows: [("old-head", 100), ("old-99", 99)],
            hasMore: true,
            cursor: "cursor-99"
        )
        let load = try XCTUnwrap(feeds.requestLoadMore(trigger: .footer))
        _ = feeds.testCompleteLoadMore(
            load,
            page: page([("old-98", 98)], hasMore: true, cursor: "cursor-98")
        )
        let ticket = try XCTUnwrap(feeds.testRequestHead(filter: .all))
        XCTAssertEqual(ticket.mode, .rangeFill)
        XCTAssertEqual(ticket.oldHeadActivitySeq, 100)
        let first = page(
            [("new-105", 105), ("new-104", 104)],
            hasMore: true,
            cursor: "cursor-104"
        )
        XCTAssertTrue(GaryxRecentThreadRangeFill.needsNextPage(
            mode: .rangeFill,
            oldHeadActivitySeq: 100,
            pages: [first]
        ))
        let second = page(
            [("new-103", 103), ("old-head", 100)],
            hasMore: true,
            cursor: "cursor-100"
        )
        XCTAssertFalse(GaryxRecentThreadRangeFill.needsNextPage(
            mode: .rangeFill,
            oldHeadActivitySeq: 100,
            pages: [first, second]
        ))
        XCTAssertEqual(
            feeds.testCompleteHead(
                ticket,
                bundle: GaryxRecentThreadRefreshBundle(
                    primaryPages: [first, second],
                    verificationPage: first
                )
            ),
            .applied
        )
        XCTAssertEqual(feeds.allFeed.orderedThreadIds, [
            "new-105", "new-104", "new-103", "old-head", "old-99", "old-98",
        ])
        XCTAssertEqual(feeds.allFeed.nextCursor, "cursor-98")
    }

    func testChainFailureIsAtomic() throws {
        var feeds = makeFeeds()
        adoptHead(&feeds, filter: .all, rows: [("old", 100)], hasMore: true)
        let before = feeds.allFeed.orderedThreadIds
        let ticket = try XCTUnwrap(feeds.testRequestHead(filter: .all))
        feeds.testFailHead(ticket)
        XCTAssertEqual(feeds.allFeed.orderedThreadIds, before)
        XCTAssertTrue(feeds.allFeed.headFailure)
    }

    func testKOverflowCommitsFivePageWindowAndDropsOldRows() throws {
        var feeds = makeFeeds()
        adoptHead(&feeds, filter: .all, rows: [("old", 100)], hasMore: true)
        let oldEpoch = feeds.allFeed.pager.epoch
        let ticket = try XCTUnwrap(feeds.testRequestHead(filter: .all))
        let pages = (0..<GaryxRecentThreadRangeFill.maxChainPages).map { index in
            let top = Int64(200 - index * 2)
            return page(
                [("new-\(top)", top), ("new-\(top - 1)", top - 1)],
                hasMore: true,
                cursor: "cursor-\(top - 1)"
            )
        }
        XCTAssertEqual(
            feeds.testCompleteHead(
                ticket,
                bundle: GaryxRecentThreadRefreshBundle(
                    primaryPages: pages,
                    verificationPage: pages[0]
                )
            ),
            .applied
        )
        XCTAssertFalse(feeds.allFeed.orderedThreadIds.contains("old"))
        XCTAssertEqual(feeds.allFeed.orderedThreadIds.count, 10)
        XCTAssertEqual(feeds.allFeed.nextCursor, "cursor-191")
        XCTAssertEqual(feeds.allFeed.pager.epoch, oldEpoch + 1)
    }

    func testKOverflowComposesWithOneMovedHeadFillAndBoundedReverification() throws {
        var feeds = makeFeeds()
        adoptHead(&feeds, filter: .all, rows: [("old", 100)], hasMore: true)
        let oldEpoch = feeds.allFeed.pager.epoch
        let ticket = try XCTUnwrap(feeds.testRequestHead(filter: .all))
        let pages = (0..<GaryxRecentThreadRangeFill.maxChainPages).map { index in
            let top = Int64(200 - index * 2)
            return page(
                [("new-\(top)", top), ("new-\(top - 1)", top - 1)],
                hasMore: true,
                cursor: "cursor-\(top - 1)"
            )
        }
        let verification = page([("moved-220", 220)], hasMore: true)
        let immediate = page(
            [("moved-220", 220), ("new-200", 200)],
            hasMore: true,
            cursor: "cursor-200"
        )
        let movingAgain = page([("moved-again-230", 230)], hasMore: true)

        XCTAssertEqual(
            feeds.testCompleteHead(
                ticket,
                bundle: GaryxRecentThreadRefreshBundle(
                    primaryPages: pages,
                    verificationPage: verification,
                    immediatePages: [immediate],
                    immediateVerificationPage: movingAgain
                )
            ),
            .applied
        )
        XCTAssertEqual(Array(feeds.allFeed.orderedThreadIds.prefix(3)), [
            "moved-220", "new-200", "new-199",
        ])
        XCTAssertFalse(feeds.allFeed.orderedThreadIds.contains("old"))
        XCTAssertEqual(feeds.allFeed.orderedThreadIds.count, 11)
        XCTAssertEqual(feeds.allFeed.nextCursor, "cursor-191")
        XCTAssertEqual(feeds.allFeed.pager.epoch, oldEpoch + 1)
        XCTAssertTrue(feeds.allFeed.trailingDirty)
        XCTAssertFalse(feeds.allFeed.orderedThreadIds.contains("moved-again-230"))
    }

    func testExhaustionBeforeAnchorReplacesAndRemovesGhostTail() throws {
        var feeds = makeFeeds()
        adoptHead(
            &feeds,
            filter: .all,
            rows: [("old", 100), ("ghost", 90)],
            hasMore: true
        )
        let ticket = try XCTUnwrap(feeds.testRequestHead(filter: .all))
        let exhausted = page(
            [("new", 110), ("still-live", 105)],
            hasMore: false,
            cursor: nil
        )
        _ = feeds.testCompleteHead(ticket, bundle: bundle(exhausted))
        XCTAssertEqual(feeds.allFeed.orderedThreadIds, ["new", "still-live"])
        XCTAssertNil(feeds.allFeed.nextCursor)
    }

    func testBootMismatchForcesReplacementThenAcceptsNewBoot() throws {
        var feeds = makeFeeds()
        adoptHead(&feeds, filter: .all, rows: [("old", 100)], hasMore: true)
        let range = try XCTUnwrap(feeds.testRequestHead(filter: .all))
        let newBoot = page(
            [("new", 110)],
            hasMore: false,
            cursor: nil,
            boot: "boot-b"
        )
        XCTAssertEqual(
            feeds.testCompleteHead(range, bundle: bundle(newBoot)),
            .forceReplacement
        )
        XCTAssertEqual(feeds.allFeed.orderedThreadIds, ["old"])
        XCTAssertTrue(feeds.allFeed.forceReplacementPending)

        let replacement = try XCTUnwrap(feeds.testRequestHead(filter: .all))
        XCTAssertEqual(replacement.mode, .replacement)
        XCTAssertEqual(
            feeds.testCompleteHead(replacement, bundle: bundle(newBoot)),
            .applied
        )
        XCTAssertEqual(feeds.allFeed.orderedThreadIds, ["new"])
        XCTAssertEqual(feeds.allFeed.serverBootId, "boot-b")
    }

    func testIncarnationMismatchForcesReplacementThenAcceptsNewStore() throws {
        var feeds = makeFeeds()
        adoptHead(&feeds, filter: .all, rows: [("old", 100)], hasMore: true)
        let range = try XCTUnwrap(feeds.testRequestHead(filter: .all))
        let newStore = page(
            [("new", 110)],
            hasMore: false,
            cursor: nil,
            incarnation: "inc-b"
        )
        XCTAssertEqual(
            feeds.testCompleteHead(range, bundle: bundle(newStore)),
            .forceReplacement
        )
        XCTAssertEqual(feeds.allFeed.orderedThreadIds, ["old"])

        let replacement = try XCTUnwrap(feeds.testRequestHead(filter: .all))
        XCTAssertEqual(replacement.mode, .replacement)
        XCTAssertEqual(
            feeds.testCompleteHead(replacement, bundle: bundle(newStore)),
            .applied
        )
        XCTAssertEqual(feeds.allFeed.orderedThreadIds, ["new"])
        XCTAssertEqual(feeds.allFeed.storeIncarnationId, "inc-b")
    }

    func testHeadVerificationAllowsOneImmediateRoundThenDefersMotion() throws {
        var feeds = makeFeeds()
        adoptHead(&feeds, filter: .all, rows: [("old", 100)], hasMore: true)
        let ticket = try XCTUnwrap(feeds.testRequestHead(filter: .all))
        let primary = page(
            [("new-110", 110), ("old", 100)],
            hasMore: true,
            cursor: "cursor-100"
        )
        let verification = page([("moved-120", 120)], hasMore: true)
        let immediate = page(
            [("moved-120", 120), ("new-110", 110)],
            hasMore: true,
            cursor: "cursor-110"
        )
        let movingAgain = page([("moved-130", 130)], hasMore: true)
        XCTAssertEqual(
            feeds.testCompleteHead(
                ticket,
                bundle: GaryxRecentThreadRefreshBundle(
                    primaryPages: [primary],
                    verificationPage: verification,
                    immediatePages: [immediate],
                    immediateVerificationPage: movingAgain
                )
            ),
            .applied
        )
        XCTAssertEqual(Array(feeds.allFeed.orderedThreadIds.prefix(3)), [
            "moved-120", "new-110", "old",
        ])
        XCTAssertTrue(feeds.allFeed.trailingDirty)
        XCTAssertFalse(feeds.allFeed.orderedThreadIds.contains("moved-130"))
    }

    func testLocalMutationAbandonsRefreshAndChatUpsertTouchesBothFeeds() throws {
        var feeds = makeFeeds()
        adoptHead(&feeds, filter: .all, rows: [("task", 20), ("chat", 19)])
        adoptHead(&feeds, filter: .nonTask, rows: [("chat", 19)])
        let stale = try XCTUnwrap(feeds.testRequestHead(filter: .all))
        feeds.removeThread("chat")
        XCTAssertEqual(
            feeds.testCompleteHead(stale, bundle: bundle(page([("chat", 30)]))),
            .abandonedLocalMutation
        )
        XCTAssertEqual(feeds.allFeed.orderedThreadIds, ["task"])
        XCTAssertTrue(feeds.nonTaskFeed.orderedThreadIds.isEmpty)

        feeds.upsertChat(threadId: "new-chat")
        XCTAssertEqual(feeds.allFeed.orderedThreadIds.first, "new-chat")
        XCTAssertEqual(feeds.nonTaskFeed.orderedThreadIds.first, "new-chat")
    }

    func testLifecycleForceReplacementThreeOutcomesAndFailedRetry() throws {
        var beforeCommit = makeFeeds()
        adoptHead(&beforeCommit, filter: .all, rows: [("target", 100), ("keep", 90)])
        beforeCommit.forceReplacement()
        let committedTicket = try XCTUnwrap(beforeCommit.testRequestHead(filter: .all))
        _ = beforeCommit.testCompleteHead(
            committedTicket,
            bundle: bundle(page([("keep", 90)]))
        )
        XCTAssertEqual(beforeCommit.allFeed.orderedThreadIds, ["keep"])

        var uncommitted = makeFeeds()
        adoptHead(&uncommitted, filter: .all, rows: [("target", 100), ("keep", 90)])
        uncommitted.forceReplacement()
        let uncommittedTicket = try XCTUnwrap(uncommitted.testRequestHead(filter: .all))
        _ = uncommitted.testCompleteHead(
            uncommittedTicket,
            bundle: bundle(page([("target", 100), ("keep", 90)]))
        )
        XCTAssertEqual(uncommitted.allFeed.orderedThreadIds, ["target", "keep"])

        uncommitted.forceReplacement()
        let failed = try XCTUnwrap(uncommitted.testRequestHead(filter: .all))
        uncommitted.testFailHead(failed)
        XCTAssertEqual(uncommitted.allFeed.orderedThreadIds, ["target", "keep"])
        XCTAssertTrue(uncommitted.allFeed.forceReplacementPending)
        XCTAssertEqual(
            try XCTUnwrap(uncommitted.testRequestHead(filter: .all)).mode,
            .replacement
        )
    }

    func testLifecycleForceReplacementQueuedDuringActiveRefreshCannotBeConsumedByOldTicket() throws {
        var feeds = makeFeeds()
        adoptHead(&feeds, filter: .all, rows: [("target", 100), ("keep", 90)])
        let oldTicket = try XCTUnwrap(feeds.testRequestHead(filter: .all))

        feeds.forceReplacement()
        XCTAssertEqual(
            feeds.testCompleteHead(
                oldTicket,
                bundle: bundle(page([("target", 100), ("keep", 90)]))
            ),
            .forceReplacement
        )
        XCTAssertTrue(feeds.allFeed.forceReplacementPending)

        let replacement = try XCTUnwrap(feeds.testRequestHead(filter: .all))
        XCTAssertEqual(replacement.mode, .replacement)
        XCTAssertEqual(
            feeds.testCompleteHead(replacement, bundle: bundle(page([("keep", 90)]))),
            .applied
        )
        XCTAssertFalse(feeds.allFeed.forceReplacementPending)
        XCTAssertEqual(feeds.allFeed.orderedThreadIds, ["keep"])
    }

    func testPeriodicCycleThirtyUsesReplacementPath() throws {
        var feeds = makeFeeds()
        adoptHead(&feeds, filter: .all, rows: [("head", 100)], hasMore: true)
        for index in 1..<GaryxRecentThreadRangeFill.replacementCycleInterval {
            let ticket = try XCTUnwrap(feeds.testRequestHead(filter: .all))
            if index == GaryxRecentThreadRangeFill.replacementCycleInterval - 1 {
                XCTAssertEqual(ticket.mode, .replacement)
            }
            let head = page([("head", 100)], hasMore: true)
            _ = feeds.testCompleteHead(ticket, bundle: bundle(head))
        }
    }

    private func makeFeeds() -> GaryxRecentThreadFeeds {
        GaryxRecentThreadFeeds.bootstrap(
            pageLimit: 30,
            overlap: 5
        ).feeds
    }

    private func adoptHead(
        _ feeds: inout GaryxRecentThreadFeeds,
        filter: GaryxRecentThreadFilter,
        rows: [(String, Int64)],
        hasMore: Bool = false,
        cursor: String? = nil
    ) {
        let ticket = feeds.testRequestHead(filter: filter)!
        let value = page(
            rows,
            hasMore: hasMore,
            cursor: cursor ?? (hasMore ? "cursor-head" : nil)
        )
        XCTAssertEqual(feeds.testCompleteHead(ticket, bundle: bundle(value)), .applied)
    }

    private func page(
        _ rows: [(String, Int64)],
        hasMore: Bool = false,
        cursor: String? = nil,
        incarnation: String = "inc-a",
        boot: String = "boot-a"
    ) -> GaryxRecentThreadFeedPage {
        GaryxRecentThreadFeedPage(
            storeIncarnationId: incarnation,
            serverBootId: boot,
            rows: rows.map { GaryxRecentThreadFeedRow(id: $0.0, activitySeq: $0.1) },
            hasMore: hasMore,
            nextCursor: cursor ?? (hasMore ? "cursor-tail" : nil)
        )
    }

    private func bundle(
        _ value: GaryxRecentThreadFeedPage
    ) -> GaryxRecentThreadRefreshBundle {
        GaryxRecentThreadRefreshBundle(
            primaryPages: [value],
            verificationPage: value
        )
    }
}

private extension GaryxRecentThreadFeeds {
    mutating func testRequestHead(
        filter: GaryxRecentThreadFilter? = nil,
        forceReplacement: Bool = false
    ) -> GaryxRecentThreadRefreshTicket? {
        let effects = requestHeadEffects(
            filter: filter,
            source: .userAction,
            forceReplacement: forceReplacement
        )
        guard let request = effects.compactMap({ effect -> GaryxRecentHeadRequest? in
            guard case .requestHead(let request) = effect else { return nil }
            return request
        }).first else {
            return nil
        }
        return beginHeadRequest(
            request,
            gatewayScope: "https://gateway.example.test",
            runtimeEpoch: 1
        )
    }

    mutating func testCompleteHead(
        _ ticket: GaryxRecentThreadRefreshTicket,
        bundle: GaryxRecentThreadRefreshBundle
    ) -> GaryxRecentThreadFeedCompletion {
        completeHead(ticket, result: .page(bundle)).outcome
    }

    mutating func testFailHead(
        _ ticket: GaryxRecentThreadRefreshTicket
    ) {
        _ = completeHead(ticket, result: .failed)
    }

    mutating func testCompleteLoadMore(
        _ ticket: GaryxRecentThreadLoadMoreTicket,
        page: GaryxRecentThreadFeedPage
    ) -> GaryxRecentThreadFeedCompletion {
        completeLoadMore(ticket, page: page).outcome
    }
}
