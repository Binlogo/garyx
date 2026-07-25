import Combine
import XCTest
@testable import GaryxMobile

/// The disk hydrate of a thread's persisted committed window must be a
/// **visible** transition.
///
/// `transcriptMirror` is non-published on purpose (live-stream writes touch it
/// per committed message). But `renderSnapshot(for:)` falls back to the mirror,
/// so seeding it with a window that carries a server-owned render snapshot makes
/// content renderable. Before this change nothing published on that seed, so the
/// conversation stayed on the skeleton until an unrelated `@Published` write —
/// in practice a network completion — happened to invalidate the view. The user
/// waited out the network for pixels the model already held.
@MainActor
final class GaryxTranscriptDiskHydrationPublishTests: XCTestCase {
    // MARK: - The regression

    func testDiskHydratePublishesSoContentReplacesSkeletonWithoutNetwork() async {
        let model = makeModel()
        let thread = makeThread(id: "thread::hydrate-publish")
        model.selectedThread = thread
        let store = FakeTranscriptCacheStore(windows: [thread.id: window(for: thread.id)])
        model.transcriptCacheStore = store

        XCTAssertTrue(
            model.isSelectedThreadAwaitingInitialHistory,
            "precondition: a cold thread with nothing in memory shows the skeleton"
        )

        var publishes = 0
        let cancellable = model.objectWillChange.sink { _ in publishes += 1 }
        defer { cancellable.cancel() }

        _ = await model.transcriptSnapshotAsync(for: thread.id)

        // The load itself is the assertion that matters: before this change the
        // seed was silent and `publishes` stayed 0 here. Two publishes, not one:
        // the floor lock bumps `selectedTurnRowsWindowRevision` and the hydrate
        // bumps its own revision, both in the same tick.
        XCTAssertEqual(publishes, 2, "the disk hydrate must publish")
        XCTAssertEqual(model.transcriptMirrorHydrationRevision, 1)

        XCTAssertNotNil(model.renderSnapshot(for: thread.id), "mirror fallback now renders")
        XCTAssertFalse(model.isSelectedThreadAwaitingInitialHistory)
        XCTAssertEqual(
            GaryxConversationTranscriptTreatmentPolicy.treatment(
                localRenderableRowCount: model.selectedThreadTurnRows().count,
                hasRenderedSnapshot: model.renderSnapshot(for: thread.id) != nil,
                isAwaitingInitialHistory: model.isSelectedThreadAwaitingInitialHistory
            ),
            .content
        )
    }

    /// The hydrate must not borrow the live render-snapshot channel: writing
    /// `renderSnapshotsByThread` would flip `hasRenderSnapshot` in
    /// `GaryxColdOpenRestorePolicy.State` and permanently block the dedicated
    /// cold-open restore from applying its messages.
    func testDiskHydrateDoesNotWriteTheLiveRenderSnapshotChannel() async {
        let model = makeModel()
        let thread = makeThread(id: "thread::hydrate-channel")
        model.selectedThread = thread
        model.transcriptCacheStore = FakeTranscriptCacheStore(
            windows: [thread.id: window(for: thread.id)]
        )

        _ = await model.transcriptSnapshotAsync(for: thread.id)

        XCTAssertNil(model.renderSnapshotsByThread[thread.id])
    }

    /// A hydrate that lands before the cold-open restore spawns must leave that
    /// restore able to apply its messages: the restore captures the already
    /// advanced mirror generation, so the generation gate still matches.
    ///
    /// Scope: this pins the *policy inputs* the production spawn would capture at
    /// that moment. It does not drive `spawnColdOpenTranscriptRestore` itself
    /// (which is private and route-callback driven), so it does not assert the
    /// messages actually land.
    func testHydrateLeavesColdOpenRestorePolicyStateAbleToApplyMessages() async {
        let model = makeModel()
        let thread = makeThread(id: "thread::hydrate-then-restore")
        model.selectedThread = thread
        model.transcriptCacheStore = FakeTranscriptCacheStore(
            windows: [thread.id: window(for: thread.id)]
        )

        _ = await model.transcriptSnapshotAsync(for: thread.id)

        // What the restore captures at spawn — i.e. after the hydrate.
        let captured = model.transcriptMirror.generation(for: thread.id)
        let state = GaryxColdOpenRestorePolicy.State(
            restoredThreadId: thread.id,
            selectedThreadId: model.selectedThread?.id,
            capturedGeneration: model.selectedThreadColdOpenGeneration,
            currentGeneration: model.selectedThreadColdOpenGeneration,
            capturedMirrorGeneration: captured,
            currentMirrorGeneration: model.transcriptMirror.generation(for: thread.id),
            threadHistoryLoaded: model.threadHistoryLoadedIds.contains(thread.id),
            hasRenderSnapshot: model.renderSnapshotsByThread[thread.id] != nil,
            hasMessages: !model.cachedMessages(for: thread.id).isEmpty
        )

        XCTAssertTrue(GaryxColdOpenRestorePolicy.shouldApply(state))
    }

    // MARK: - Concurrency

    /// The mirror check in `transcriptSnapshotAsync` happens before its await, so
    /// on a cold open the stream request builder and the initial history fetch
    /// both pass it. Without coalescing each reads the file, each seeds the
    /// mirror, and each advances the generation the restore policy compares.
    func testConcurrentEntrantsCoalesceOntoOneLoadOneSeedOnePublish() async {
        let model = makeModel()
        let thread = makeThread(id: "thread::hydrate-coalesce")
        model.selectedThread = thread
        let store = FakeTranscriptCacheStore(windows: [thread.id: window(for: thread.id)])
        model.transcriptCacheStore = store

        async let first = model.transcriptSnapshotAsync(for: thread.id)
        async let second = model.transcriptSnapshotAsync(for: thread.id)
        let results = await [first, second]

        XCTAssertEqual(store.loadCount, 1, "one disk read")
        XCTAssertEqual(model.transcriptMirror.generation(for: thread.id), 1, "one mirror seed")
        XCTAssertEqual(model.transcriptMirrorHydrationRevision, 1, "one publish")
        XCTAssertEqual(results.compactMap { $0 }.count, 2, "both entrants get the window")
        XCTAssertEqual(results[0], results[1])
    }

    /// A live committed/render write can win the mirror while the load is in
    /// flight. The older disk window must not overwrite it.
    ///
    /// The gate is a real happens-before, not a race: the fake store blocks
    /// inside `load` until the test has finished mutating on the main actor, so
    /// the mutation is ordered before the hydration decision.
    func testLiveMirrorWriteDuringLoadIsNotOverwrittenByTheDiskWindow() async {
        let model = makeModel()
        let thread = makeThread(id: "thread::hydrate-freshness")
        model.selectedThread = thread
        let live = window(for: thread.id, text: "live", basedOnSeq: 9)
        let store = FakeTranscriptCacheStore(
            windows: [thread.id: window(for: thread.id, text: "stale", basedOnSeq: 2)],
            gated: true
        )
        model.transcriptCacheStore = store

        let entered = expectation(description: "load entered")
        store.armEntryExpectation(entered)
        let handle = Task { await model.transcriptSnapshotAsync(for: thread.id) }
        await fulfillment(of: [entered], timeout: 10)
        model.setTranscriptMirror(live, for: thread.id)
        store.releaseLoad()
        let resolved = await handle.value

        XCTAssertEqual(model.transcriptMirror.snapshot(for: thread.id), live)
        XCTAssertEqual(resolved, live, "the caller sees the winning window, not the disk one")
    }

    /// `clearTranscriptCache` is a mirror mutation reachable mid-load from stream
    /// control-rewrite recovery. It leaves the mirror **absent**, so an
    /// "is something there?" check cannot see it — only the TASK-1751 P1
    /// generation can. The cleared window must stay cleared.
    func testNilClearDuringLoadIsNotResurrectedByTheDiskWindow() async {
        let model = makeModel()
        let thread = makeThread(id: "thread::hydrate-clear")
        model.selectedThread = thread
        // Seed the mirror first so the clear has something to invalidate, exactly
        // as recovery would find it.
        model.setTranscriptMirror(window(for: thread.id, text: "pre-clear"), for: thread.id)
        let store = FakeTranscriptCacheStore(
            windows: [thread.id: window(for: thread.id, text: "stale")],
            gated: true
        )
        model.transcriptCacheStore = store
        model.setTranscriptMirror(nil, for: thread.id)

        let entered = expectation(description: "load entered")
        store.armEntryExpectation(entered)
        let handle = Task { await model.transcriptSnapshotAsync(for: thread.id) }
        await fulfillment(of: [entered], timeout: 10)
        model.clearTranscriptCache(for: thread.id)
        store.releaseLoad()
        let resolved = await handle.value

        XCTAssertNil(model.transcriptMirror.snapshot(for: thread.id), "stale window")
        XCTAssertNil(resolved, "the cleared window must not escape to the caller")
    }

    /// The waiter window, isolated: an in-flight entry that has already completed,
    /// with the mirror seeded and then cleared behind it. A coalesced entrant that
    /// resumes here must re-read the mirror rather than hand back the window the
    /// shared task produced — and must not touch the store to find that out.
    ///
    /// Constructed without the store so nothing else can influence the outcome.
    /// (Probe supplied by review #TASK-2712: fails on 1f6f15d44, passes here.)
    func testEntrantResumingOnACompletedEntryRereadsTheMirror() async {
        let model = makeModel()
        let thread = makeThread(id: "thread::hydrate-waiter-window")
        model.selectedThread = thread
        let store = FakeTranscriptCacheStore(windows: [:])
        model.transcriptCacheStore = store

        let completed = Task<Void, Never> {}
        await completed.value
        model.transcriptDiskHydrationTasks[thread.id] = completed
        model.setTranscriptMirror(window(for: thread.id, text: "stale"), for: thread.id)
        model.setTranscriptMirror(nil, for: thread.id)

        let resolved = await model.transcriptSnapshotAsync(for: thread.id)

        XCTAssertNil(resolved, "a frozen shared result must not outlive the mirror")
        XCTAssertEqual(store.loadCount, 0, "resolving a coalesced entrant reads no disk")
    }

    /// A clear issued *reentrantly*, from inside the hydrate's own floor-lock
    /// publish, must not leave the entrant holding the seeded window.
    ///
    /// Scope: this fires while the hydrate is still on the stack — before the
    /// shared task completes — so it stresses publish reentrancy, not the
    /// post-completion waiter window. That window is covered by
    /// `testEntrantResumingOnACompletedEntryRereadsTheMirror`.
    func testClearIssuedReentrantlyFromTheHydratePublishIsNotReturnedToTheEntrant() async {
        let model = makeModel()
        let thread = makeThread(id: "thread::hydrate-late-clear")
        model.selectedThread = thread
        model.transcriptCacheStore = FakeTranscriptCacheStore(
            windows: [thread.id: window(for: thread.id)]
        )

        var cleared = false
        let cancellable = model.objectWillChange.sink { [weak model] _ in
            guard let model, !cleared,
                  model.transcriptMirror.snapshot(for: thread.id) != nil
            else { return }
            cleared = true
            model.clearTranscriptCache(for: thread.id)
        }
        defer { cancellable.cancel() }

        let resolved = await model.transcriptSnapshotAsync(for: thread.id)

        XCTAssertTrue(cleared, "precondition: the clear ran after the seed")
        XCTAssertNil(model.transcriptMirror.snapshot(for: thread.id))
        XCTAssertNil(resolved, "a stale window must not be handed to the entrant")
    }

    /// Thread ids are not unique across gateways. An entrant whose scope was left
    /// mid-load must get nothing — never the destination scope's window, whose
    /// `afterCursor` would be fed into this entrant's stream/history request.
    func testEntrantFromAnExitedScopeNeverReceivesTheDestinationScopesWindow() async {
        let model = makeModel()
        let thread = makeThread(id: "thread::hydrate-cross-scope")
        model.selectedThread = thread
        let store = FakeTranscriptCacheStore(
            windows: [thread.id: window(for: thread.id, text: "origin")],
            gated: true
        )
        model.transcriptCacheStore = store

        let entered = expectation(description: "load entered")
        store.armEntryExpectation(entered)
        let handle = Task { await model.transcriptSnapshotAsync(for: thread.id) }
        await fulfillment(of: [entered], timeout: 10)
        model.resetGatewayRuntimeState()
        model.gatewayRequestToken = GaryxGatewayRequestToken(
            scope: GaryxGatewayScope(identity: "destination-gateway", epoch: 1),
            activationSequence: 2
        )
        // The destination scope legitimately populates the same thread id.
        let destination = window(for: thread.id, text: "destination", turns: 50)
        model.setTranscriptMirror(destination, for: thread.id)
        store.releaseLoad()
        let resolved = await handle.value

        XCTAssertNil(resolved, "the exited scope's entrant must receive nothing")
        XCTAssertEqual(
            model.transcriptMirror.snapshot(for: thread.id),
            destination,
            "the destination scope's own window is untouched"
        )
    }

    /// A gateway switch drops the whole mirror, but `clearAll` can only bump the
    /// generation of threads that were *present* — a thread being hydrated for the
    /// first time was absent, so the generation alone cannot tell that its decoded
    /// window belongs to a scope the app has left. The request token can.
    func testGatewaySwitchDuringLoadDiscardsTheExitedScopesWindow() async {
        let model = makeModel()
        let thread = makeThread(id: "thread::hydrate-scope")
        model.selectedThread = thread
        let store = FakeTranscriptCacheStore(
            windows: [thread.id: window(for: thread.id, text: "old gateway")],
            gated: true
        )
        model.transcriptCacheStore = store

        let entered = expectation(description: "load entered")
        store.armEntryExpectation(entered)
        let handle = Task { await model.transcriptSnapshotAsync(for: thread.id) }
        await fulfillment(of: [entered], timeout: 10)
        model.resetGatewayRuntimeState()
        model.gatewayRequestToken = GaryxGatewayRequestToken(
            scope: GaryxGatewayScope(identity: "other-gateway", epoch: 1),
            activationSequence: 2
        )
        store.releaseLoad()
        let resolved = await handle.value

        XCTAssertNil(
            model.transcriptMirror.snapshot(for: thread.id),
            "the exited scope's decoded window must not be re-seeded after reset"
        )
        XCTAssertNil(resolved)

        // And it must not surface on a later selection of the same thread id.
        model.selectedThread = thread
        XCTAssertNil(model.renderSnapshot(for: thread.id), "old render snapshot")
    }

    // MARK: - Window floor

    func testHydrateAnchorsTheWindowFloor() async {
        let model = makeModel()
        let thread = makeThread(id: "thread::hydrate-floor")
        model.selectedThread = thread
        model.transcriptCacheStore = FakeTranscriptCacheStore(
            windows: [thread.id: window(for: thread.id)]
        )

        XCTAssertNil(model.selectedTurnRowsWindowState.floorRowId)

        _ = await model.transcriptSnapshotAsync(for: thread.id)

        XCTAssertNotNil(
            model.selectedTurnRowsWindowState.floorRowId,
            "the hydrate must anchor the P3 floor the way setRenderSnapshot does"
        )
    }

    /// The reason the floor matters: with it anchored, an active run appending
    /// tail rows grows the window at the bottom instead of sliding the head.
    func testAnchoredFloorKeepsTheHeadStableWhenARunAppendsTailRows() async {
        let model = makeModel()
        let thread = makeThread(id: "thread::hydrate-floor-append")
        model.selectedThread = thread
        let turns = GaryxTurnRowsWindowPlannerLimits.initialLimit + 10
        model.transcriptCacheStore = FakeTranscriptCacheStore(
            windows: [thread.id: window(for: thread.id, turns: turns)]
        )

        _ = await model.transcriptSnapshotAsync(for: thread.id)
        let headBeforeAppend = model.selectedThreadTurnRows().first?.id
        XCTAssertNotNil(headBeforeAppend)

        // A run appends at the tail, exactly as a live frame would.
        model.setTranscriptMirror(window(for: thread.id, turns: turns + 5), for: thread.id)

        XCTAssertEqual(
            model.selectedThreadTurnRows().first?.id,
            headBeforeAppend,
            "an anchored floor must not slide when rows are appended"
        )
    }

    // MARK: - Windows with no render snapshot

    func testWindowWithoutRenderSnapshotStillSeedsAndPublishesButAnchorsNoFloor() async {
        let model = makeModel()
        let thread = makeThread(id: "thread::hydrate-no-snapshot")
        model.selectedThread = thread
        model.transcriptCacheStore = FakeTranscriptCacheStore(
            windows: [thread.id: window(for: thread.id, includeRenderSnapshot: false)]
        )

        _ = await model.transcriptSnapshotAsync(for: thread.id)

        XCTAssertNotNil(model.transcriptMirror.snapshot(for: thread.id), "cursor seed still happens")
        XCTAssertEqual(model.transcriptMirrorHydrationRevision, 1)
        XCTAssertNil(model.selectedTurnRowsWindowState.floorRowId, "nothing renderable to anchor")
        XCTAssertTrue(model.isSelectedThreadAwaitingInitialHistory, "still genuinely waiting")
    }

    // MARK: - Non-selected threads

    func testHydrateForANonSelectedThreadSeedsWithoutTouchingSelectedPresentation() async {
        let model = makeModel()
        let selected = makeThread(id: "thread::hydrate-selected")
        let other = makeThread(id: "thread::hydrate-other")
        model.selectedThread = selected
        model.transcriptCacheStore = FakeTranscriptCacheStore(
            windows: [other.id: window(for: other.id)]
        )

        _ = await model.transcriptSnapshotAsync(for: other.id)

        XCTAssertNotNil(model.transcriptMirror.snapshot(for: other.id))
        XCTAssertEqual(model.transcriptMirrorHydrationRevision, 0, "not the selected thread")
        XCTAssertNil(model.selectedTurnRowsWindowState.floorRowId)
    }

    // MARK: - Live writes stay silent

    /// Asserts the actual publish, not just this revision: a `setTranscriptMirror`
    /// that sent `objectWillChange` directly would still leave the revision at 0.
    func testLiveMirrorWritesPublishNothing() {
        let model = makeModel()
        let thread = makeThread(id: "thread::hydrate-live-silent")
        model.selectedThread = thread

        var publishes = 0
        let cancellable = model.objectWillChange.sink { _ in publishes += 1 }
        defer { cancellable.cancel() }

        for seq in 1...5 {
            model.setTranscriptMirror(
                window(for: thread.id, basedOnSeq: seq),
                for: thread.id
            )
        }

        XCTAssertEqual(publishes, 0, "streaming mirror writes must stay silent")
        XCTAssertEqual(model.transcriptMirrorHydrationRevision, 0)
    }

    // MARK: - Fixtures

    private func makeModel() -> GaryxMobileModel {
        let suiteName = "GaryxTranscriptDiskHydrationPublishTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return GaryxMobileModel(defaults: defaults)
    }

    private func makeThread(id: String) -> GaryxThreadSummary {
        GaryxThreadSummary(
            id: id,
            title: "Hydration Thread",
            createdAt: nil,
            updatedAt: nil,
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

    /// A persisted window shaped like one the SSE path writes: committed
    /// messages plus the server-owned render snapshot that references them.
    private func window(
        for threadId: String,
        text: String = "cached",
        basedOnSeq: Int = 2,
        turns: Int = 1,
        includeRenderSnapshot: Bool = true
    ) -> GaryxCachedTranscript {
        var messages: [GaryxTranscriptMessage] = []
        var rows: [GaryxRenderRow] = []
        for turn in 0..<turns {
            let userSeq = turn * 2 + 1
            let replySeq = userSeq + 1
            messages.append(
                GaryxTranscriptMessage(index: userSeq - 1, role: .user, text: "\(text) ask \(turn)")
            )
            messages.append(
                GaryxTranscriptMessage(
                    index: replySeq - 1,
                    role: .assistant,
                    text: "\(text) reply \(turn)"
                )
            )
            rows.append(
                .userTurn(GaryxRenderUserTurnRow(
                    id: "turn:\(userSeq)",
                    user: GaryxRenderMessageRef(id: "seq:\(userSeq)", seq: userSeq, role: "user"),
                    activity: [
                        .assistantReply(GaryxRenderAssistantReplyRow(
                            id: "reply:\(replySeq)",
                            message: GaryxRenderMessageRef(
                                id: "seq:\(replySeq)",
                                seq: replySeq,
                                role: "assistant"
                            )
                        )),
                    ]
                ))
            )
        }
        let snapshot: GaryxRenderSnapshot? = includeRenderSnapshot
            ? GaryxRenderSnapshot(
                basedOnSeq: max(basedOnSeq, turns * 2),
                rows: rows,
                tailActivity: .none
            )
            : nil
        return GaryxCachedTranscript(
            threadId: threadId,
            savedAt: Date(timeIntervalSince1970: 0),
            messages: messages,
            renderSnapshot: snapshot,
            hasMoreBefore: false,
            nextBeforeIndex: nil
        )
    }
}

/// Mirrors `GaryxTurnRowsWindowPlanner.initialLimit`, which is internal to
/// GaryxMobileCore.
private enum GaryxTurnRowsWindowPlannerLimits {
    static let initialLimit = 60
}

private final class FakeTranscriptCacheStore: GaryxTranscriptCacheStore, @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [String: GaryxCachedTranscript]
    private var loads = 0
    /// When gated, `load` announces entry and then blocks until the test releases
    /// it. The persistence queue runs `load` off the main actor, so a test can
    /// mutate model state on the main actor and know that mutation is ordered
    /// before the load returns — a real happens-before instead of a race.
    ///
    /// Entry is announced through an `XCTestExpectation` so the waiting side has a
    /// timeout: a regression that stops `load` from being reached fails the test
    /// instead of hanging the suite forever. (A bare continuation cannot be timed
    /// out, and `DispatchSemaphore.wait` is unavailable from async contexts in
    /// Swift 6.) The release side stays a semaphore — the store protocol's `load`
    /// is synchronous — and is bounded for the same reason.
    private let gated: Bool
    private var enteredLoad = false
    private var entryExpectation: XCTestExpectation?
    private let release = DispatchSemaphore(value: 0)

    init(windows: [String: GaryxCachedTranscript], gated: Bool = false) {
        self.windows = windows
        self.gated = gated
    }

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loads
    }

    /// Arm an expectation that fulfills when `load` is entered. Await it with
    /// `fulfillment(of:timeout:)`.
    func armEntryExpectation(_ expectation: XCTestExpectation) {
        lock.lock()
        let already = enteredLoad
        if !already { entryExpectation = expectation }
        lock.unlock()
        if already { expectation.fulfill() }
    }

    func releaseLoad() {
        release.signal()
    }

    func load(threadId: String) -> GaryxCachedTranscript? {
        lock.lock()
        loads += 1
        let window = windows[threadId]
        var expectation: XCTestExpectation?
        if gated {
            enteredLoad = true
            expectation = entryExpectation
            entryExpectation = nil
        }
        lock.unlock()
        if gated {
            expectation?.fulfill()
            _ = release.wait(timeout: .now() + 10)
        }
        return window
    }

    func save(_ snapshot: GaryxCachedTranscript) {
        lock.lock()
        defer { lock.unlock() }
        windows[snapshot.threadId] = snapshot
    }

    func remove(threadId: String) {
        lock.lock()
        defer { lock.unlock() }
        windows[threadId] = nil
    }

    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        windows.removeAll()
    }
}
