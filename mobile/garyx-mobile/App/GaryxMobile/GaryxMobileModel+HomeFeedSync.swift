import Foundation

/// Structural capability for the only code path allowed to start a Recent
/// head transport. Callers can carry it into the transport port but cannot
/// construct it.
struct GaryxHomeFeedSyncAuthority {
    fileprivate init() {}
}

@MainActor
final class GaryxHomeFeedSyncCoordinator {
    private struct UserIntent {
        var source: GaryxThreadListRefreshSource
        var forceReplacement: Bool
        var refreshesSelectedFeedOnly: Bool
    }

    private struct Waiter {
        var filters: Set<GaryxRecentThreadFilter>
        var continuation: CheckedContinuation<Void, Never>
    }

    private weak var owner: GaryxMobileModel?
    private let scopeToken: GaryxGatewayRequestToken?
    private var scopeIsActive: Bool
    private var connection: GaryxHomeFeedConnection = .down
    private var isHomeVisible = true
    private var isSceneBackgrounded = false
    private var pendingEffects: [GaryxRecentFeedEffect]
    private var pendingFavoritesSnapshotTicket: GaryxFavoritesSnapshotTicket?
    private var pendingUserIntent: UserIntent?
    private var waiters: [UUID: Waiter] = [:]
    private var syncState = GaryxHomeFeedSyncState()
    private var transportTasks: [UUID: Task<Void, Never>] = [:]
    private var timerTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?
    private let immediateDemandTimeout: TimeInterval
    private let now: () -> Date
    private let automaticallyEvaluatesWakeSignals: Bool
    private let wakeStream: AsyncStream<Void>
    private let wakeContinuation: AsyncStream<Void>.Continuation
    #if DEBUG
    private var startedHeadRequestsForTesting: [GaryxRecentHeadRequest] = []
    #endif

    init(
        initialEffects: [GaryxRecentFeedEffect],
        initialFavoritesSnapshotTicket: GaryxFavoritesSnapshotTicket? = nil,
        immediateDemandTimeout: TimeInterval,
        scopeToken: GaryxGatewayRequestToken? = nil,
        now: @escaping () -> Date = Date.init,
        automaticallyEvaluatesWakeSignals: Bool = true
    ) {
        pendingEffects = initialEffects
        pendingFavoritesSnapshotTicket = initialFavoritesSnapshotTicket
        self.immediateDemandTimeout = immediateDemandTimeout
        self.scopeToken = scopeToken
        self.now = now
        self.automaticallyEvaluatesWakeSignals = automaticallyEvaluatesWakeSignals
        scopeIsActive = scopeToken != nil
        var continuation: AsyncStream<Void>.Continuation?
        wakeStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        wakeContinuation = continuation!
    }

    deinit {
        timerTask?.cancel()
        loopTask?.cancel()
        transportTasks.values.forEach { $0.cancel() }
        wakeContinuation.finish()
    }

    func attach(_ owner: GaryxMobileModel) {
        self.owner = owner
        if automaticallyEvaluatesWakeSignals, loopTask == nil {
            let stream = wakeStream
            loopTask = Task { [weak self] in
                var iterator = stream.makeAsyncIterator()
                while !Task.isCancelled {
                    let signal: Void? = await iterator.next()
                    if Task.isCancelled || signal == nil {
                        continue
                    }
                    self?.evaluateUntilWaiting()
                }
            }
        }
        wake()
    }

    func deactivateScope() {
        scopeIsActive = false
        connection = .down
        pendingEffects = []
        pendingFavoritesSnapshotTicket = nil
        pendingUserIntent = nil
        timerTask?.cancel()
        timerTask = nil
        transportTasks.values.forEach { $0.cancel() }
        owner?.cancelThreadFavoritesSnapshotTransport()
        settleAllWaiters()
        wake()
    }

    func takePendingEffectsForScopeReplacement() -> [GaryxRecentFeedEffect] {
        let effects = pendingEffects
        pendingEffects = []
        return effects
    }

    func takePendingFavoritesSnapshotForScopeReplacement()
        -> GaryxFavoritesSnapshotTicket? {
        let ticket = pendingFavoritesSnapshotTicket
        pendingFavoritesSnapshotTicket = nil
        return ticket
    }

    func enqueueFavoritesSnapshot(_ ticket: GaryxFavoritesSnapshotTicket) {
        pendingFavoritesSnapshotTicket = ticket
        owner?.cancelThreadFavoritesSnapshotTransport()
        wake()
    }

    #if DEBUG
    func waitForTransportIdleForTesting() async {
        while !transportTasks.isEmpty {
            await Task.yield()
        }
    }

    func hasQueuedHeadRequestForTesting(_ filter: GaryxRecentThreadFilter) -> Bool {
        hasQueuedRequest(for: filter)
    }

    func hasPendingUserIntentForTesting(
        _ source: GaryxThreadListRefreshSource
    ) -> Bool {
        pendingUserIntent?.source == source
    }

    func hasScheduledTimerForTesting() -> Bool {
        timerTask != nil
    }

    func evaluateForTesting() {
        evaluateUntilWaiting()
    }

    func startedHeadRequestCountForTesting(
        _ filter: GaryxRecentThreadFilter
    ) -> Int {
        startedHeadRequestsForTesting.count { $0.filter == filter }
    }
    #endif

    func updateConnection(_ state: GaryxMobileConnectionState) {
        switch state {
        case .ready:
            connection = .ready
        case .checking:
            connection = .checking
        case .disconnected, .failed:
            connection = .down
        }
        wake()
    }

    func updateHomeVisibility(_ isHomeVisible: Bool) {
        self.isHomeVisible = isHomeVisible
        wake()
    }

    func updateSceneBackgrounded(_ isBackgrounded: Bool) {
        isSceneBackgrounded = isBackgrounded
        wake()
    }

    func homeDomainDidChange() {
        wake()
    }

    func runRecentFeedEffects(_ effects: [GaryxRecentFeedEffect]) {
        for effect in effects {
            switch effect {
            case .publish:
                owner?.emitHomeProjectionSnapshot()
            case .requestHead(let request):
                if let index = pendingEffects.lastIndex(where: { pending in
                    guard case .requestHead(let queued) = pending else { return false }
                    return queued.filter == request.filter
                }), case .requestHead(let queued) = pendingEffects[index] {
                    pendingEffects[index] = .requestHead(queued.merging(request))
                } else {
                    pendingEffects.append(effect)
                }
            }
        }
        wake()
    }

    func submitUserIntent(
        source: GaryxThreadListRefreshSource,
        forceReplacement: Bool
    ) async {
        guard let owner, owner.hasGatewaySettings else { return }
        let waiterId = UUID()
        let filter = owner.recentThreadFeeds.selectedFilter
        mergeUserIntent(
            UserIntent(
                source: source,
                forceReplacement: forceReplacement,
                refreshesSelectedFeedOnly: source == .userPullToRefresh
            )
        )
        wake()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[waiterId] = Waiter(
                    filters: [filter],
                    continuation: continuation
                )
                settleWaitersIfConverged()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterId)
            }
        }
    }

    /// Connect orchestration has already passed the reachability gate. Merge
    /// its selected-feed work into any bootstrap effect, then synchronously
    /// claim the transport before unrelated background domains are launched.
    func startSelectedFeedRefreshForConnect() {
        guard let owner, owner.hasGatewaySettings else { return }
        let effects = owner.makeHomeFeedRefreshEffects(
            source: .userAction,
            forceReplacement: false,
            refreshesSelectedFeedOnly: true,
            authority: GaryxHomeFeedSyncAuthority()
        )
        runRecentFeedEffects(effects)
        evaluateUntilWaiting()
    }

    func replaceAllRecentFeeds() async {
        guard let owner, owner.hasGatewaySettings else { return }
        let waiterId = UUID()
        let effects = owner.makeAllRecentReplacementEffects(
            authority: GaryxHomeFeedSyncAuthority()
        )
        runRecentFeedEffects(effects)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[waiterId] = Waiter(
                    filters: [.all, .nonTask],
                    continuation: continuation
                )
                settleWaitersIfConverged()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterId)
            }
        }
    }

    func waitForFavoritesConvergence() async {
        let waiterId = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[waiterId] = Waiter(
                    filters: [.favorites],
                    continuation: continuation
                )
                settleWaitersIfConverged()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterId)
            }
        }
    }

    private func evaluateUntilWaiting() {
        timerTask?.cancel()
        timerTask = nil

        evaluation: while !Task.isCancelled {
            drainRunnableEffects()
            settleWaitersIfConverged()

            if !scopeIsActive || scopeToken == nil || owner == nil {
                break evaluation
            }

            let phase = selectedPhase
            if phase.owesImmediateRequest {
                if syncState.immediateOwedSince == nil {
                    syncState.immediateOwedSince = now()
                }
            } else {
                syncState.immediateOwedSince = nil
            }

            let action = GaryxHomeFeedSyncPlanner.next(
                state: syncState,
                demand: GaryxHomeFeedDemand(
                    phase: phase,
                    hasPendingUserIntent: pendingUserIntent != nil,
                    queuedHeadRequest: selectedQueuedHeadRequest
                ),
                visibility: visibility,
                connection: connection,
                now: now(),
                immediateDemandTimeout: immediateDemandTimeout
            )
            switch action {
            case .waitForExternalWake:
                // Structural invariant: this is the only timer-less live
                // exit. The planner must name the owner edge that will call
                // `wake()` (connection, visibility, transport, load-more, or
                // a future user intent). Every other live exit schedules a
                // timer; inactive scopes have no retained demand.
                break evaluation
            case .sleep(let deadline):
                scheduleTimer(at: deadline)
                break evaluation
            case .downgradeImmediateDemand:
                downgradeSelectedImmediateDemand()
                continue
            case .refreshNow(let reason):
                let intent = pendingUserIntent
                pendingUserIntent = nil
                let source = intent?.source
                    ?? (reason == .userIntent ? .userAction : .backgroundLoop)
                if let owner {
                    let effects = owner.makeHomeFeedRefreshEffects(
                        source: source,
                        forceReplacement: intent?.forceReplacement ?? false,
                        refreshesSelectedFeedOnly:
                            intent?.refreshesSelectedFeedOnly ?? false,
                        authority: GaryxHomeFeedSyncAuthority()
                    )
                    runRecentFeedEffects(effects)
                }
                continue
            }
        }
    }

    private func downgradeSelectedImmediateDemand() {
        guard let owner else { return }
        let selected = owner.recentThreadFeeds.selectedFilter
        pendingEffects.removeAll { effect in
            guard case .requestHead(let request) = effect else { return false }
            return request.filter == selected
        }
        let effects = owner.downgradeSelectedHomeFeedDemand(
            authority: GaryxHomeFeedSyncAuthority()
        )
        runRecentFeedEffects(effects)
    }

    private func drainRunnableEffects() {
        guard connection == .ready,
              !isSceneBackgrounded,
              scopeIsActive,
              let owner,
              let scopeToken else { return }

        let selected = owner.recentThreadFeeds.selectedFilter
        if selected == .favorites {
            drainPendingFavoritesSnapshot(owner: owner)
        }
        let orderedEffects = pendingEffects.enumerated().sorted { lhs, rhs in
            let lhsPriority = effectPriority(lhs.element, selected: selected)
            let rhsPriority = effectPriority(rhs.element, selected: selected)
            return lhsPriority == rhsPriority
                ? lhs.offset < rhs.offset
                : lhsPriority < rhsPriority
        }.map(\.element)
        var retained: [GaryxRecentFeedEffect] = []
        for effect in orderedEffects {
            switch effect {
            case .publish:
                owner.emitHomeProjectionSnapshot()
            case .requestHead(let request):
                guard requestIsRunnable(request, selected: owner.recentThreadFeeds.selectedFilter) else {
                    retained.append(effect)
                    continue
                }
                if let ticket = owner.beginRecentHeadRequest(
                    request,
                    scopeToken: scopeToken,
                    authority: GaryxHomeFeedSyncAuthority()
                ) {
                    #if DEBUG
                    startedHeadRequestsForTesting.append(request)
                    #endif
                    syncState.lastRefreshStartedAt = now()
                    let taskId = UUID()
                    transportTasks[taskId] = Task { [weak self, weak owner] in
                        if let owner {
                            await owner.performRecentHeadRequest(
                                ticket,
                                authority: GaryxHomeFeedSyncAuthority()
                            )
                        }
                        self?.transportDidFinish(taskId)
                    }
                }
            }
        }
        pendingEffects = retained

        if selected != .favorites {
            drainPendingFavoritesSnapshot(owner: owner)
        }
    }

    private func effectPriority(
        _ effect: GaryxRecentFeedEffect,
        selected: GaryxRecentThreadFilter
    ) -> Int {
        guard case .requestHead(let request) = effect else { return 1 }
        return request.filter == selected ? 0 : 2
    }

    private func drainPendingFavoritesSnapshot(owner: GaryxMobileModel) {
        guard let ticket = pendingFavoritesSnapshotTicket else { return }
        guard owner.threadFavoritesState.activeSnapshotTicket == ticket,
              ticket.gatewayScope == owner.threadFavoritesState.gatewayScope else {
            pendingFavoritesSnapshotTicket = nil
            return
        }
        pendingFavoritesSnapshotTicket = nil
        syncState.lastRefreshStartedAt = now()
        let taskId = UUID()
        let transport = owner.startThreadFavoritesSnapshot(
            ticket,
            authority: GaryxHomeFeedSyncAuthority()
        )
        transportTasks[taskId] = Task { [weak self] in
            await transport.value
            self?.transportDidFinish(taskId)
        }
    }

    private func requestIsRunnable(
        _ request: GaryxRecentHeadRequest,
        selected: GaryxRecentThreadFilter
    ) -> Bool {
        if request.runsWhenUnselected || waiters.values.contains(where: {
            $0.filters.contains(request.filter)
        }) {
            return true
        }
        switch selected {
        case .all:
            return request.filter == .all
        case .nonTask:
            return request.filter == .all || request.filter == .nonTask
        case .favorites:
            return request.filter == .all
        }
    }

    private var selectedPhase: GaryxRecentHeadPhase {
        guard let owner else {
            return .ready
        }
        switch owner.recentThreadFeeds.selectedFilter {
        case .all:
            return owner.recentThreadFeeds.allFeed.headPhase
        case .nonTask:
            return owner.recentThreadFeeds.nonTaskFeed.headPhase
        case .favorites:
            return owner.threadFavoritesState.headPhase
        }
    }

    private var visibility: GaryxHomeFeedVisibility {
        if isSceneBackgrounded {
            return .background
        }
        return isHomeVisible ? .foregroundVisible : .foregroundHidden
    }

    private var selectedQueuedHeadRequest: GaryxHomeFeedQueuedHeadRequest {
        guard let owner else { return .none }
        switch owner.recentThreadFeeds.selectedFilter {
        case .all:
            return owner.recentThreadFeeds.allFeed.queuedHeadRequest
        case .nonTask:
            return owner.recentThreadFeeds.nonTaskFeed.queuedHeadRequest
        case .favorites:
            return .none
        }
    }

    private func scheduleTimer(at deadline: Date) {
        timerTask?.cancel()
        let delay = max(0, deadline.timeIntervalSince(now()))
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled {
                self?.wake()
            }
        }
    }

    private func transportDidFinish(_ taskId: UUID) {
        transportTasks[taskId] = nil
        wake()
    }

    private func mergeUserIntent(_ candidate: UserIntent) {
        guard let current = pendingUserIntent else {
            pendingUserIntent = candidate
            return
        }
        let source: GaryxThreadListRefreshSource
        switch (current.source, candidate.source) {
        case (.userPullToRefresh, _), (_, .userPullToRefresh):
            source = .userPullToRefresh
        case (.userAction, _), (_, .userAction):
            source = .userAction
        case (.backgroundLoop, .backgroundLoop):
            source = .backgroundLoop
        }
        pendingUserIntent = UserIntent(
            source: source,
            forceReplacement: current.forceReplacement || candidate.forceReplacement,
            refreshesSelectedFeedOnly: current.refreshesSelectedFeedOnly
                && candidate.refreshesSelectedFeedOnly
        )
    }

    private func settleWaitersIfConverged() {
        guard pendingUserIntent == nil else { return }
        let settledIds = waiters.compactMap { id, waiter -> UUID? in
            let settled = waiter.filters.allSatisfy { filter in
                let phase = phase(for: filter)
                return phase.activeAttempt == nil
                    && !phase.owesImmediateRequest
                    && !hasQueuedRequest(for: filter)
            }
            return settled
                ? id
                : nil
        }
        for id in settledIds {
            cancelWaiter(id)
        }
    }

    private func hasQueuedRequest(for filter: GaryxRecentThreadFilter) -> Bool {
        if filter == .favorites {
            return pendingFavoritesSnapshotTicket != nil
        }
        return pendingEffects.contains { effect in
            guard case .requestHead(let request) = effect else { return false }
            return request.filter == filter
        }
    }

    private func phase(for filter: GaryxRecentThreadFilter) -> GaryxRecentHeadPhase {
        guard let owner else { return .ready }
        switch filter {
        case .all:
            return owner.recentThreadFeeds.allFeed.headPhase
        case .nonTask:
            return owner.recentThreadFeeds.nonTaskFeed.headPhase
        case .favorites:
            return owner.threadFavoritesState.headPhase
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume()
    }

    private func settleAllWaiters() {
        let continuations = waiters.values.map(\.continuation)
        waiters = [:]
        continuations.forEach { $0.resume() }
    }

    private func wake() {
        wakeContinuation.yield(())
    }
}

extension GaryxMobileModel {
    func rebuildHomeFeedSyncCoordinator(
        for scopeToken: GaryxGatewayRequestToken
    ) {
        let inheritedEffects = homeFeedSyncCoordinator
            .takePendingEffectsForScopeReplacement()
        let inheritedFavoritesSnapshot = homeFeedSyncCoordinator
            .takePendingFavoritesSnapshotForScopeReplacement()
        homeFeedSyncCoordinator.deactivateScope()

        let replacement = GaryxHomeFeedSyncCoordinator(
            initialEffects: inheritedEffects,
            initialFavoritesSnapshotTicket: inheritedFavoritesSnapshot,
            immediateDemandTimeout: Self.homeFeedImmediateDemandTimeout,
            scopeToken: scopeToken
        )
        homeFeedSyncCoordinator = replacement
        replacement.attach(self)
        replacement.updateConnection(connectionState)
        replacement.updateHomeVisibility(isHomeVisible)
        replacement.updateSceneBackgrounded(homeFeedSceneIsBackgrounded)
    }

    func requestHomeFeedRefresh(
        source: GaryxThreadListRefreshSource,
        forceReplacement: Bool = false
    ) async {
        #if DEBUG
        guard !debugSnapshotActive else { return }
        #endif
        guard hasGatewaySettings else { return }
        await homeFeedSyncCoordinator.submitUserIntent(
            source: source,
            forceReplacement: forceReplacement || source == .userPullToRefresh
        )
    }

    fileprivate func makeHomeFeedRefreshEffects(
        source: GaryxThreadListRefreshSource,
        forceReplacement: Bool,
        refreshesSelectedFeedOnly: Bool,
        authority _: GaryxHomeFeedSyncAuthority
    ) -> [GaryxRecentFeedEffect] {
        servicePinnedOrderRetry(source: source)
        if !refreshesSelectedFeedOnly {
            refreshThreadFavoritesSnapshot()
        }

        switch recentThreadFeeds.selectedFilter {
        case .all:
            return recentThreadFeeds.requestHeadEffects(
                filter: .all,
                source: source,
                forceReplacement: forceReplacement,
                homeProjectionCommit: refreshesSelectedFeedOnly
                    ? .cachedPins
                    : .refreshedPins
            )
        case .nonTask:
            let selectedFeedEffects = recentThreadFeeds.requestHeadEffects(
                filter: .nonTask,
                source: source,
                forceReplacement: forceReplacement,
                homeProjectionCommit: refreshesSelectedFeedOnly
                    ? .cachedPins
                    : .refreshedPins
            )
            guard !refreshesSelectedFeedOnly else {
                return selectedFeedEffects
            }
            return selectedFeedEffects + recentThreadFeeds.requestHeadEffects(
                filter: .all,
                source: source,
                forceReplacement: forceReplacement,
                homeProjectionCommit: .none
            )
        case .favorites:
            runThreadFavoritesEffects(threadFavoritesProvider.requestRefresh())
            guard !refreshesSelectedFeedOnly else {
                return []
            }
            return recentThreadFeeds.requestHeadEffects(
                filter: .all,
                source: source,
                forceReplacement: forceReplacement,
                homeProjectionCommit: .refreshedPins
            )
        }
    }

    fileprivate func beginRecentHeadRequest(
        _ request: GaryxRecentHeadRequest,
        scopeToken: GaryxGatewayRequestToken,
        authority _: GaryxHomeFeedSyncAuthority
    ) -> GaryxRecentThreadRefreshTicket? {
        guard scopeToken == gatewayRequestToken else { return nil }
        return recentThreadFeeds.beginHeadRequest(
            request,
            gatewayScope: threadFavoritesState.gatewayScope,
            runtimeEpoch: threadFavoritesState.runtimeEpoch
        )
    }

    fileprivate func makeAllRecentReplacementEffects(
        authority _: GaryxHomeFeedSyncAuthority
    ) -> [GaryxRecentFeedEffect] {
        recentThreadFeeds.requestHeadEffects(
            filter: .all,
            source: .userAction,
            forceReplacement: true,
            homeProjectionCommit: recentThreadFeeds.selectedFilter != .nonTask
                ? .refreshedPins
                : .none,
            runsWhenUnselected: true
        ) + recentThreadFeeds.requestHeadEffects(
            filter: .nonTask,
            source: .userAction,
            forceReplacement: true,
            homeProjectionCommit: recentThreadFeeds.selectedFilter == .nonTask
                ? .refreshedPins
                : .none,
            runsWhenUnselected: true
        )
    }

    fileprivate func downgradeSelectedHomeFeedDemand(
        authority _: GaryxHomeFeedSyncAuthority
    ) -> [GaryxRecentFeedEffect] {
        switch recentThreadFeeds.selectedFilter {
        case .all, .nonTask:
            return recentThreadFeeds.downgradeImmediateDemandToUserAction(
                filter: recentThreadFeeds.selectedFilter
            )
        case .favorites:
            // Favorites uses the same phase machine; its explicit downgrade
            // is reducer-owned so the provider publishes one coherent snapshot.
            let changed = threadFavoritesProvider.downgradeImmediateDemandToUserAction()
            return changed ? [.publish] : []
        }
    }
}
