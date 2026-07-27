import XCTest
@testable import GaryxMobileCore

final class GaryxRecentHeadPhaseTests: XCTestCase {
    private struct PhaseProvenance {
        var label: String
        var phase: GaryxRecentHeadPhase
        var effects: [GaryxRecentFeedEffect]
    }

    private let stalls: [GaryxRecentHeadStall] = [
        .networkFailure,
        .interrupted,
        .supersededByReset,
        .identityReplacement,
        .racedLocalMutation,
    ]

    func testEveryReachableSkeletonHasAttemptOrRequestEffect() throws {
        var records: [PhaseProvenance] = []

        let bootstrap = makeBootstrap()
        records.append(
            PhaseProvenance(
                label: "bootstrap owed",
                phase: bootstrap.feeds.allFeed.headPhase,
                effects: bootstrap.effects
            )
        )

        var primingFeeds = bootstrap.feeds
        let primingTicket = try begin(
            effects: bootstrap.effects,
            in: &primingFeeds
        )
        records.append(
            PhaseProvenance(
                label: "priming attempt",
                phase: primingFeeds.allFeed.headPhase,
                effects: []
            )
        )
        let readyCompletion = primingFeeds.completeHead(
            primingTicket,
            result: .page(bundle(page: page()))
        )
        records.append(
            PhaseProvenance(
                label: "ready",
                phase: primingFeeds.allFeed.headPhase,
                effects: readyCompletion.effects
            )
        )

        let refreshEffects = primingFeeds.requestHeadEffects(
            filter: .all,
            source: .backgroundLoop
        )
        _ = try begin(effects: refreshEffects, in: &primingFeeds)
        records.append(
            PhaseProvenance(
                label: "refreshing attempt",
                phase: primingFeeds.allFeed.headPhase,
                effects: []
            )
        )

        for stall in stalls {
            var unprimed = makeBootstrap().feeds
            let initialEffects = unprimed.requestHeadEffects(
                filter: .all,
                source: .userAction
            )
            let initial = try begin(effects: initialEffects, in: &unprimed)
            let unprimedCompletion = unprimed.completeHead(
                initial,
                result: .interrupted(stall)
            )
            records.append(
                PhaseProvenance(
                    label: "unprimed immediate \(stall)",
                    phase: unprimed.allFeed.headPhase,
                    effects: unprimedCompletion.effects
                )
            )

            var primed = try makePrimedFeeds()
            let effects = primed.requestHeadEffects(
                filter: .all,
                source: .userAction
            )
            let refresh = try begin(effects: effects, in: &primed)
            let completion = primed.completeHead(
                refresh,
                result: .interrupted(stall)
            )
            records.append(
                PhaseProvenance(
                    label: "ready stale immediate \(stall)",
                    phase: primed.allFeed.headPhase,
                    effects: completion.effects
                )
            )
        }

        var failedCold = makeBootstrap().feeds
        let failedColdEffects = failedCold.requestHeadEffects(
            filter: .all,
            source: .userAction
        )
        let failedColdTicket = try begin(
            effects: failedColdEffects,
            in: &failedCold
        )
        let failedColdCompletion = failedCold.completeHead(
            failedColdTicket,
            result: .failed
        )
        records.append(
            PhaseProvenance(
                label: "unprimed user action failure",
                phase: failedCold.allFeed.headPhase,
                effects: failedColdCompletion.effects
            )
        )

        var failedWarm = try makePrimedFeeds()
        let failedWarmEffects = failedWarm.requestHeadEffects(
            filter: .all,
            source: .userAction
        )
        let failedWarmTicket = try begin(
            effects: failedWarmEffects,
            in: &failedWarm
        )
        let failedWarmCompletion = failedWarm.completeHead(
            failedWarmTicket,
            result: .failed
        )
        records.append(
            PhaseProvenance(
                label: "ready stale user action failure",
                phase: failedWarm.allFeed.headPhase,
                effects: failedWarmCompletion.effects
            )
        )

        for record in records {
            let presentation = GaryxRecentThreadFeedPresentation(
                headPhase: record.phase
            )
            guard case .loadingSkeleton = presentation.placeholder(rowsAreEmpty: true) else {
                continue
            }
            XCTAssertTrue(
                record.phase.activeAttempt != nil || containsHeadRequest(record.effects),
                "\(record.label) rendered a skeleton without an attempt or request effect"
            )
        }
    }

    func testPhaseEventMatrixCannotReachUnknownIdleState() {
        let seeds: [(String, () -> GaryxRecentHeadState)] = [
            ("priming owed immediate", makeInitialState),
            ("priming owed user", makePrimingOwedUserState),
            ("priming", makePrimingState),
            ("ready", makeReadyState),
            ("refreshing", makeRefreshingState),
            ("ready stale immediate", makeReadyStaleImmediateState),
            ("ready stale user", makeReadyStaleUserState),
        ]
        var events: [(String, (inout GaryxRecentHeadState) -> Void)] = [
            ("begin", { _ = $0.beginAttempt() }),
            ("success", { state in
                _ = state.settleSuccess(self.attemptForSettlement(in: state))
            }),
            ("settle immediate", { state in
                _ = state.settle(
                    self.attemptForSettlement(in: state),
                    stalledBy: .interrupted,
                    demand: .immediate
                )
            }),
            ("settle user", { state in
                _ = state.settle(
                    self.attemptForSettlement(in: state),
                    stalledBy: .networkFailure,
                    demand: .userAction
                )
            }),
            ("downgrade", { _ = $0.downgradeImmediateDemandToUserAction() }),
        ]
        for stall in stalls {
            events.append(("reset \(stall)", { $0.reset(stalledBy: stall) }))
            events.append(
                ("owe \(stall)", { $0.oweImmediate(stalledBy: stall) })
            )
            for demand in [
                GaryxRecentHeadDemand.immediate,
                .userAction,
            ] {
                events.append(
                    ("invalidate \(stall) \(demand)", {
                        $0.invalidate(stalledBy: stall, demand: demand)
                    })
                )
            }
        }

        for (seedName, seed) in seeds {
            for (eventName, event) in events {
                var state = seed()
                event(&state)
                assertNoUnknownIdle(
                    state.phase,
                    context: "\(seedName) × \(eventName)"
                )
            }
        }
    }

    func testBootstrapStartsOwedAndReturnsRequestEffect() {
        let bootstrap = makeBootstrap()
        XCTAssertEqual(
            bootstrap.feeds.allFeed.headPhase,
            .primingOwed(.supersededByReset, .immediate)
        )
        XCTAssertTrue(
            bootstrap.effects.contains { effect in
                guard case .requestHead(let request) = effect else { return false }
                return request.filter == .all
            }
        )
    }

    func testEveryUnifiedCompletionPathReturnsEffects() throws {
        var success = makeBootstrap().feeds
        let successTicket = try begin(
            effects: success.requestHeadEffects(
                filter: .all,
                source: .userAction
            ),
            in: &success
        )
        assertEffects(
            success.completeHead(
                successTicket,
                result: .page(bundle(page: page()))
            ),
            path: "success"
        )

        var failed = makeBootstrap().feeds
        let failedTicket = try begin(
            effects: failed.requestHeadEffects(
                filter: .all,
                source: .userAction
            ),
            in: &failed
        )
        assertEffects(
            failed.completeHead(failedTicket, result: .failed),
            path: "failure"
        )

        for stall in stalls {
            var interrupted = makeBootstrap().feeds
            let ticket = try begin(
                effects: interrupted.requestHeadEffects(
                    filter: .all,
                    source: .userAction
                ),
                in: &interrupted
            )
            assertEffects(
                interrupted.completeHead(
                    ticket,
                    result: .interrupted(stall)
                ),
                path: "interrupted \(stall)"
            )
        }

        var reset = makeBootstrap().feeds
        let staleTicket = try begin(
            effects: reset.requestHeadEffects(
                filter: .all,
                source: .userAction
            ),
            in: &reset
        )
        _ = reset.resetFeedData()
        assertEffects(
            reset.completeHead(
                staleTicket,
                result: .page(bundle(page: page()))
            ),
            path: "stale epoch"
        )

        var locallyMutated = try makePrimedFeeds()
        let localTicket = try begin(
            effects: locallyMutated.requestHeadEffects(
                filter: .all,
                source: .userAction
            ),
            in: &locallyMutated
        )
        locallyMutated.removeThread("missing")
        assertEffects(
            locallyMutated.completeHead(
                localTicket,
                result: .page(bundle(page: page()))
            ),
            path: "local mutation"
        )

        var identityChanged = try makePrimedFeeds()
        let identityTicket = try begin(
            effects: identityChanged.requestHeadEffects(
                filter: .all,
                source: .userAction
            ),
            in: &identityChanged
        )
        assertEffects(
            identityChanged.completeHead(
                identityTicket,
                result: .page(
                    bundle(
                        page: page(
                            incarnation: "replacement-incarnation"
                        )
                    )
                )
            ),
            path: "identity replacement"
        )
    }

    private func makeBootstrap() -> GaryxRecentThreadFeedsBootstrap {
        GaryxRecentThreadFeeds.bootstrap(
            pageLimit: 30,
            overlap: 5
        )
    }

    private func makePrimedFeeds() throws -> GaryxRecentThreadFeeds {
        let bootstrap = makeBootstrap()
        var feeds = bootstrap.feeds
        let ticket = try begin(effects: bootstrap.effects, in: &feeds)
        let completion = feeds.completeHead(
            ticket,
            result: .page(bundle(page: page()))
        )
        XCTAssertEqual(completion.outcome, .applied)
        return feeds
    }

    private func begin(
        effects: [GaryxRecentFeedEffect],
        in feeds: inout GaryxRecentThreadFeeds
    ) throws -> GaryxRecentThreadRefreshTicket {
        let effect = try XCTUnwrap(effects.first { effect in
            guard case .requestHead(let request) = effect else { return false }
            return request.filter == .all
        })
        guard case .requestHead(let request) = effect else {
            throw TestError.missingRequest
        }
        return try XCTUnwrap(
            feeds.beginHeadRequest(
                request,
                gatewayScope: "https://gateway.example.test",
                runtimeEpoch: 1
            )
        )
    }

    private func page(
        incarnation: String = "incarnation-a"
    ) -> GaryxRecentThreadFeedPage {
        GaryxRecentThreadFeedPage(
            storeIncarnationId: incarnation,
            serverBootId: "boot-a",
            rows: [],
            hasMore: false,
            nextCursor: nil
        )
    }

    private func bundle(
        page: GaryxRecentThreadFeedPage
    ) -> GaryxRecentThreadRefreshBundle {
        GaryxRecentThreadRefreshBundle(
            primaryPages: [page],
            verificationPage: page
        )
    }

    private func containsHeadRequest(
        _ effects: [GaryxRecentFeedEffect]
    ) -> Bool {
        effects.contains { effect in
            if case .requestHead = effect {
                return true
            }
            return false
        }
    }

    private func assertEffects(
        _ completion: GaryxRecentHeadCompletion,
        path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            completion.effects.isEmpty,
            "\(path) cleared or rejected a lane without an effect",
            file: file,
            line: line
        )
    }

    private func assertNoUnknownIdle(
        _ phase: GaryxRecentHeadPhase,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if !phase.isPrimed && phase.activeAttempt == nil {
            XCTAssertNotNil(
                phase.demand,
                "\(context) reached unknown content with an idle, unowned lane",
                file: file,
                line: line
            )
        }
        let presentation = GaryxRecentThreadFeedPresentation(
            headPhase: phase
        )
        if case .loadingSkeleton = presentation.placeholder(rowsAreEmpty: true) {
            XCTAssertTrue(
                phase.activeAttempt != nil || phase.owesImmediateRequest,
                "\(context) rendered loading without a transport proof or owed effect",
                file: file,
                line: line
            )
        }
    }

    private func attemptForSettlement(
        in state: GaryxRecentHeadState
    ) -> GaryxRecentHeadAttempt {
        if let active = state.phase.activeAttempt {
            return active
        }
        var copy = state
        if let attempt = copy.beginAttempt() {
            copy.reset()
            return attempt
        }
        copy.reset()
        return copy.beginAttempt()!
    }

    private func makeInitialState() -> GaryxRecentHeadState {
        GaryxRecentHeadState()
    }

    private func makePrimingState() -> GaryxRecentHeadState {
        var state = makeInitialState()
        _ = state.beginAttempt()
        return state
    }

    private func makePrimingOwedUserState() -> GaryxRecentHeadState {
        var state = makePrimingState()
        _ = state.settle(
            state.phase.activeAttempt!,
            stalledBy: .networkFailure,
            demand: .userAction
        )
        return state
    }

    private func makeReadyState() -> GaryxRecentHeadState {
        var state = makePrimingState()
        _ = state.settleSuccess(state.phase.activeAttempt!)
        return state
    }

    private func makeRefreshingState() -> GaryxRecentHeadState {
        var state = makeReadyState()
        _ = state.beginAttempt()
        return state
    }

    private func makeReadyStaleImmediateState() -> GaryxRecentHeadState {
        var state = makeRefreshingState()
        _ = state.settle(
            state.phase.activeAttempt!,
            stalledBy: .interrupted,
            demand: .immediate
        )
        return state
    }

    private func makeReadyStaleUserState() -> GaryxRecentHeadState {
        var state = makeRefreshingState()
        _ = state.settle(
            state.phase.activeAttempt!,
            stalledBy: .networkFailure,
            demand: .userAction
        )
        return state
    }

    private enum TestError: Error {
        case missingRequest
    }
}
