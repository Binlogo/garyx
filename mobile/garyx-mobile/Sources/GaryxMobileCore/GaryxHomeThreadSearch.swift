import Combine
import Foundation

/// The five user-visible states of Home thread search. Transport and debounce
/// details stay in `GaryxHomeThreadSearchState`; views render this projection.
public enum GaryxHomeThreadSearchPresentation: Equatable, Sendable {
    case prompt
    case loading
    case results
    case empty(query: String)
    case failed(query: String, message: String)
}

/// Paging affordance shown below a non-empty result set.
public enum GaryxHomeThreadSearchFooterState: Equatable, Sendable {
    case hidden
    case idle
    case loading
    case failed
}

public struct GaryxHomeThreadSearchDebounceTicket: Equatable, Sendable {
    public let generation: UInt64
    public let query: String
}

public enum GaryxHomeThreadSearchDebounceDecision: Equatable, Sendable {
    case none
    case wait(
        ticket: GaryxHomeThreadSearchDebounceTicket,
        nanoseconds: UInt64
    )
}

public struct GaryxHomeThreadSearchRequest: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case head
        case page
    }

    public let generation: UInt64
    public let gatewayRequestToken: GaryxGatewayRequestToken
    public let query: String
    public let cursor: String?
    public let kind: Kind

    /// Importable production contract for the one gateway endpoint owned by
    /// Home search. Tests assert this value directly so the call site cannot
    /// silently inherit a workspace or recent-filter scope.
    public var endpointRequest: GaryxHomeThreadSearchEndpointRequest {
        GaryxHomeThreadSearchEndpointRequest(
            query: query,
            cursor: cursor
        )
    }
}

public struct GaryxHomeThreadSearchEndpointRequest: Equatable, Sendable {
    public static let pageLimit = 30

    public let rootWorkspacePath: String?
    public let tasks: GaryxThreadSummaryTaskFilter
    public let query: String
    public let limit: Int
    public let cursor: String?

    public init(query: String, cursor: String?) {
        rootWorkspacePath = nil
        tasks = .include
        self.query = query
        limit = Self.pageLimit
        self.cursor = cursor
    }
}

public enum GaryxHomeThreadSearchCompletion: Equatable, Sendable {
    case accepted
    case rejectedStale
    case rejectedStoreIdentity
}

/// Pure Home thread-search state machine.
///
/// Matching remains entirely server-owned. This type trims only the boundary
/// whitespace needed to decide whether a request exists and to bind a cursor
/// to the exact request string; it deliberately does not reproduce the
/// gateway's NFKC/case-fold matching rules.
public struct GaryxHomeThreadSearchState: Equatable, Sendable {
    public static let debounceNanoseconds: UInt64 = 250_000_000

    public private(set) var query: String?
    public private(set) var generation: UInt64
    public private(set) var threads: [GaryxThreadSummary]
    public private(set) var nextCursor: String?
    public private(set) var isPrimed: Bool
    public private(set) var isLoadingHead: Bool
    public private(set) var isLoadingMore: Bool
    public private(set) var headFailureMessage: String?
    public private(set) var loadMoreFailed: Bool
    public private(set) var gatewayRequestToken: GaryxGatewayRequestToken?
    public private(set) var isGatewayScopeActive: Bool

    private var awaitsDebounce: Bool
    private var storeIncarnationId: String?

    public init(
        generation: UInt64 = 0,
        gatewayRequestToken: GaryxGatewayRequestToken? = nil,
        isGatewayScopeActive: Bool? = nil
    ) {
        self.query = nil
        self.generation = generation
        self.threads = []
        self.nextCursor = nil
        self.isPrimed = false
        self.isLoadingHead = false
        self.isLoadingMore = false
        self.headFailureMessage = nil
        self.loadMoreFailed = false
        self.gatewayRequestToken = gatewayRequestToken
        self.isGatewayScopeActive = gatewayRequestToken != nil
            && (isGatewayScopeActive ?? true)
        self.awaitsDebounce = false
        self.storeIncarnationId = nil
    }

    public var presentation: GaryxHomeThreadSearchPresentation {
        guard let query else { return .prompt }
        if !threads.isEmpty {
            return .results
        }
        if isLoadingHead || awaitsDebounce {
            return .loading
        }
        if let headFailureMessage {
            return .failed(query: query, message: headFailureMessage)
        }
        if isPrimed {
            return .empty(query: query)
        }
        return .loading
    }

    public var footerState: GaryxHomeThreadSearchFooterState {
        guard presentation == .results, nextCursor != nil else {
            return .hidden
        }
        if isLoadingMore {
            return .loading
        }
        return loadMoreFailed ? .failed : .idle
    }

    public var debounceDecision: GaryxHomeThreadSearchDebounceDecision {
        guard awaitsDebounce, let query else { return .none }
        return .wait(
            ticket: GaryxHomeThreadSearchDebounceTicket(
                generation: generation,
                query: query
            ),
            nanoseconds: Self.debounceNanoseconds
        )
    }

    /// Rebinds every resident row, cursor, debounce ticket, and in-flight
    /// request to one exact gateway activation. The user query survives so an
    /// open search can rerun against the newly active gateway, but no row from
    /// the previous partition can remain visible.
    @discardableResult
    public mutating func replaceGatewayRequestToken(
        _ nextToken: GaryxGatewayRequestToken,
        isActive: Bool = true
    ) -> Bool {
        guard nextToken != gatewayRequestToken
                || isActive != isGatewayScopeActive else {
            return false
        }
        advanceGeneration()
        gatewayRequestToken = nextToken
        isGatewayScopeActive = isActive
        threads = []
        resetPageState()
        awaitsDebounce = isActive && query != nil
        return true
    }

    /// Replaces the semantic request query. Returns false when trimming makes
    /// the request identical, so display-only whitespace edits do not restart
    /// transport or invalidate a valid cursor.
    @discardableResult
    public mutating func replaceQuery(_ rawQuery: String?) -> Bool {
        let nextQuery = Self.normalizedQuery(rawQuery)
        guard nextQuery != query else { return false }
        advanceGeneration()
        query = nextQuery
        threads = []
        resetPageState()
        awaitsDebounce = isGatewayScopeActive && nextQuery != nil
        return true
    }

    /// Converts the still-current 250 ms debounce ticket into a first-page
    /// request. A superseded ticket cannot start transport.
    public mutating func beginDebouncedSearch(
        _ ticket: GaryxHomeThreadSearchDebounceTicket
    ) -> GaryxHomeThreadSearchRequest? {
        guard awaitsDebounce,
              !isLoadingHead,
              ticket.generation == generation,
              ticket.query == query else {
            return nil
        }
        awaitsDebounce = false
        return beginHeadRequest()
    }

    /// Re-runs the current query immediately. Existing rows stay resident
    /// while pull-to-refresh is in flight, but the old cursor and every prior
    /// request generation are invalidated synchronously.
    public mutating func beginRefresh() -> GaryxHomeThreadSearchRequest? {
        guard query != nil,
              gatewayRequestToken != nil,
              isGatewayScopeActive else {
            return nil
        }
        advanceGeneration()
        nextCursor = nil
        storeIncarnationId = nil
        isLoadingHead = false
        isLoadingMore = false
        headFailureMessage = nil
        loadMoreFailed = false
        awaitsDebounce = false
        return beginHeadRequest()
    }

    public mutating func beginLoadMore(
        retryingFailure: Bool = false
    ) -> GaryxHomeThreadSearchRequest? {
        guard let query,
              let gatewayRequestToken,
              isGatewayScopeActive,
              isPrimed,
              !threads.isEmpty,
              !isLoadingHead,
              !isLoadingMore,
              let nextCursor else {
            return nil
        }
        if loadMoreFailed && !retryingFailure {
            return nil
        }
        loadMoreFailed = false
        isLoadingMore = true
        return GaryxHomeThreadSearchRequest(
            generation: generation,
            gatewayRequestToken: gatewayRequestToken,
            query: query,
            cursor: nextCursor,
            kind: .page
        )
    }

    @discardableResult
    public mutating func complete(
        _ request: GaryxHomeThreadSearchRequest,
        page: GaryxThreadSummariesPage
    ) -> GaryxHomeThreadSearchCompletion {
        guard owns(request) else { return .rejectedStale }

        switch request.kind {
        case .head:
            guard isLoadingHead, request.cursor == nil else {
                return .rejectedStale
            }
            threads = Self.unique(page.threads)
            isLoadingHead = false
            isPrimed = true
            headFailureMessage = nil
            storeIncarnationId = page.storeIncarnationId
            nextCursor = Self.adoptedCursor(from: page)
            return .accepted

        case .page:
            guard isLoadingMore,
                  request.cursor == nextCursor else {
                return .rejectedStale
            }
            guard page.storeIncarnationId == storeIncarnationId else {
                isLoadingMore = false
                loadMoreFailed = true
                return .rejectedStoreIdentity
            }
            threads = Self.merging(threads, with: page.threads)
            isLoadingMore = false
            loadMoreFailed = false
            nextCursor = Self.adoptedCursor(from: page)
            return .accepted
        }
    }

    @discardableResult
    public mutating func fail(
        _ request: GaryxHomeThreadSearchRequest,
        message: String
    ) -> Bool {
        guard owns(request) else { return false }
        switch request.kind {
        case .head:
            guard isLoadingHead else { return false }
            isLoadingHead = false
            headFailureMessage = Self.failureMessage(message)
        case .page:
            guard isLoadingMore, request.cursor == nextCursor else { return false }
            isLoadingMore = false
            loadMoreFailed = true
        }
        return true
    }

    private mutating func beginHeadRequest() -> GaryxHomeThreadSearchRequest? {
        guard let query,
              let gatewayRequestToken,
              isGatewayScopeActive,
              !isLoadingHead else {
            return nil
        }
        isLoadingHead = true
        headFailureMessage = nil
        return GaryxHomeThreadSearchRequest(
            generation: generation,
            gatewayRequestToken: gatewayRequestToken,
            query: query,
            cursor: nil,
            kind: .head
        )
    }

    private func owns(_ request: GaryxHomeThreadSearchRequest) -> Bool {
        request.generation == generation
            && request.gatewayRequestToken == gatewayRequestToken
            && request.query == query
    }

    private mutating func resetPageState() {
        nextCursor = nil
        isPrimed = false
        isLoadingHead = false
        isLoadingMore = false
        headFailureMessage = nil
        loadMoreFailed = false
        storeIncarnationId = nil
    }

    private mutating func advanceGeneration() {
        generation &+= 1
    }

    private static func normalizedQuery(_ rawQuery: String?) -> String? {
        let query = rawQuery?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return query.isEmpty ? nil : query
    }

    private static func adoptedCursor(from page: GaryxThreadSummariesPage) -> String? {
        guard page.hasMore else { return nil }
        let cursor = page.nextCursor?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cursor.isEmpty ? nil : cursor
    }

    private static func unique(_ summaries: [GaryxThreadSummary]) -> [GaryxThreadSummary] {
        merging([], with: summaries)
    }

    private static func merging(
        _ current: [GaryxThreadSummary],
        with incoming: [GaryxThreadSummary]
    ) -> [GaryxThreadSummary] {
        var merged = current
        var indices: [String: Int] = [:]
        for (index, summary) in merged.enumerated() {
            let id = summary.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, indices[id] == nil else { continue }
            indices[id] = index
        }
        for summary in incoming {
            let id = summary.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            if let index = indices[id] {
                merged[index] = summary
            } else {
                indices[id] = merged.count
                merged.append(summary)
            }
        }
        return merged
    }

    private static func failureMessage(_ rawMessage: String) -> String {
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Could not load threads" : message
    }
}

struct GaryxHomeThreadSearchRowsContext: Equatable, Sendable {
    var gatewayRequestToken: GaryxGatewayRequestToken
    var isGatewayScopeActive: Bool
    var agents: [GaryxAgentSummary]
    var automationThreadIds: Set<String>
    var pinnedThreadIds: Set<String>
    var favoritedThreadIds: Set<String>
    var selectedThreadId: String?
    var runningThreadIds: Set<String>

    init(
        gatewayRequestToken: GaryxGatewayRequestToken,
        isGatewayScopeActive: Bool = true,
        agents: [GaryxAgentSummary] = [],
        automationThreadIds: Set<String> = [],
        pinnedThreadIds: Set<String> = [],
        favoritedThreadIds: Set<String> = [],
        selectedThreadId: String? = nil,
        runningThreadIds: Set<String> = []
    ) {
        self.gatewayRequestToken = gatewayRequestToken
        self.isGatewayScopeActive = isGatewayScopeActive
        self.agents = agents
        self.automationThreadIds = Self.normalizedIds(automationThreadIds)
        self.pinnedThreadIds = Self.normalizedIds(pinnedThreadIds)
        self.favoritedThreadIds = Self.normalizedIds(favoritedThreadIds)
        self.selectedThreadId = Self.normalizedId(selectedThreadId)
        self.runningThreadIds = Self.normalizedIds(runningThreadIds)
    }

    static let initial = GaryxHomeThreadSearchRowsContext(
        gatewayRequestToken: GaryxGatewayRequestToken(
            scope: GaryxGatewayScope(identity: "unconfigured", epoch: 1),
            activationSequence: 1
        ),
        isGatewayScopeActive: false
    )

    private static func normalizedIds(_ ids: Set<String>) -> Set<String> {
        Set(ids.compactMap(normalizedId))
    }

    private static func normalizedId(_ rawId: String?) -> String? {
        let id = rawId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return id.isEmpty ? nil : id
    }
}

/// Dedicated observable boundary for the live row inputs that do not belong
/// to the recency page. Search results can contain threads outside Home's
/// loaded window, so their favorite, pin, selection, automation, and run state
/// must not depend on the recency store deciding to publish.
@MainActor
final class GaryxHomeThreadSearchRowsStore: ObservableObject {
    @Published private(set) var context: GaryxHomeThreadSearchRowsContext
    private(set) var publishCount = 0

    init(context: GaryxHomeThreadSearchRowsContext = .initial) {
        self.context = context
    }

    @discardableResult
    func apply(_ nextContext: GaryxHomeThreadSearchRowsContext) -> Bool {
        guard nextContext != context else { return false }
        context = nextContext
        publishCount += 1
        return true
    }

    func rows(for threads: [GaryxThreadSummary]) -> [GaryxHomeThreadRow] {
        GaryxHomeThreadSearchRowsBuilder.build(
            threads: threads,
            context: context
        )
    }
}

/// Pure row projection for search results. It preserves the gateway's result
/// order while applying the same identity, action, favorite, pin, selection,
/// and running presentation used by Home.
enum GaryxHomeThreadSearchRowsBuilder {
    static func build(
        threads: [GaryxThreadSummary],
        context: GaryxHomeThreadSearchRowsContext
    ) -> [GaryxHomeThreadRow] {
        var agentsById: [String: GaryxAgentSummary] = [:]
        for agent in context.agents where agentsById[agent.id] == nil {
            agentsById[agent.id] = agent
        }

        var seen = Set<String>()
        return threads.compactMap { thread in
            let id = thread.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return GaryxHomeThreadSectionsBuilder.row(
                thread: thread,
                isSelected: context.selectedThreadId == id,
                isPinned: context.pinnedThreadIds.contains(id),
                isFavorite: context.favoritedThreadIds.contains(id),
                isRunning: context.runningThreadIds.contains(id),
                showsDivider: seen.count > 1,
                agentsById: agentsById,
                automationThreadIds: context.automationThreadIds
            )
        }
    }
}
