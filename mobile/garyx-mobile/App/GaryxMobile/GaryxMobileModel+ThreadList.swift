import Foundation

private struct GaryxFetchedRecentRefresh {
    var bundle: GaryxRecentThreadRefreshBundle
    var threads: [GaryxThreadSummary]
}

private struct GaryxRecentIdentityInterrupted: Error {}

// Home recent-thread list: refresh and pagination, the widget snapshot
// projection, workspace/bot thread merging, completed-thread history
// hydration, and the background committed-run reconcile loop.
extension GaryxMobileModel {
    func selectRecentThreadFilter(_ filter: GaryxRecentThreadFilter) {
        guard recentThreadFeeds.selectedFilter != filter else { return }
        recentThreadFeeds.select(filter)
        GaryxRecentThreadFilterStorage.save(
            filter,
            defaults: defaults,
            key: GaryxMobileSettingsKeys.recentThreadFilter
        )
        Task { [weak self] in
            await self?.requestHomeFeedRefresh(source: .userAction)
        }
    }

    func performRecentHeadRequest(
        _ ticket: GaryxRecentThreadRefreshTicket,
        authority _: GaryxHomeFeedSyncAuthority
    ) async {
        let runtimeGeneration = gatewayRequestToken
        let previousThreadSummaries = Self.mergedThreadSummaries(
            residentRecentThreadSummaries + [selectedThread].compactMap { $0 }
        )
        let previouslyRemoteBusyThreadIds = remoteBusyThreadIds
        let transactionId = homeProjectionGateway.beginTransaction(
            label: "home-feed-sync"
        )
        defer { homeProjectionGateway.endTransaction(transactionId) }
        do {
            let gatewayClient = try client()
            if !ticket.updatesHomeChrome {
                let fetched = try await fetchRecentRefresh(
                    ticket: ticket,
                    gatewayClient: gatewayClient
                )
                if runtimeGeneration != gatewayRequestToken {
                    let completion = recentThreadFeeds.completeHead(
                        ticket,
                        result: .interrupted(.supersededByReset)
                    )
                    homeFeedSyncCoordinator.runRecentFeedEffects(completion.effects)
                    return
                }
                let completion = recentThreadFeeds.completeHead(
                    ticket,
                    result: .page(fetched.bundle)
                )
                homeFeedSyncCoordinator.runRecentFeedEffects(completion.effects)
                if completion.outcome == .applied {
                    cacheThreadSummaries(
                        pendingThreadArchives.visibleThreads(fetched.threads)
                    )
                    persistRecentThreadsWidgetSnapshot()
                }
                return
            }

            let pinsRequestStamp = capturePinnedOrderRequestStamp()
            async let recentRefresh = fetchRecentRefresh(
                ticket: ticket,
                gatewayClient: gatewayClient
            )
            async let threadPinsPage = gatewayClient.listThreadPins()
            let (fetchedRefresh, pinsPage) = try await (recentRefresh, threadPinsPage)
            if runtimeGeneration != gatewayRequestToken {
                let completion = recentThreadFeeds.completeHead(
                    ticket,
                    result: .interrupted(.supersededByReset)
                )
                homeFeedSyncCoordinator.runRecentFeedEffects(completion.effects)
                return
            }
            var fetchedThreads = pendingThreadArchives.visibleThreads(fetchedRefresh.threads)
            let selectionIdForThisRefresh = selectedThread?.id
            let requiredThreadIds = normalizedThreadIds(
                pendingThreadArchives.visibleThreadIds(pinsPage.threadIds) + [selectionIdForThisRefresh]
            )
            fetchedThreads += await fetchMissingThreadSummaries(
                using: gatewayClient,
                requiredThreadIds: requiredThreadIds,
                existingThreadIds: Set(fetchedThreads.map(\.id))
            )
            if runtimeGeneration != gatewayRequestToken {
                let completion = recentThreadFeeds.completeHead(
                    ticket,
                    result: .interrupted(.supersededByReset)
                )
                homeFeedSyncCoordinator.runRecentFeedEffects(completion.effects)
                return
            }

            let completion = recentThreadFeeds.completeHead(
                ticket,
                result: .page(fetchedRefresh.bundle)
            )
            homeFeedSyncCoordinator.runRecentFeedEffects(completion.effects)
            if completion.outcome == .applied {
                commitRefreshedRecentThreadsPage(
                    pinsPageThreadIds: pinsPage.threadIds,
                    fetchedThreads: fetchedThreads,
                    previousThreadSummaries: previousThreadSummaries,
                    previouslyRemoteBusyThreadIds: previouslyRemoteBusyThreadIds,
                    selectionIdForThisRefresh: selectionIdForThisRefresh,
                    runtimeGeneration: runtimeGeneration,
                    pinsRevision: pinsPage.revision,
                    pinsRequestStamp: pinsRequestStamp
                )
            }
        } catch is GaryxRecentIdentityInterrupted {
            let completion = recentThreadFeeds.completeHead(
                ticket,
                result: .interrupted(.identityReplacement)
            )
            homeFeedSyncCoordinator.runRecentFeedEffects(completion.effects)
        } catch is CancellationError {
            let completion = recentThreadFeeds.completeHead(
                ticket,
                result: .interrupted(.interrupted)
            )
            homeFeedSyncCoordinator.runRecentFeedEffects(completion.effects)
        } catch {
            let completion = recentThreadFeeds.completeHead(
                ticket,
                result: .failed
            )
            homeFeedSyncCoordinator.runRecentFeedEffects(completion.effects)
            if runtimeGeneration != gatewayRequestToken {
                return
            }
            if recentThreadFeeds.selectedFilter == ticket.filter {
                presentThreadListRefreshFailure(source: ticket.source, error: error)
            }
        }
    }

    private func fetchRecentRefresh(
        ticket: GaryxRecentThreadRefreshTicket,
        gatewayClient: GaryxGatewayClient
    ) async throws -> GaryxFetchedRecentRefresh {
        let primary = try await fetchRecentChain(
            ticket: ticket,
            mode: ticket.mode,
            oldHeadActivitySeq: ticket.oldHeadActivitySeq,
            gatewayClient: gatewayClient
        )
        let verification = try await fetchRecentPage(
            ticket: ticket,
            cursor: nil,
            gatewayClient: gatewayClient
        )
        let primaryHead = primary.pages.first?.headActivitySeq
        var immediate: (pages: [GaryxRecentThreadFeedPage], threads: [GaryxThreadSummary])?
        var immediateVerification: GaryxRecentThreadFeedPage?
        if GaryxRecentThreadRangeFill.verificationObservedNewerHead(
            chainFirstHead: primaryHead,
            verificationPage: verification.feedPage
        ) {
            immediate = try await fetchRecentChain(
                ticket: ticket,
                mode: .rangeFill,
                oldHeadActivitySeq: primaryHead,
                gatewayClient: gatewayClient
            )
            immediateVerification = try await fetchRecentPage(
                ticket: ticket,
                cursor: nil,
                gatewayClient: gatewayClient
            ).feedPage
        }
        return GaryxFetchedRecentRefresh(
            bundle: GaryxRecentThreadRefreshBundle(
                primaryPages: primary.pages,
                verificationPage: verification.feedPage,
                immediatePages: immediate?.pages,
                immediateVerificationPage: immediateVerification
            ),
            threads: primary.threads + (immediate?.threads ?? [])
        )
    }

    private func fetchRecentChain(
        ticket: GaryxRecentThreadRefreshTicket,
        mode: GaryxRecentThreadRefreshMode,
        oldHeadActivitySeq: Int64?,
        gatewayClient: GaryxGatewayClient
    ) async throws -> (pages: [GaryxRecentThreadFeedPage], threads: [GaryxThreadSummary]) {
        var pages: [GaryxRecentThreadFeedPage] = []
        var threads: [GaryxThreadSummary] = []
        var cursor: String?
        repeat {
            let fetched = try await fetchRecentPage(
                ticket: ticket,
                cursor: cursor,
                gatewayClient: gatewayClient
            )
            pages.append(fetched.feedPage)
            threads += fetched.threads
            cursor = fetched.nextCursor
        } while GaryxRecentThreadRangeFill.needsNextPage(
            mode: mode,
            oldHeadActivitySeq: oldHeadActivitySeq,
            pages: pages
        )
        return (pages, threads)
    }

    private func fetchRecentPage(
        ticket: GaryxRecentThreadRefreshTicket,
        cursor: String?,
        gatewayClient: GaryxGatewayClient
    ) async throws -> (
        feedPage: GaryxRecentThreadFeedPage,
        threads: [GaryxThreadSummary],
        nextCursor: String?
    ) {
        let page = try await gatewayClient.listRecentThreads(
            filter: ticket.filter,
            limit: Self.threadListPageLimit,
            cursor: cursor
        )
        guard let ownedFeed = recentThreadFeeds.feed(for: ticket.filter) else {
            throw GaryxRecentIdentityInterrupted()
        }
        let decision = observeThreadStoreIdentity(
            gatewayScope: ticket.gatewayScope,
            runtimeEpoch: ticket.runtimeEpoch,
            owned: ownedFeed.pager.epoch == ticket.pagerTicket.epoch
                && ownedFeed.pager.isRefreshingHead,
            storeIncarnationId: page.storeIncarnationId
        )
        guard decision == .accept else { throw GaryxRecentIdentityInterrupted() }
        return (GaryxRecentThreadFeedPage(page), page.threads, page.nextCursor)
    }

    /// Archive/delete ambiguity keeps today's rollback/error UX, then calls
    /// this reconstruction path. A commit before either replacement snapshot
    /// disappears now; a later commit is picked up by the next M=30/foreground
    /// replacement cycle.
    func forceReplaceThreadFeedsAfterAmbiguousLifecycle(
        reconstructionTickets: [GaryxThreadReconstructionTicket] = []
    ) async {
        recentThreadFeeds.forceReplacement()
        async let favorites: Void = refreshThreadFavoritesSnapshotAndWait()
        async let recent: Void = homeFeedSyncCoordinator.replaceAllRecentFeeds()
        _ = await (favorites, recent)
        await reconstructResidentThreadLists(reconstructionTickets)
    }

    private func reconstructResidentThreadLists(
        _ tickets: [GaryxThreadReconstructionTicket]
    ) async {
        guard !tickets.isEmpty else { return }
        for ticket in tickets {
            let outcome: GaryxThreadReconstructionOutcome
            if ticket.storeId == "home" {
                let selectedReady: Bool
                switch recentThreadFeeds.selectedFilter {
                case .favorites:
                    selectedReady = threadFavoritesState.headPhase == .ready
                case .all:
                    selectedReady = recentThreadFeeds.allFeed.headPhase == .ready
                case .nonTask:
                    selectedReady = recentThreadFeeds.nonTaskFeed.headPhase == .ready
                }
                if selectedReady {
                    outcome = .authoritative(
                        orderedThreadIds: normalizedThreadIds(
                            pinnedThreadIds.map(Optional.some)
                                + visibleRecentThreadIds.map(Optional.some)
                        )
                    )
                } else {
                    outcome = .failed(message: "Thread reconstruction did not complete.")
                }
            } else if ticket.storeId == "recent:all" {
                outcome = recentReconstructionOutcome(recentThreadFeeds.allFeed)
            } else if ticket.storeId == "recent:non_task" {
                outcome = recentReconstructionOutcome(recentThreadFeeds.nonTaskFeed)
            } else if ticket.storeId.hasPrefix("workspace:") {
                let path = String(ticket.storeId.dropFirst("workspace:".count))
                await refreshWorkspaceThreadList(path: path)
                outcome = reconstructionOutcome(
                    snapshot: workspaceThreadStores[path]?.snapshot
                )
            } else if ticket.storeId.hasPrefix("automation:") {
                let automationId = String(ticket.storeId.dropFirst("automation:".count))
                await refreshAutomationThreadList(automationId: automationId)
                outcome = reconstructionOutcome(
                    snapshot: automationThreadStores[automationId]?.snapshot
                )
            } else if ticket.storeId.hasPrefix("bot:") {
                let groupId = String(ticket.storeId.dropFirst("bot:".count))
                await refreshRemoteState()
                if let group = mobileBotGroups.first(where: { $0.id == groupId }) {
                    refreshBotThreadList(group: group)
                    let hydrationTasks = botThreadHydrationTasks[groupId]
                        .map { Array($0.values) } ?? []
                    for task in hydrationTasks {
                        await task.value
                    }
                    outcome = reconstructionOutcome(
                        snapshot: botThreadStores[groupId]?.snapshot
                    )
                } else {
                    outcome = .authoritative(orderedThreadIds: [])
                }
            } else {
                outcome = .failed(message: "Unknown thread-list owner.")
            }
            _ = threadMutationHubStore.value.completeReconstruction(
                ticket,
                outcome: outcome
            )
        }
        // Provider commits happen before the hub accepts each authoritative
        // replacement. Re-project once so generic stores drop any pending
        // motion cleared by successful reconstruction (or retain sticky
        // motion when a replacement failed).
        refreshResidentThreadListStores()
    }

    private func recentReconstructionOutcome(
        _ feed: GaryxRecentThreadFeedState
    ) -> GaryxThreadReconstructionOutcome {
        guard feed.headPhase == .ready,
              !feed.forceReplacementPending else {
            return .failed(message: "Thread reconstruction did not complete.")
        }
        return .authoritative(orderedThreadIds: feed.orderedThreadIds)
    }

    private func reconstructionOutcome(
        snapshot: GaryxThreadListPresentationSnapshot?
    ) -> GaryxThreadReconstructionOutcome {
        guard let snapshot,
              snapshot.isPrimed,
              !snapshot.isRefreshing,
              !snapshot.headFailure,
              snapshot.availability == .ready else {
            return .failed(message: "Thread reconstruction did not complete.")
        }
        return .authoritative(
            orderedThreadIds: snapshot.pinnedThreadIds + snapshot.orderedThreadIds
        )
    }

    /// Synchronous commit of a completed head-refresh transaction. Runs
    /// entirely on the MainActor after the refresh's last await, so all
    /// inputs captured before the backfill are re-filtered here against the
    /// committed tombstones in `pendingThreadArchives`: a thread archived
    /// while the backfill was suspended must not be resurrected by pre-await
    /// snapshots (review #TASK-1804 round 2).
    func commitRefreshedRecentThreadsPage(
        pinsPageThreadIds: [String],
        fetchedThreads: [GaryxThreadSummary],
        previousThreadSummaries: [GaryxThreadSummary],
        previouslyRemoteBusyThreadIds: Set<String>,
        selectionIdForThisRefresh: String?,
        runtimeGeneration: GaryxGatewayRequestToken,
        pinsRevision: Int64 = 0,
        pinsRequestStamp: GaryxPinnedOrderRequestStamp? = nil
    ) {
        applyPinnedThreadIds(
            pendingThreadArchives.visibleThreadIds(pinsPageThreadIds),
            revision: pinsRevision,
            stamp: pinsRequestStamp
        )
        let visibleFetchedThreads = pendingThreadArchives.visibleThreads(fetchedThreads)
        let previousRuntimeByThreadId = Dictionary(
            uniqueKeysWithValues: previousThreadSummaries.compactMap { thread -> (String, GaryxThreadRuntimeSummary)? in
                guard let runtime = thread.threadRuntime else { return nil }
                return (thread.id, runtime)
            }
        )
        let refreshedGatewayThreads = Self.mergedThreadSummaries(visibleFetchedThreads).map { thread in
            var next = thread
            if next.threadRuntime == nil {
                next.threadRuntime = previousRuntimeByThreadId[next.id]
            }
            return next
        }
        let refreshedThreads = refreshedGatewayThreads.map(summaryWithCommittedRunState)
        cacheThreadSummaries(refreshedThreads)
        persistRecentThreadsWidgetSnapshot()
        hydrateCompletedRecentThreadHistories(
            previousThreads: previousThreadSummaries,
            previouslyRemoteBusyThreadIds: previouslyRemoteBusyThreadIds,
            refreshedThreads: refreshedGatewayThreads,
            runtimeGeneration: runtimeGeneration
        )
        let currentSelectedId = selectedThread?.id
        if let selectionIdForThisRefresh,
           currentSelectedId == selectionIdForThisRefresh,
           let updatedSelection = threadSummaryCache.summary(for: selectionIdForThisRefresh) {
            var nextSelection = updatedSelection
            if nextSelection.threadRuntime == nil {
                nextSelection.threadRuntime = selectedThread?.threadRuntime
            }
            nextSelection = summaryWithCommittedRunState(nextSelection)
            if selectedThread != nextSelection {
                selectedThread = nextSelection
            }
            if draftThreadTitle != nextSelection.title {
                draftThreadTitle = nextSelection.title
            }
        }
    }

    private func presentThreadListRefreshFailure(source: GaryxThreadListRefreshSource, error: Error) {
        switch GaryxThreadListRefreshPolicy.failurePresentation(source: source) {
        case .toast:
            lastError = displayMessage(for: error)
        case .transientStatus:
            gatewaySettingsStatus = "Waiting to sync with gateway"
        }
    }

    func refreshHomeThreadsAfterLocalRunStart() {
        refreshHomeThreadsAfterLocalRunStateChange()
        scheduleHomeThreadsRunStateRefresh(after: 350_000_000)
    }

    func refreshHomeThreadsAfterLocalRunStateChange() {
        scheduleHomeThreadsRunStateRefresh()
    }

    private func scheduleHomeThreadsRunStateRefresh(after delayNanos: UInt64? = nil) {
        guard hasGatewaySettings else { return }
        Task { [weak self] in
            if let delayNanos {
                try? await Task.sleep(nanoseconds: delayNanos)
                guard !Task.isCancelled else { return }
            }
            await self?.refreshHomeThreadsRunStateIfConnected()
        }
    }

    private func refreshHomeThreadsRunStateIfConnected() async {
        guard hasGatewaySettings, case .ready = connectionState else { return }
        await requestHomeFeedRefresh(source: .backgroundLoop)
    }

    func persistRecentThreadsWidgetSnapshot() {
        recentThreadsWidgetPersistenceGeneration &+= 1
        let generation = recentThreadsWidgetPersistenceGeneration
        let token = "widget-\(generation)"
        let summaries = residentRecentThreadSummaries
        let input = GaryxRecentThreadsWidgetSnapshotInput(
            threads: summaries,
            agents: agents,
            pinnedThreadIds: pinnedThreadIds,
            recentThreadIds: allRecentThreadIds,
            gatewayScopeId: currentGatewayScopeId
        )
        threadSummaryLeaseOwner.beginWidgetWrite(
            token: token,
            threadIds: summaries.map(\.id),
            summaries: summaries
        )
        let queue = recentThreadsWidgetPersistenceQueue
        let store = avatarStore
        Task(priority: .utility) { [weak self] in
            let outcome = await queue.persist(
                input: input,
                generation: generation,
                avatarStore: store,
                validator: GaryxAvatarCGImageValidator()
            )
            guard let self else { return }
            switch outcome {
            case .finished:
                threadSummaryLeaseOwner.finishWidgetWrite(token: token)
            case .cancelled:
                threadSummaryLeaseOwner.cancelWidgetWrite(token: token)
            case .skipped:
                threadSummaryLeaseOwner.skipWidgetWrite(token: token)
            }
        }
    }

    func widgetAgentIdentity(for thread: GaryxThreadSummary) -> WidgetAgentIdentity {
        let identity = GaryxWidgetAgentIdentityProjector.identity(
            for: thread,
            agents: agents
        )
        return WidgetAgentIdentity(
            id: identity.id,
            name: identity.name,
            avatarDataUrl: identity.avatarDataUrl,
            providerType: identity.providerType,
            builtIn: identity.builtIn
        )
    }

    @discardableResult
    func applyThreadTitleUpdate(threadId: String, title: String) -> Bool {
        let normalizedThreadId = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadId.isEmpty, !nextTitle.isEmpty else { return false }

        var changed = false
        if var cached = threadSummaryCache.summary(for: normalizedThreadId),
           cached.title != nextTitle {
            let mutationId = nextThreadMutationId(kind: "rename", threadId: normalizedThreadId)
            _ = threadMutationHubStore.value.began(
                mutationId: mutationId,
                kind: .rename(threadId: normalizedThreadId),
                gatewayRuntimeEpoch: threadMutationHubStore.value.gatewayRuntimeEpoch
            )
            cached.title = nextTitle
            cacheThreadSummaries([cached])
            _ = threadMutationHubStore.value.committed(
                mutationId: mutationId,
                gatewayRuntimeEpoch: threadMutationHubStore.value.gatewayRuntimeEpoch,
                authority: GaryxThreadMutationAuthority(summary: cached)
            )
            changed = true
        }

        if selectedThread?.id == normalizedThreadId,
           selectedThread?.title != nextTitle {
            selectedThread?.title = nextTitle
            draftThreadTitle = nextTitle
            changed = true
        }

        if changed {
            persistRecentThreadsWidgetSnapshot()
        }
        return changed
    }

    func loadMoreThreads(trigger: GaryxThreadListLoadMoreTrigger) async {
        guard hasGatewaySettings,
              let ticket = recentThreadFeeds.requestLoadMore(
                  trigger: trigger,
                  gatewayScope: threadFavoritesState.gatewayScope,
                  runtimeEpoch: threadFavoritesState.runtimeEpoch
              ) else {
            // Rejected triggers are free: nothing is consumed, and the
            // sentinel/footer re-evaluate from pager state (TASK-1802 R4).
            return
        }
        await performLoadMoreThreads(ticket: ticket)
    }

    /// The explicit tap on the failed footer row.
    func retryLoadMoreThreads() async {
        guard hasGatewaySettings,
              let ticket = recentThreadFeeds.retryLoadMore(
                  gatewayScope: threadFavoritesState.gatewayScope,
                  runtimeEpoch: threadFavoritesState.runtimeEpoch
              ) else {
            return
        }
        await performLoadMoreThreads(ticket: ticket)
    }

    private func performLoadMoreThreads(ticket: GaryxRecentThreadLoadMoreTicket) async {
        let runtimeGeneration = gatewayRequestToken
        do {
            let page = try await client().listRecentThreads(
                filter: ticket.filter,
                limit: ticket.limit,
                cursor: ticket.cursor
            )
            guard runtimeGeneration == gatewayRequestToken else {
                homeFeedSyncCoordinator.runRecentFeedEffects(
                    recentThreadFeeds.interruptLoadMore(ticket)
                )
                return
            }
            let pageThreads = pendingThreadArchives.visibleThreads(page.threads)
            guard let ownedFeed = recentThreadFeeds.feed(for: ticket.filter) else {
                throw GaryxRecentIdentityInterrupted()
            }
            let identity = observeThreadStoreIdentity(
                gatewayScope: ticket.gatewayScope,
                runtimeEpoch: ticket.runtimeEpoch,
                owned: ownedFeed.pager.epoch == ticket.pagerTicket.epoch
                    && ownedFeed.pager.isLoadingMore,
                storeIncarnationId: page.storeIncarnationId
            )
            guard identity == .accept else {
                homeFeedSyncCoordinator.runRecentFeedEffects(
                    recentThreadFeeds.interruptLoadMore(ticket)
                )
                return
            }
            let completion = recentThreadFeeds.completeLoadMore(
                ticket,
                page: GaryxRecentThreadFeedPage(page)
            )
            homeFeedSyncCoordinator.runRecentFeedEffects(completion.effects)
            switch completion.outcome {
            case .abandonedStaleEpoch:
                // Pager reset mid-flight: the page belongs to the previous
                // gateway and is dropped silently.
                return
            case .abandonedLocalMutation:
                // Archive/delete/pin surgery raced this page (review
                // #TASK-1804 round 4): dedup-append against the
                // post-surgery list would resurrect the removed row as a
                // "new" id. The cursor did not advance; re-request the same
                // window with fresh filters.
                scheduleLoadMoreFollowUpAfterLocalMutation()
                return
            case .forceReplacement:
                await forceReplaceThreadFeedsAfterAmbiguousLifecycle()
                return
            case .applied:
                cacheThreadSummaries(pageThreads)
                persistRecentThreadsWidgetSnapshot()
            case .failed, .interrupted:
                return
            }
        } catch is GaryxRecentIdentityInterrupted {
            homeFeedSyncCoordinator.runRecentFeedEffects(
                recentThreadFeeds.interruptLoadMore(ticket)
            )
        } catch {
            // No global toast: the footer's failed state is the feedback,
            // and the pager's failed gate blocks automatic re-fires
            // (TASK-1802 R5).
            homeFeedSyncCoordinator.runRecentFeedEffects(
                recentThreadFeeds.failLoadMore(ticket)
            )
        }
    }

    /// Re-issues an abandoned load-more. Goes through the normal gate; when
    /// the abandoned request was an explicit retry (gate still `.failed`),
    /// the follow-up continues that user intent via `retryLoadMore`.
    private func scheduleLoadMoreFollowUpAfterLocalMutation() {
        Task { [weak self] in
            guard let self else { return }
            guard let ticket = recentThreadFeeds.requestLoadMore(
                trigger: .footer,
                gatewayScope: threadFavoritesState.gatewayScope,
                runtimeEpoch: threadFavoritesState.runtimeEpoch
            )
                ?? recentThreadFeeds.retryLoadMore(
                    gatewayScope: threadFavoritesState.gatewayScope,
                    runtimeEpoch: threadFavoritesState.runtimeEpoch
                ) else {
                return
            }
            await performLoadMoreThreads(ticket: ticket)
        }
    }

    func hydrateCompletedRecentThreadHistories(
        previousThreads: [GaryxThreadSummary],
        previouslyRemoteBusyThreadIds: Set<String>,
        refreshedThreads: [GaryxThreadSummary],
        runtimeGeneration: GaryxGatewayRequestToken
    ) {
        guard hasGatewaySettings else { return }
        let previousThreadsById = Dictionary(uniqueKeysWithValues: previousThreads.map { ($0.id, $0) })
        for thread in refreshedThreads {
            let threadId = thread.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !threadId.isEmpty,
                  shouldHydrateCompletedRecentThread(
                    previousThread: previousThreadsById[threadId],
                    previousRemoteBusyThreadIds: previouslyRemoteBusyThreadIds,
                    refreshedThread: thread
                  ) else {
                continue
            }
            hydrateCompletedRecentThreadHistory(
                threadId: threadId,
                runtimeGeneration: runtimeGeneration
            )
        }
    }

    func shouldHydrateCompletedRecentThread(
        previousThread: GaryxThreadSummary?,
        previousRemoteBusyThreadIds: Set<String>,
        refreshedThread: GaryxThreadSummary
    ) -> Bool {
        GaryxCompletedThreadHydrationPolicy.shouldHydrate(
            previousThread: previousThread,
            previousRemoteBusyThreadIds: previousRemoteBusyThreadIds,
            refreshedThread: refreshedThread,
            selectedThreadId: selectedThread?.id
        )
    }

    func hydrateCompletedRecentThreadHistory(threadId: String, runtimeGeneration: GaryxGatewayRequestToken) {
        guard completedThreadHistoryHydrationTasks[threadId] == nil else { return }
        completedThreadHistoryHydrationTasks[threadId] = Task { [weak self] in
            guard let self else { return }
            await hydrateCompletedRecentThreadHistoryNow(
                threadId: threadId,
                runtimeGeneration: runtimeGeneration
            )
        }
    }

    @discardableResult
    func hydrateCompletedRecentThreadHistoryNow(threadId: String, runtimeGeneration: GaryxGatewayRequestToken) async -> Bool {
        defer {
            completedThreadHistoryHydrationTasks[threadId] = nil
        }
        guard runtimeGeneration == gatewayRequestToken,
              hasGatewaySettings else {
            return true
        }
        do {
            let transcript = try await client().threadHistory(
                threadId: threadId,
                limit: Self.threadHistoryPageLimit,
                userQueryLimit: Self.threadHistoryUserQueryLimit
            )
            guard runtimeGeneration == gatewayRequestToken else { return true }
            let prepared = await Task.detached(priority: .utility) {
                GaryxPreparedThreadTranscriptUpdate.make(from: transcript)
            }.value
            return applyPreparedThreadTranscriptToCache(
                prepared,
                transcript: transcript,
                threadId: threadId,
                preservingLoadedOlderPages: true,
                scheduleRecoveryIfSelected: false
            )
        } catch {
            guard runtimeGeneration == gatewayRequestToken else { return true }
            let message = displayMessage(for: error)
            if Self.isTransientGatewayErrorMessage(message) {
                gatewaySettingsStatus = "Waiting to sync with gateway"
            }
            return true
        }
    }

    func startBackgroundCommittedRunReconcileLoop() {
        guard hasGatewaySettings,
              isHomeVisible,
              case .ready = connectionState else {
            cancelBackgroundCommittedRunReconcileLoop()
            return
        }
        guard backgroundCommittedRunReconcileTask == nil else { return }
        let runtimeGeneration = gatewayRequestToken
        backgroundCommittedRunReconcileTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.backgroundCommittedRunReconcileIntervalNanos)
                if Task.isCancelled { break }
                await reconcileBackgroundCommittedRunStates(runtimeGeneration: runtimeGeneration)
            }
        }
    }

    func cancelBackgroundCommittedRunReconcileLoop() {
        backgroundCommittedRunReconcileTask?.cancel()
        backgroundCommittedRunReconcileTask = nil
    }

    func reconcileBackgroundCommittedRunStates(runtimeGeneration: GaryxGatewayRequestToken) async {
        guard runtimeGeneration == gatewayRequestToken,
              hasGatewaySettings,
              case .ready = connectionState else {
            cancelBackgroundCommittedRunReconcileLoop()
            return
        }
        let decision = backgroundCommittedRunReconcilePlanner.nextDecision(
            candidateThreadIds: backgroundCommittedRunCandidateThreadIds()
        )
        guard decision.hydratesCandidateThreads else { return }

        for threadId in decision.candidateThreadIds {
            if Task.isCancelled { break }
            if completedThreadHistoryHydrationTasks[threadId] != nil {
                continue
            }
            let remainedBusy = await hydrateCompletedRecentThreadHistoryNow(
                threadId: threadId,
                runtimeGeneration: runtimeGeneration
            )
            if !remainedBusy {
                publishThreadSummaryState()
            }
        }
    }

    func syncBackgroundCommittedRunReconcileLoopForHomeVisibility() {
        if isHomeVisible {
            startBackgroundCommittedRunReconcileLoop()
        } else {
            cancelBackgroundCommittedRunReconcileLoop()
        }
    }

    func backgroundCommittedRunCandidateThreadIds() -> [String] {
        GaryxBackgroundCommittedRunReconcilePlanner.candidateThreadIds(
            locallyTrackedThreadIds: runTracker.locallyTrackedThreadIds,
            runStateByThread: runStateByThread,
            threads: residentRecentThreadSummaries,
            selectedThreadId: selectedThread?.id
        )
    }
}
