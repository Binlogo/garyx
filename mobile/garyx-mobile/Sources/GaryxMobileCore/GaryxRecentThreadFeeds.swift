import Foundation

public enum GaryxRecentThreadFilter: String, CaseIterable, Equatable, Hashable, Sendable {
    case all
    case nonTask
    case favorites

    public static let homeMenuOptions: [Self] = [.all, .nonTask, .favorites]

    /// Favorites is snapshot-owned and must never be encoded as a Recent query.
    public var tasksQueryValue: String? {
        switch self {
        case .all: return "include"
        case .nonTask: return "exclude"
        case .favorites: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .all: return "All"
        case .nonTask: return "Chats"
        case .favorites: return "Favorites"
        }
    }

    public var activeStatusLabel: String? {
        switch self {
        case .all: return nil
        case .nonTask: return "Chats"
        case .favorites: return "Favorites"
        }
    }
}

public enum GaryxRecentThreadRefreshMode: Equatable, Sendable {
    case rangeFill
    case replacement
}

public struct GaryxRecentHeadRequest: Equatable, Sendable {
    public var filter: GaryxRecentThreadFilter
    public var source: GaryxThreadListRefreshSource
    public var forceReplacement: Bool
    public var updatesHomeChrome: Bool
    public var runsWhenUnselected: Bool

    public init(
        filter: GaryxRecentThreadFilter,
        source: GaryxThreadListRefreshSource,
        forceReplacement: Bool = false,
        updatesHomeChrome: Bool = true,
        runsWhenUnselected: Bool = false
    ) {
        precondition(filter != .favorites, "Favorites owns its snapshot transport")
        self.filter = filter
        self.source = source
        self.forceReplacement = forceReplacement
        self.updatesHomeChrome = updatesHomeChrome
        self.runsWhenUnselected = runsWhenUnselected
    }

    public func merging(_ candidate: Self) -> Self {
        precondition(filter == candidate.filter, "head requests only merge within one feed")
        let mergedSource: GaryxThreadListRefreshSource
        switch (source, candidate.source) {
        case (.userPullToRefresh, _), (_, .userPullToRefresh):
            mergedSource = .userPullToRefresh
        case (.userAction, _), (_, .userAction):
            mergedSource = .userAction
        case (.backgroundLoop, .backgroundLoop):
            mergedSource = .backgroundLoop
        }
        return Self(
            filter: filter,
            source: mergedSource,
            forceReplacement: forceReplacement || candidate.forceReplacement,
            updatesHomeChrome: updatesHomeChrome || candidate.updatesHomeChrome,
            runsWhenUnselected: runsWhenUnselected || candidate.runsWhenUnselected
        )
    }
}

public enum GaryxRecentFeedEffect: Equatable, Sendable {
    case requestHead(GaryxRecentHeadRequest)
    case publish
}

public struct GaryxRecentThreadRefreshTicket: Equatable, Sendable {
    public let filter: GaryxRecentThreadFilter
    public let pagerTicket: GaryxThreadListRefreshTicket
    public let attempt: GaryxRecentHeadAttempt
    public let gatewayScope: String
    public let runtimeEpoch: UInt64
    public let source: GaryxThreadListRefreshSource
    public let updatesHomeChrome: Bool
    public let runsWhenUnselected: Bool
    public let mode: GaryxRecentThreadRefreshMode
    public let oldHeadActivitySeq: Int64?
    public let forceReplacementGeneration: UInt64
}

public struct GaryxRecentThreadLoadMoreTicket: Equatable, Sendable {
    public let filter: GaryxRecentThreadFilter
    public let pagerTicket: GaryxThreadListLoadMoreTicket
    public let gatewayScope: String
    public let runtimeEpoch: UInt64
    public let cursor: String

    public var limit: Int { pagerTicket.limit }
}

public struct GaryxRecentThreadFeedRow: Equatable, Sendable {
    public var id: String
    public var activitySeq: Int64

    public init(id: String, activitySeq: Int64) {
        self.id = id
        self.activitySeq = activitySeq
    }
}

public struct GaryxRecentThreadFeedPage: Equatable, Sendable {
    public var storeIncarnationId: String
    public var serverBootId: String
    public var rows: [GaryxRecentThreadFeedRow]
    public var hasMore: Bool
    public var nextCursor: String?

    public init(
        storeIncarnationId: String,
        serverBootId: String,
        rows: [GaryxRecentThreadFeedRow],
        hasMore: Bool,
        nextCursor: String?
    ) {
        self.storeIncarnationId = storeIncarnationId
        self.serverBootId = serverBootId
        self.rows = rows
        self.hasMore = hasMore
        self.nextCursor = nextCursor
    }

    public init(_ page: GaryxRecentThreadsPage) {
        self.init(
            storeIncarnationId: page.storeIncarnationId,
            serverBootId: page.serverBootId,
            rows: page.threads.compactMap { thread in
                guard let activitySeq = thread.activitySeq else { return nil }
                return GaryxRecentThreadFeedRow(id: thread.id, activitySeq: activitySeq)
            },
            hasMore: page.hasMore,
            nextCursor: page.nextCursor
        )
    }

    public var headActivitySeq: Int64? { rows.first?.activitySeq }
}

public struct GaryxRecentThreadRefreshBundle: Equatable, Sendable {
    public var primaryPages: [GaryxRecentThreadFeedPage]
    public var verificationPage: GaryxRecentThreadFeedPage
    public var immediatePages: [GaryxRecentThreadFeedPage]?
    public var immediateVerificationPage: GaryxRecentThreadFeedPage?

    public init(
        primaryPages: [GaryxRecentThreadFeedPage],
        verificationPage: GaryxRecentThreadFeedPage,
        immediatePages: [GaryxRecentThreadFeedPage]? = nil,
        immediateVerificationPage: GaryxRecentThreadFeedPage? = nil
    ) {
        self.primaryPages = primaryPages
        self.verificationPage = verificationPage
        self.immediatePages = immediatePages
        self.immediateVerificationPage = immediateVerificationPage
    }
}

public enum GaryxRecentThreadFeedCompletion: Equatable, Sendable {
    case applied
    case abandonedStaleEpoch
    case abandonedLocalMutation
    case forceReplacement
    case failed
    case interrupted(GaryxRecentHeadStall)
}

public enum GaryxRecentHeadResult: Equatable, Sendable {
    case page(GaryxRecentThreadRefreshBundle)
    case failed
    case interrupted(GaryxRecentHeadStall)
}

public struct GaryxRecentHeadCompletion: Equatable, Sendable {
    public var outcome: GaryxRecentThreadFeedCompletion
    public var effects: [GaryxRecentFeedEffect]

    public init(
        outcome: GaryxRecentThreadFeedCompletion,
        effects: [GaryxRecentFeedEffect]
    ) {
        self.outcome = outcome
        self.effects = effects
    }
}

public struct GaryxRecentLoadMoreCompletion: Equatable, Sendable {
    public var outcome: GaryxRecentThreadFeedCompletion
    public var effects: [GaryxRecentFeedEffect]

    public init(
        outcome: GaryxRecentThreadFeedCompletion,
        effects: [GaryxRecentFeedEffect]
    ) {
        self.outcome = outcome
        self.effects = effects
    }
}

public struct GaryxRecentThreadFeedBootstrap: Equatable, Sendable {
    public var state: GaryxRecentThreadFeedState
    public var effects: [GaryxRecentFeedEffect]
}

public enum GaryxRecentThreadRangeFill {
    public static let maxChainPages = 5
    public static let replacementCycleInterval = 30

    public static func needsNextPage(
        mode: GaryxRecentThreadRefreshMode,
        oldHeadActivitySeq: Int64?,
        pages: [GaryxRecentThreadFeedPage]
    ) -> Bool {
        guard let last = pages.last,
              last.hasMore,
              pages.count < maxChainPages else { return false }
        guard mode == .rangeFill, let oldHeadActivitySeq else { return true }
        guard let tail = last.rows.last?.activitySeq else { return false }
        return tail > oldHeadActivitySeq
    }

    public static func verificationObservedNewerHead(
        chainFirstHead: Int64?,
        verificationPage: GaryxRecentThreadFeedPage
    ) -> Bool {
        guard let verificationHead = verificationPage.headActivitySeq else { return false }
        return chainFirstHead.map { verificationHead > $0 } ?? true
    }
}

public struct GaryxRecentThreadFeedState: Equatable, Sendable, GaryxRecentHeadDomain {
    public private(set) var orderedThreadIds: [String]
    private var headState: GaryxRecentHeadState
    public private(set) var pager: GaryxHomeThreadListPager
    public private(set) var nextCursor: String?
    public private(set) var storeIncarnationId: String?
    public private(set) var serverBootId: String?
    public private(set) var headActivitySeq: Int64?
    public private(set) var refreshCycle: Int
    public private(set) var forceReplacementPending: Bool
    public private(set) var forceReplacementGeneration: UInt64
    public private(set) var trailingDirty: Bool
    public private(set) var pendingHeadRequest: GaryxRecentHeadRequest?

    private init(pageLimit: Int, overlap: Int) {
        orderedThreadIds = []
        headState = GaryxRecentHeadState()
        pager = GaryxHomeThreadListPager(pageLimit: pageLimit, overlap: overlap)
        nextCursor = nil
        storeIncarnationId = nil
        serverBootId = nil
        headActivitySeq = nil
        refreshCycle = 0
        forceReplacementPending = false
        forceReplacementGeneration = 0
        trailingDirty = false
        pendingHeadRequest = nil
    }

    public static func bootstrap(
        filter: GaryxRecentThreadFilter,
        pageLimit: Int,
        overlap: Int
    ) -> GaryxRecentThreadFeedBootstrap {
        precondition(filter != .favorites, "Favorites owns its own reducer")
        return GaryxRecentThreadFeedBootstrap(
            state: GaryxRecentThreadFeedState(
                pageLimit: pageLimit,
                overlap: overlap
            ),
            effects: [
                .requestHead(
                    GaryxRecentHeadRequest(
                        filter: filter,
                        source: .userAction,
                        forceReplacement: true,
                        updatesHomeChrome: filter == .all
                    )
                ),
            ]
        )
    }

    public var headPhase: GaryxRecentHeadPhase { headState.phase }
    public var rows: [String] { orderedThreadIds }
    public var footerState: GaryxHomeLoadMoreFooterState { pager.footerState }
    public var isPrimed: Bool { headPhase.isPrimed }
    public var headFailure: Bool { headPhase.awaitsUserAction }

    public var presentation: GaryxRecentThreadFeedPresentation {
        GaryxRecentThreadFeedPresentation(self)
    }

    fileprivate mutating func enqueueHeadRequest(
        _ request: GaryxRecentHeadRequest
    ) -> [GaryxRecentFeedEffect] {
        guard headPhase.activeAttempt == nil, !pager.isLoadingMore else {
            pendingHeadRequest = Self.mergedPendingHeadRequest(
                pendingHeadRequest,
                request
            )
            return []
        }
        return [.requestHead(request)]
    }

    fileprivate mutating func beginHeadRequest(
        _ request: GaryxRecentHeadRequest,
        gatewayScope: String,
        runtimeEpoch: UInt64
    ) -> GaryxRecentThreadRefreshTicket? {
        guard !pager.isLoadingMore,
              headPhase.activeAttempt == nil,
              let pagerTicket = pager.requestRefresh(),
              let attempt = headState.beginAttempt() else {
            pendingHeadRequest = Self.mergedPendingHeadRequest(
                pendingHeadRequest,
                request
            )
            return nil
        }
        let periodicReplacement = (refreshCycle + 1)
            % GaryxRecentThreadRangeFill.replacementCycleInterval == 0
        let mode: GaryxRecentThreadRefreshMode = request.forceReplacement
            || forceReplacementPending
            || !isPrimed
            || periodicReplacement
            ? .replacement
            : .rangeFill
        return GaryxRecentThreadRefreshTicket(
            filter: .all, // Feed owner replaces this value.
            pagerTicket: pagerTicket,
            attempt: attempt,
            gatewayScope: gatewayScope,
            runtimeEpoch: runtimeEpoch,
            source: request.source,
            updatesHomeChrome: request.updatesHomeChrome,
            runsWhenUnselected: request.runsWhenUnselected,
            mode: mode,
            oldHeadActivitySeq: headActivitySeq,
            forceReplacementGeneration: forceReplacementGeneration
        )
    }

    fileprivate mutating func completeHead(
        _ ticket: GaryxRecentThreadRefreshTicket,
        result: GaryxRecentHeadResult
    ) -> GaryxRecentHeadCompletion {
        switch result {
        case .page(let bundle):
            return completeHeadPage(ticket, bundle: bundle)
        case .failed:
            pager.failRefresh(ticket.pagerTicket)
            guard headState.settle(
                ticket.attempt,
                stalledBy: .networkFailure,
                demand: pendingHeadRequest == nil ? .userAction : .immediate
            ) else {
                return GaryxRecentHeadCompletion(
                    outcome: .abandonedStaleEpoch,
                    effects: [.publish]
                )
            }
            return GaryxRecentHeadCompletion(
                outcome: .failed,
                effects: [.publish] + drainPendingHeadEffects()
            )
        case .interrupted(let stall):
            pager.interruptRefresh(ticket.pagerTicket)
            return settleHead(
                ticket,
                outcome: .interrupted(stall),
                stalledBy: stall
            )
        }
    }

    private mutating func completeHeadPage(
        _ ticket: GaryxRecentThreadRefreshTicket,
        bundle: GaryxRecentThreadRefreshBundle
    ) -> GaryxRecentHeadCompletion {
        guard !bundle.primaryPages.isEmpty else {
            pager.failRefresh(ticket.pagerTicket)
            return settleHead(
                ticket,
                outcome: .abandonedStaleEpoch,
                stalledBy: .supersededByReset
            )
        }
        let allPages = bundle.primaryPages
            + [bundle.verificationPage]
            + (bundle.immediatePages ?? [])
            + [bundle.immediateVerificationPage].compactMap { $0 }
        guard let identity = Self.consistentIdentity(allPages) else {
            pager.failRefresh(ticket.pagerTicket)
            markForceReplacement()
            return settleHead(
                ticket,
                outcome: .forceReplacement,
                stalledBy: .identityReplacement,
                forceReplacement: true
            )
        }
        if let storeIncarnationId,
           storeIncarnationId != identity.storeIncarnationId,
           ticket.mode != .replacement {
            pager.failRefresh(ticket.pagerTicket)
            markForceReplacement()
            return settleHead(
                ticket,
                outcome: .forceReplacement,
                stalledBy: .identityReplacement,
                forceReplacement: true
            )
        }
        if let serverBootId,
           serverBootId != identity.serverBootId,
           ticket.mode != .replacement {
            pager.failRefresh(ticket.pagerTicket)
            markForceReplacement()
            return settleHead(
                ticket,
                outcome: .forceReplacement,
                stalledBy: .identityReplacement,
                forceReplacement: true
            )
        }

        var primary = applyChain(
            ticket: ticket,
            pages: bundle.primaryPages,
            existingIds: orderedThreadIds,
            existingCursor: nextCursor
        )
        let primaryHead = bundle.primaryPages.first?.headActivitySeq
        let needsImmediate = GaryxRecentThreadRangeFill.verificationObservedNewerHead(
            chainFirstHead: primaryHead,
            verificationPage: bundle.verificationPage
        )
        var continuedMotion = false
        if needsImmediate, let immediatePages = bundle.immediatePages,
           !immediatePages.isEmpty {
            let immediateTicket = GaryxRecentThreadRefreshTicket(
                filter: ticket.filter,
                pagerTicket: ticket.pagerTicket,
                attempt: ticket.attempt,
                gatewayScope: ticket.gatewayScope,
                runtimeEpoch: ticket.runtimeEpoch,
                source: ticket.source,
                updatesHomeChrome: ticket.updatesHomeChrome,
                runsWhenUnselected: ticket.runsWhenUnselected,
                mode: .rangeFill,
                oldHeadActivitySeq: primaryHead,
                forceReplacementGeneration: ticket.forceReplacementGeneration
            )
            let immediate = applyChain(
                ticket: immediateTicket,
                pages: immediatePages,
                existingIds: primary.ids,
                existingCursor: primary.cursor
            )
            primary = (
                ids: immediate.ids,
                cursor: immediate.cursor,
                hasMore: immediate.hasMore,
                replacement: primary.replacement || immediate.replacement
            )
            if let verification = bundle.immediateVerificationPage {
                continuedMotion = GaryxRecentThreadRangeFill.verificationObservedNewerHead(
                    chainFirstHead: immediatePages.first?.headActivitySeq,
                    verificationPage: verification
                )
            } else {
                continuedMotion = true
            }
        } else if needsImmediate {
            continuedMotion = true
        }

        switch pager.completeRangeRefresh(
            ticket.pagerTicket,
            committedCount: primary.ids.count,
            hasMore: primary.hasMore,
            replacementCommitted: primary.replacement
        ) {
        case .abandonedStaleEpoch:
            return settleHead(
                ticket,
                outcome: .abandonedStaleEpoch,
                stalledBy: .supersededByReset
            )
        case .abandonedLocalMutation:
            return settleHead(
                ticket,
                outcome: .abandonedLocalMutation,
                stalledBy: .racedLocalMutation
            )
        case .apply:
            let replacementRequestedAfterDispatch = forceReplacementPending
                && forceReplacementGeneration != ticket.forceReplacementGeneration
            orderedThreadIds = primary.ids
            nextCursor = primary.cursor
            storeIncarnationId = identity.storeIncarnationId
            serverBootId = identity.serverBootId
            headActivitySeq = (bundle.immediatePages?.first ?? bundle.primaryPages.first)?
                .headActivitySeq
            refreshCycle += 1
            forceReplacementPending = replacementRequestedAfterDispatch
            trailingDirty = continuedMotion
            if replacementRequestedAfterDispatch {
                return settleHead(
                    ticket,
                    outcome: .forceReplacement,
                    stalledBy: .racedLocalMutation,
                    forceReplacement: true
                )
            }
            _ = headState.settleSuccess(ticket.attempt)
            return GaryxRecentHeadCompletion(
                outcome: .applied,
                effects: [.publish] + drainPendingHeadEffects()
            )
        }
    }

    fileprivate mutating func requestLoadMore(
        trigger: GaryxThreadListLoadMoreTrigger,
        gatewayScope: String,
        runtimeEpoch: UInt64
    ) -> GaryxRecentThreadLoadMoreTicket? {
        guard headPhase.activeAttempt == nil,
              !forceReplacementPending,
              let cursor = nextCursor,
              let ticket = pager.requestLoadMore(trigger: trigger) else { return nil }
        return GaryxRecentThreadLoadMoreTicket(
            filter: .all,
            pagerTicket: ticket,
            gatewayScope: gatewayScope,
            runtimeEpoch: runtimeEpoch,
            cursor: cursor
        )
    }

    fileprivate mutating func retryLoadMore(
        gatewayScope: String,
        runtimeEpoch: UInt64
    ) -> GaryxRecentThreadLoadMoreTicket? {
        guard headPhase.activeAttempt == nil,
              !forceReplacementPending,
              let cursor = nextCursor,
              let ticket = pager.retryLoadMore() else { return nil }
        return GaryxRecentThreadLoadMoreTicket(
            filter: .all,
            pagerTicket: ticket,
            gatewayScope: gatewayScope,
            runtimeEpoch: runtimeEpoch,
            cursor: cursor
        )
    }

    fileprivate mutating func completeLoadMore(
        _ ticket: GaryxRecentThreadLoadMoreTicket,
        page: GaryxRecentThreadFeedPage
    ) -> GaryxRecentLoadMoreCompletion {
        if let storeIncarnationId, storeIncarnationId != page.storeIncarnationId {
            pager.failLoadMore(ticket.pagerTicket)
            markForceReplacement()
            return GaryxRecentLoadMoreCompletion(
                outcome: .forceReplacement,
                effects: [.publish] + recoveryHeadEffects(
                    filter: ticket.filter,
                    source: .userAction,
                    forceReplacement: true
                )
            )
        }
        if let serverBootId, serverBootId != page.serverBootId {
            pager.failLoadMore(ticket.pagerTicket)
            markForceReplacement()
            return GaryxRecentLoadMoreCompletion(
                outcome: .forceReplacement,
                effects: [.publish] + recoveryHeadEffects(
                    filter: ticket.filter,
                    source: .userAction,
                    forceReplacement: true
                )
            )
        }
        switch pager.completeLoadMore(
            ticket.pagerTicket,
            pageOffset: pager.nextOffset,
            pageCount: page.rows.count,
            hasMore: page.hasMore
        ) {
        case .abandonedStaleEpoch:
            return GaryxRecentLoadMoreCompletion(
                outcome: .abandonedStaleEpoch,
                effects: [.publish] + drainPendingHeadEffects()
            )
        case .abandonedLocalMutation:
            return GaryxRecentLoadMoreCompletion(
                outcome: .abandonedLocalMutation,
                effects: [.publish] + drainPendingHeadEffects()
            )
        case .apply:
            orderedThreadIds = GaryxThreadListPageMerge.appendPage(
                pageIds: Self.normalizedIds(page.rows.map(\.id)),
                existingIds: orderedThreadIds
            )
            nextCursor = page.nextCursor
            storeIncarnationId = page.storeIncarnationId
            serverBootId = page.serverBootId
            return GaryxRecentLoadMoreCompletion(
                outcome: .applied,
                effects: [.publish] + drainPendingHeadEffects()
            )
        }
    }

    fileprivate mutating func failLoadMore(
        _ ticket: GaryxRecentThreadLoadMoreTicket
    ) -> [GaryxRecentFeedEffect] {
        pager.failLoadMore(ticket.pagerTicket)
        return [.publish] + drainPendingHeadEffects()
    }

    fileprivate mutating func interruptLoadMore(
        _ ticket: GaryxRecentThreadLoadMoreTicket
    ) -> [GaryxRecentFeedEffect] {
        pager.interruptLoadMore(ticket.pagerTicket)
        return [.publish] + drainPendingHeadEffects()
    }

    fileprivate mutating func noteLocalMutation() { pager.noteLocalMutation() }

    fileprivate mutating func remove(_ threadId: String) {
        orderedThreadIds.removeAll { $0 == threadId }
        noteLocalMutation()
    }

    fileprivate mutating func upsertAtHead(_ threadId: String) {
        orderedThreadIds.removeAll { $0 == threadId }
        orderedThreadIds.insert(threadId, at: 0)
        headActivitySeq = nil
        noteLocalMutation()
    }

    fileprivate mutating func markForceReplacement() {
        forceReplacementGeneration &+= 1
        forceReplacementPending = true
        trailingDirty = false
    }

    fileprivate mutating func reset(
        filter: GaryxRecentThreadFilter
    ) -> [GaryxRecentFeedEffect] {
        pager.reset()
        orderedThreadIds = []
        headState.reset()
        nextCursor = nil
        storeIncarnationId = nil
        serverBootId = nil
        headActivitySeq = nil
        refreshCycle = 0
        forceReplacementPending = false
        forceReplacementGeneration = 0
        trailingDirty = false
        pendingHeadRequest = nil
        return [
            .publish,
            .requestHead(
                GaryxRecentHeadRequest(
                    filter: filter,
                    source: .userAction,
                    forceReplacement: true,
                    updatesHomeChrome: filter == .all
                )
            ),
        ]
    }

    @discardableResult
    fileprivate mutating func downgradeImmediateDemandToUserAction() -> Bool {
        let changed = headState.downgradeImmediateDemandToUserAction()
        if changed {
            pendingHeadRequest = nil
        }
        return changed
    }

    private mutating func settleHead(
        _ ticket: GaryxRecentThreadRefreshTicket,
        outcome: GaryxRecentThreadFeedCompletion,
        stalledBy stall: GaryxRecentHeadStall,
        forceReplacement: Bool = false
    ) -> GaryxRecentHeadCompletion {
        guard headState.settle(
            ticket.attempt,
            stalledBy: stall,
            demand: .immediate
        ) else {
            return GaryxRecentHeadCompletion(
                outcome: .abandonedStaleEpoch,
                effects: [.publish]
            )
        }
        pendingHeadRequest = Self.mergedPendingHeadRequest(
            pendingHeadRequest,
            GaryxRecentHeadRequest(
                filter: ticket.filter,
                source: ticket.source,
                forceReplacement: forceReplacement,
                updatesHomeChrome: ticket.updatesHomeChrome,
                runsWhenUnselected: ticket.runsWhenUnselected
            )
        )
        return GaryxRecentHeadCompletion(
            outcome: outcome,
            effects: [.publish] + drainPendingHeadEffects()
        )
    }

    private mutating func recoveryHeadEffects(
        filter: GaryxRecentThreadFilter,
        source: GaryxThreadListRefreshSource,
        forceReplacement: Bool
    ) -> [GaryxRecentFeedEffect] {
        let request = GaryxRecentHeadRequest(
            filter: filter,
            source: source,
            forceReplacement: forceReplacement,
            updatesHomeChrome: true
        )
        pendingHeadRequest = Self.mergedPendingHeadRequest(
            pendingHeadRequest,
            request
        )
        headState.oweImmediate(stalledBy: .identityReplacement)
        return drainPendingHeadEffects()
    }

    private mutating func drainPendingHeadEffects() -> [GaryxRecentFeedEffect] {
        guard headPhase.activeAttempt == nil,
              !pager.isLoadingMore,
              let request = pendingHeadRequest else {
            return []
        }
        pendingHeadRequest = nil
        headState.oweImmediate(stalledBy: .interrupted)
        return [.requestHead(request)]
    }

    private static func mergedPendingHeadRequest(
        _ current: GaryxRecentHeadRequest?,
        _ candidate: GaryxRecentHeadRequest
    ) -> GaryxRecentHeadRequest {
        current?.merging(candidate) ?? candidate
    }

    private func applyChain(
        ticket: GaryxRecentThreadRefreshTicket,
        pages: [GaryxRecentThreadFeedPage],
        existingIds: [String],
        existingCursor: String?
    ) -> (ids: [String], cursor: String?, hasMore: Bool, replacement: Bool) {
        let pageIds = Self.normalizedIds(pages.flatMap { $0.rows.map(\.id) })
        let last = pages.last
        let reachedAnchor = ticket.oldHeadActivitySeq.map { anchor in
            last?.rows.last.map { $0.activitySeq <= anchor } ?? false
        } ?? false
        let exhaustedBeforeAnchor = last?.hasMore == false && !reachedAnchor
        let exceededWindow = pages.count >= GaryxRecentThreadRangeFill.maxChainPages
            && !reachedAnchor
        let replacement = ticket.mode == .replacement
            || ticket.oldHeadActivitySeq == nil
            || exhaustedBeforeAnchor
            || exceededWindow
        if replacement {
            return (pageIds, last?.nextCursor, last?.hasMore ?? false, true)
        }
        return (
            GaryxThreadListPageMerge.mergeHead(
                pageIds: pageIds,
                existingIds: existingIds
            ),
            existingCursor,
            existingCursor != nil,
            false
        )
    }

    private static func consistentIdentity(
        _ pages: [GaryxRecentThreadFeedPage]
    ) -> (storeIncarnationId: String, serverBootId: String)? {
        guard let first = pages.first,
              pages.allSatisfy({
                  $0.storeIncarnationId == first.storeIncarnationId
                      && $0.serverBootId == first.serverBootId
              }) else { return nil }
        return (first.storeIncarnationId, first.serverBootId)
    }

    private static func normalizedIds(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.compactMap { rawId in
            let id = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return id
        }
    }
}

public struct GaryxRecentThreadFeedsBootstrap: Equatable, Sendable {
    public var feeds: GaryxRecentThreadFeeds
    public var effects: [GaryxRecentFeedEffect]
}

public struct GaryxRecentThreadFeeds: Equatable, Sendable {
    public private(set) var selectedFilter: GaryxRecentThreadFilter
    public private(set) var allFeed: GaryxRecentThreadFeedState
    public private(set) var nonTaskFeed: GaryxRecentThreadFeedState

    private init(
        selectedFilter: GaryxRecentThreadFilter,
        allFeed: GaryxRecentThreadFeedState,
        nonTaskFeed: GaryxRecentThreadFeedState
    ) {
        self.selectedFilter = selectedFilter
        self.allFeed = allFeed
        self.nonTaskFeed = nonTaskFeed
    }

    public static func bootstrap(
        pageLimit: Int,
        overlap: Int,
        selectedFilter: GaryxRecentThreadFilter = .all
    ) -> GaryxRecentThreadFeedsBootstrap {
        let all = GaryxRecentThreadFeedState.bootstrap(
            filter: .all,
            pageLimit: pageLimit,
            overlap: overlap
        )
        let nonTask = GaryxRecentThreadFeedState.bootstrap(
            filter: .nonTask,
            pageLimit: pageLimit,
            overlap: overlap
        )
        return GaryxRecentThreadFeedsBootstrap(
            feeds: GaryxRecentThreadFeeds(
                selectedFilter: selectedFilter,
                allFeed: all.state,
                nonTaskFeed: nonTask.state
            ),
            effects: all.effects + nonTask.effects
        )
    }

    public var allRecentThreadIds: [String] { allFeed.orderedThreadIds }
    public var visibleRecentThreadIds: [String] {
        feed(for: selectedFilter)?.orderedThreadIds ?? []
    }
    public var selectedPresentation: GaryxRecentThreadFeedPresentation? {
        feed(for: selectedFilter)?.presentation
    }
    public var selectedPager: GaryxHomeThreadListPager? { feed(for: selectedFilter)?.pager }

    public func feed(for filter: GaryxRecentThreadFilter) -> GaryxRecentThreadFeedState? {
        switch filter {
        case .all: return allFeed
        case .nonTask: return nonTaskFeed
        case .favorites: return nil
        }
    }

    public mutating func select(_ filter: GaryxRecentThreadFilter) { selectedFilter = filter }

    public mutating func requestHeadEffects(
        filter: GaryxRecentThreadFilter? = nil,
        source: GaryxThreadListRefreshSource,
        forceReplacement: Bool = false,
        updatesHomeChrome: Bool = true,
        runsWhenUnselected: Bool = false
    ) -> [GaryxRecentFeedEffect] {
        let filter = filter ?? selectedFilter
        guard filter != .favorites else { return [] }
        let request = GaryxRecentHeadRequest(
            filter: filter,
            source: source,
            forceReplacement: forceReplacement,
            updatesHomeChrome: updatesHomeChrome,
            runsWhenUnselected: runsWhenUnselected
        )
        switch filter {
        case .all:
            return allFeed.enqueueHeadRequest(request)
        case .nonTask:
            return nonTaskFeed.enqueueHeadRequest(request)
        case .favorites:
            preconditionFailure("guarded above")
        }
    }

    public mutating func beginHeadRequest(
        _ request: GaryxRecentHeadRequest,
        gatewayScope: String,
        runtimeEpoch: UInt64
    ) -> GaryxRecentThreadRefreshTicket? {
        let ticket: GaryxRecentThreadRefreshTicket?
        switch request.filter {
        case .all:
            ticket = allFeed.beginHeadRequest(
                request,
                gatewayScope: gatewayScope,
                runtimeEpoch: runtimeEpoch
            )
        case .nonTask:
            ticket = nonTaskFeed.beginHeadRequest(
                request,
                gatewayScope: gatewayScope,
                runtimeEpoch: runtimeEpoch
            )
        case .favorites:
            ticket = nil
        }
        guard let ticket else { return nil }
        return GaryxRecentThreadRefreshTicket(
            filter: request.filter,
            pagerTicket: ticket.pagerTicket,
            attempt: ticket.attempt,
            gatewayScope: ticket.gatewayScope,
            runtimeEpoch: ticket.runtimeEpoch,
            source: ticket.source,
            updatesHomeChrome: ticket.updatesHomeChrome,
            runsWhenUnselected: ticket.runsWhenUnselected,
            mode: ticket.mode,
            oldHeadActivitySeq: ticket.oldHeadActivitySeq,
            forceReplacementGeneration: ticket.forceReplacementGeneration
        )
    }

    public mutating func completeHead(
        _ ticket: GaryxRecentThreadRefreshTicket,
        result: GaryxRecentHeadResult
    ) -> GaryxRecentHeadCompletion {
        switch ticket.filter {
        case .all:
            return allFeed.completeHead(ticket, result: result)
        case .nonTask:
            return nonTaskFeed.completeHead(ticket, result: result)
        case .favorites:
            return GaryxRecentHeadCompletion(
                outcome: .abandonedStaleEpoch,
                effects: [.publish]
            )
        }
    }

    public mutating func requestLoadMore(
        trigger: GaryxThreadListLoadMoreTrigger,
        gatewayScope: String = "",
        runtimeEpoch: UInt64 = 0
    ) -> GaryxRecentThreadLoadMoreTicket? {
        switch selectedFilter {
        case .all:
            guard let ticket = allFeed.requestLoadMore(
                trigger: trigger,
                gatewayScope: gatewayScope,
                runtimeEpoch: runtimeEpoch
            ) else { return nil }
            return GaryxRecentThreadLoadMoreTicket(
                filter: .all,
                pagerTicket: ticket.pagerTicket,
                gatewayScope: ticket.gatewayScope,
                runtimeEpoch: ticket.runtimeEpoch,
                cursor: ticket.cursor
            )
        case .nonTask:
            guard let ticket = nonTaskFeed.requestLoadMore(
                trigger: trigger,
                gatewayScope: gatewayScope,
                runtimeEpoch: runtimeEpoch
            ) else { return nil }
            return GaryxRecentThreadLoadMoreTicket(
                filter: .nonTask,
                pagerTicket: ticket.pagerTicket,
                gatewayScope: ticket.gatewayScope,
                runtimeEpoch: ticket.runtimeEpoch,
                cursor: ticket.cursor
            )
        case .favorites:
            return nil
        }
    }

    public mutating func retryLoadMore(
        gatewayScope: String = "",
        runtimeEpoch: UInt64 = 0
    ) -> GaryxRecentThreadLoadMoreTicket? {
        switch selectedFilter {
        case .all:
            guard let ticket = allFeed.retryLoadMore(
                gatewayScope: gatewayScope,
                runtimeEpoch: runtimeEpoch
            ) else { return nil }
            return GaryxRecentThreadLoadMoreTicket(
                filter: .all,
                pagerTicket: ticket.pagerTicket,
                gatewayScope: ticket.gatewayScope,
                runtimeEpoch: ticket.runtimeEpoch,
                cursor: ticket.cursor
            )
        case .nonTask:
            guard let ticket = nonTaskFeed.retryLoadMore(
                gatewayScope: gatewayScope,
                runtimeEpoch: runtimeEpoch
            ) else { return nil }
            return GaryxRecentThreadLoadMoreTicket(
                filter: .nonTask,
                pagerTicket: ticket.pagerTicket,
                gatewayScope: ticket.gatewayScope,
                runtimeEpoch: ticket.runtimeEpoch,
                cursor: ticket.cursor
            )
        case .favorites:
            return nil
        }
    }

    public mutating func completeLoadMore(
        _ ticket: GaryxRecentThreadLoadMoreTicket,
        page: GaryxRecentThreadFeedPage
    ) -> GaryxRecentLoadMoreCompletion {
        switch ticket.filter {
        case .all: return allFeed.completeLoadMore(ticket, page: page)
        case .nonTask: return nonTaskFeed.completeLoadMore(ticket, page: page)
        case .favorites:
            return GaryxRecentLoadMoreCompletion(
                outcome: .abandonedStaleEpoch,
                effects: [.publish]
            )
        }
    }

    public mutating func failLoadMore(
        _ ticket: GaryxRecentThreadLoadMoreTicket
    ) -> [GaryxRecentFeedEffect] {
        switch ticket.filter {
        case .all: return allFeed.failLoadMore(ticket)
        case .nonTask: return nonTaskFeed.failLoadMore(ticket)
        case .favorites: return [.publish]
        }
    }

    public mutating func interruptLoadMore(
        _ ticket: GaryxRecentThreadLoadMoreTicket
    ) -> [GaryxRecentFeedEffect] {
        switch ticket.filter {
        case .all: return allFeed.interruptLoadMore(ticket)
        case .nonTask: return nonTaskFeed.interruptLoadMore(ticket)
        case .favorites: return [.publish]
        }
    }

    public mutating func forceReplacement() {
        allFeed.markForceReplacement()
        nonTaskFeed.markForceReplacement()
    }

    public mutating func noteLocalMutation() {
        allFeed.noteLocalMutation()
        nonTaskFeed.noteLocalMutation()
    }

    public mutating func removeThread(_ rawThreadId: String) {
        let threadId = rawThreadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !threadId.isEmpty else { return }
        allFeed.remove(threadId)
        nonTaskFeed.remove(threadId)
    }

    public mutating func upsertChat(threadId rawThreadId: String) {
        let threadId = rawThreadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !threadId.isEmpty else { return }
        allFeed.upsertAtHead(threadId)
        nonTaskFeed.upsertAtHead(threadId)
    }

    public mutating func resetFeedData() -> [GaryxRecentFeedEffect] {
        allFeed.reset(filter: .all) + nonTaskFeed.reset(filter: .nonTask)
    }

    public mutating func downgradeImmediateDemandToUserAction(
        filter: GaryxRecentThreadFilter
    ) -> [GaryxRecentFeedEffect] {
        let changed: Bool
        switch filter {
        case .all:
            changed = allFeed.downgradeImmediateDemandToUserAction()
        case .nonTask:
            changed = nonTaskFeed.downgradeImmediateDemandToUserAction()
        case .favorites:
            changed = false
        }
        return changed ? [.publish] : []
    }
}
