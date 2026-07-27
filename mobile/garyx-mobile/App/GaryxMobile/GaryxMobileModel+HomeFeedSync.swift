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
    private let wakeStream: AsyncStream<Void>
    private let wakeContinuation: AsyncStream<Void>.Continuation

    init(
        initialEffects: [GaryxRecentFeedEffect],
        initialFavoritesSnapshotTicket: GaryxFavoritesSnapshotTicket? = nil,
        immediateDemandTimeout: TimeInterval,
        scopeToken: GaryxGatewayRequestToken? = nil
    ) {
        pendingEffects = initialEffects
        pendingFavoritesSnapshotTicket = initialFavoritesSnapshotTicket
        self.immediateDemandTimeout = immediateDemandTimeout
        self.scopeToken = scopeToken
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
        if loopTask == nil {
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
                forceReplacement: forceReplacement
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
                    syncState.immediateOwedSince = Date()
                }
            } else {
                syncState.immediateOwedSince = nil
            }

            if selectedHeadRequestIsInternallyQueued {
                if phase.owesImmediateRequest {
                    let deadline = (syncState.immediateOwedSince ?? Date())
                        .addingTimeInterval(immediateDemandTimeout)
                    if deadline <= Date() {
                        downgradeSelectedImmediateDemand()
                        continue
                    }
                    scheduleTimer(at: deadline)
                }
                break evaluation
            }

            let action = GaryxHomeFeedSyncPlanner.next(
                state: syncState,
                demand: GaryxHomeFeedDemand(
                    phase: phase,
                    hasPendingUserIntent: pendingUserIntent != nil
                ),
                visibility: visibility,
                connection: connection,
                now: Date(),
                immediateDemandTimeout: immediateDemandTimeout
            )
            switch action {
            case .none:
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

        var retained: [GaryxRecentFeedEffect] = []
        for effect in pendingEffects {
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
                    syncState.lastRefreshStartedAt = Date()
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

        if let ticket = pendingFavoritesSnapshotTicket {
            guard owner.threadFavoritesState.activeSnapshotTicket == ticket,
                  ticket.gatewayScope == owner.threadFavoritesState.gatewayScope else {
                pendingFavoritesSnapshotTicket = nil
                return
            }
            pendingFavoritesSnapshotTicket = nil
            syncState.lastRefreshStartedAt = Date()
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

    private var selectedHeadRequestIsInternallyQueued: Bool {
        guard let owner else { return false }
        switch owner.recentThreadFeeds.selectedFilter {
        case .all:
            return owner.recentThreadFeeds.allFeed.pendingHeadRequest != nil
        case .nonTask:
            return owner.recentThreadFeeds.nonTaskFeed.pendingHeadRequest != nil
        case .favorites:
            return false
        }
    }

    private func scheduleTimer(at deadline: Date) {
        timerTask?.cancel()
        let delay = max(0, deadline.timeIntervalSinceNow)
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
            forceReplacement: current.forceReplacement || candidate.forceReplacement
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
        authority _: GaryxHomeFeedSyncAuthority
    ) -> [GaryxRecentFeedEffect] {
        servicePinnedOrderRetry(source: source)
        let refreshesSelectedFeedOnly = source == .userPullToRefresh
        if !refreshesSelectedFeedOnly {
            refreshThreadFavoritesSnapshot()
        }

        switch recentThreadFeeds.selectedFilter {
        case .all:
            return recentThreadFeeds.requestHeadEffects(
                filter: .all,
                source: source,
                forceReplacement: forceReplacement,
                updatesHomeChrome: !refreshesSelectedFeedOnly
            )
        case .nonTask:
            let selectedFeedEffects = recentThreadFeeds.requestHeadEffects(
                filter: .nonTask,
                source: source,
                forceReplacement: forceReplacement,
                updatesHomeChrome: !refreshesSelectedFeedOnly
            )
            guard !refreshesSelectedFeedOnly else {
                return selectedFeedEffects
            }
            return selectedFeedEffects + recentThreadFeeds.requestHeadEffects(
                filter: .all,
                source: source,
                forceReplacement: forceReplacement,
                updatesHomeChrome: false
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
                updatesHomeChrome: true
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
            updatesHomeChrome: recentThreadFeeds.selectedFilter != .nonTask,
            runsWhenUnselected: true
        ) + recentThreadFeeds.requestHeadEffects(
            filter: .nonTask,
            source: .userAction,
            forceReplacement: true,
            updatesHomeChrome: recentThreadFeeds.selectedFilter == .nonTask,
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
