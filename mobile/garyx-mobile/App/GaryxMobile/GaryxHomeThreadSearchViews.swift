// App-side composition and transport orchestration for Home thread search.
import Foundation
import SwiftUI

struct GaryxHomeThreadSearchChromeAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

enum GaryxHomeThreadSearchChromeMetrics {
    static let metrics = GaryxChromeMorphSurfaceMetrics(
        horizontalMargin: 16,
        maximumExpandedWidth: 620,
        collapsedCornerRadius: 22,
        expandedCornerRadius: 22
    )
}

struct GaryxHomeThreadSearchButton: View {
    let isHidden: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "magnifyingglass")
                .font(GaryxFont.fixedSystem(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .garyxAdaptiveGlass(
                    .regular,
                    isInteractive: true,
                    in: Circle(),
                    isEnabled: !isHidden
                )
                .contentShape(Circle())
        }
        .buttonStyle(GaryxPressableRowStyle())
        .opacity(isHidden ? 0 : 1)
        .allowsHitTesting(!isHidden)
        .accessibilityLabel("Search threads")
        .accessibilityIdentifier("home-thread-search-button")
        .accessibilityHidden(isHidden)
        // The source control stays mounted throughout the morph so this anchor
        // remains one continuous piece of geometry in both directions.
        .anchorPreference(
            key: GaryxHomeThreadSearchChromeAnchorKey.self,
            value: .bounds
        ) { $0 }
    }
}

struct GaryxHomeThreadSearchMorphSurface: View {
    @Environment(\.garyxMotion) private var motion

    let isExpanded: Bool
    let anchorRect: CGRect
    let containerSize: CGSize
    @Binding var queryText: String
    let focus: FocusState<Bool>.Binding
    let onCancel: () -> Void

    var body: some View {
        let renderedExpanded = motion.allowsSpatialMotion(.morphOpen) ? isExpanded : true
        GaryxChromeMorphSurface(
            isExpanded: renderedExpanded,
            anchorRect: anchorRect,
            containerSize: containerSize,
            metrics: GaryxHomeThreadSearchChromeMetrics.metrics,
            onClose: onCancel,
            isAccessibilityModal: false
        ) {
            GaryxHomeThreadSearchChromeContent(
                queryText: $queryText,
                focus: focus,
                onCancel: onCancel
            )
        }
        .opacity(motion.allowsSpatialMotion(.morphOpen) || isExpanded ? 1 : 0)
        // The final-width content stays mounted behind the morph's clipping
        // window. Disable touch and accessibility while it is clipped down to
        // the collapsed endpoint.
        .allowsHitTesting(isExpanded)
        .accessibilityHidden(!isExpanded)
    }
}

struct GaryxHomeThreadSearchOverlayHost: View {
    @ObservedObject var searchStore: GaryxHomeThreadSearchStore

    let anchor: Anchor<CGRect>?
    let model: GaryxMobileModel
    let focus: FocusState<Bool>.Binding
    let onCancel: () -> Void

    @ViewBuilder
    var body: some View {
        if searchStore.chromeState.isPresented, let anchor {
            GeometryReader { geometry in
                GaryxHomeThreadSearchMorphSurface(
                    isExpanded: searchStore.chromeState.isExpanded,
                    anchorRect: geometry[anchor],
                    containerSize: geometry.size,
                    queryText: queryBinding,
                    focus: focus,
                    onCancel: onCancel
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { searchStore.queryText },
            set: { searchStore.updateQuery($0, model: model) }
        )
    }
}

struct GaryxHomeThreadSearchModeList<SearchRows: View, RecentRows: View>: View {
    @ObservedObject var searchStore: GaryxHomeThreadSearchStore
    @ObservedObject var searchRowsStore: GaryxHomeThreadSearchRowsStore

    let isSidebarDragActive: Bool
    let onRefreshSearch: () async -> Void
    let onRefreshRecent: () async -> Void
    private let searchRows: () -> SearchRows
    private let recentRows: () -> RecentRows

    init(
        searchStore: GaryxHomeThreadSearchStore,
        searchRowsStore: GaryxHomeThreadSearchRowsStore,
        isSidebarDragActive: Bool,
        onRefreshSearch: @escaping () async -> Void,
        onRefreshRecent: @escaping () async -> Void,
        @ViewBuilder searchRows: @escaping () -> SearchRows,
        @ViewBuilder recentRows: @escaping () -> RecentRows
    ) {
        self.searchStore = searchStore
        self.searchRowsStore = searchRowsStore
        self.isSidebarDragActive = isSidebarDragActive
        self.onRefreshSearch = onRefreshSearch
        self.onRefreshRecent = onRefreshRecent
        self.searchRows = searchRows
        self.recentRows = recentRows
    }

    var body: some View {
        // Keep this mode owner outside the Equatable Home body cache. The
        // search store is the explicit invalidation path for the List builder.
        List {
            if searchStore.chromeState.isPresented {
                searchRows()
            } else {
                recentRows()
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        // Rows hide their UIKit backgrounds. Keep one opaque SwiftUI backing
        // layer so Reduce Transparency never reveals the hosting window.
        .background(GaryxTheme.background)
        .scrollDisabled(isSidebarDragActive)
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            if searchStore.chromeState.isPresented {
                await onRefreshSearch()
            } else {
                await onRefreshRecent()
            }
        }
    }
}

private struct GaryxHomeThreadSearchChromeContent: View {
    @Binding var queryText: String
    let focus: FocusState<Bool>.Binding
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // The outer morph is the sole glass surface. This reuses the
            // shared search-field layout without nesting a second glass pass.
            GaryxGlassSearchField(
                "Search threads",
                text: $queryText,
                focus: focus,
                accessibilityIdentifier: "home-thread-search-field",
                drawsGlassSurface: false
            )
            .frame(maxWidth: .infinity)
            .layoutPriority(1)

            Button("Cancel", action: onCancel)
                .font(GaryxFont.callout(weight: .medium))
                .foregroundStyle(.primary)
                .frame(minWidth: 68, minHeight: 44)
                .contentShape(Rectangle())
                .buttonStyle(GaryxPressableRowStyle())
                .accessibilityIdentifier("home-thread-search-cancel")
                .padding(.trailing, 4)
        }
        .frame(minHeight: 44)
        .garyxTypographyBoundary(.navigationChrome)
    }
}

struct GaryxHomeThreadSearchFooter: View {
    let state: GaryxHomeThreadSearchFooterState
    let onLoadMore: () async -> Void
    let onRetry: () async -> Void

    @ViewBuilder
    var body: some View {
        switch state {
        case .hidden:
            EmptyView()
        case .idle:
            Color.clear
                .frame(minHeight: 44)
                .onAppear {
                    Task { await onLoadMore() }
                }
        case .loading:
            ProgressView()
                .scaleEffect(0.72)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityLabel("Loading more threads")
        case .failed:
            Button("Couldn't load more · Tap to retry") {
                Task { await onRetry() }
            }
            .font(GaryxFont.caption(weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .buttonStyle(GaryxPressableRowStyle())
        }
    }
}

@MainActor
final class GaryxHomeThreadSearchStore: ObservableObject {
    @Published private(set) var queryText = ""
    @Published private(set) var state = GaryxHomeThreadSearchState()
    @Published private(set) var chromeState = GaryxChromeMorphPresentationState.hidden

    private var headTask: Task<Void, Never>?
    private var headTaskId: UUID?
    private var pageTask: Task<Void, Never>?
    private var pageTaskId: UUID?
    private var dismissalPending = false

    deinit {
        headTask?.cancel()
        pageTask?.cancel()
    }

    func updateQuery(_ rawQuery: String, model: GaryxMobileModel) {
        guard queryText != rawQuery else { return }
        queryText = rawQuery

        let changed = mutate { $0.replaceQuery(rawQuery) }
        guard changed else { return }
        cancelTransport()
        scheduleDebouncedSearch(model: model)
    }

    func synchronizeGatewayRequestToken(
        _ gatewayRequestToken: GaryxGatewayRequestToken,
        isActive: Bool,
        model: GaryxMobileModel
    ) {
        let changed = mutate {
            $0.replaceGatewayRequestToken(
                gatewayRequestToken,
                isActive: isActive
            )
        }
        guard changed else { return }
        cancelTransport()
        guard !dismissalPending else { return }
        scheduleDebouncedSearch(model: model)
    }

    func beginDismissal() {
        dismissalPending = true
        cancelTransport()
    }

    func beginPresentation() {
        dismissalPending = false
    }

    func completeDismissal() {
        queryText = ""
        _ = mutate { $0.replaceQuery(nil) }
        cancelTransport()
        dismissalPending = false
    }

    func setChromeState(_ nextState: GaryxChromeMorphPresentationState) {
        guard chromeState != nextState else { return }
        chromeState = nextState
    }

    private func scheduleDebouncedSearch(model: GaryxMobileModel) {
        guard case let .wait(ticket, nanoseconds) = state.debounceDecision else {
            return
        }
        let taskId = UUID()
        headTaskId = taskId
        headTask = Task { @MainActor [weak self, weak model] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                self?.finishHeadTask(taskId)
                return
            }
            guard !Task.isCancelled, let self, let model else { return }
            guard let request = mutate({
                $0.beginDebouncedSearch(ticket)
            }) else {
                finishHeadTask(taskId)
                return
            }
            await execute(request, model: model)
            finishHeadTask(taskId)
        }
    }

    func refresh(model: GaryxMobileModel) async {
        cancelTransport()
        guard let request = mutate({ $0.beginRefresh() }) else { return }
        await runHeadRequest(request, model: model)
    }

    func retry(model: GaryxMobileModel) async {
        await refresh(model: model)
    }

    func loadMore(
        model: GaryxMobileModel,
        retryingFailure: Bool = false
    ) async {
        guard let request = mutate({
            $0.beginLoadMore(retryingFailure: retryingFailure)
        }) else {
            return
        }

        let taskId = UUID()
        let task = Task { @MainActor [weak self, weak model] in
            guard let self, let model else { return }
            await execute(request, model: model)
        }
        pageTaskId = taskId
        pageTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        finishPageTask(taskId)
    }

    private func runHeadRequest(
        _ request: GaryxHomeThreadSearchRequest,
        model: GaryxMobileModel
    ) async {
        let taskId = UUID()
        let task = Task { @MainActor [weak self, weak model] in
            guard let self, let model else { return }
            await execute(request, model: model)
        }
        headTaskId = taskId
        headTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        finishHeadTask(taskId)
    }

    private func execute(
        _ request: GaryxHomeThreadSearchRequest,
        model: GaryxMobileModel
    ) async {
        do {
            let page = try await model.fetchHomeThreadSearchPage(
                request.endpointRequest,
                gatewayRequestToken: request.gatewayRequestToken
            )
            try Task.checkCancellation()
            _ = mutate { $0.complete(request, page: page) }
        } catch {
            guard !GaryxMobileModel.isCancellationError(error),
                  !Task.isCancelled else {
                return
            }
            let message = model.displayMessage(for: error)
            _ = mutate { $0.fail(request, message: message) }
        }
    }

    private func cancelTransport() {
        headTask?.cancel()
        pageTask?.cancel()
        headTask = nil
        headTaskId = nil
        pageTask = nil
        pageTaskId = nil
    }

    private func finishHeadTask(_ taskId: UUID) {
        guard headTaskId == taskId else { return }
        headTask = nil
        headTaskId = nil
    }

    private func finishPageTask(_ taskId: UUID) {
        guard pageTaskId == taskId else { return }
        pageTask = nil
        pageTaskId = nil
    }

    @discardableResult
    private func mutate<Value>(
        _ mutation: (inout GaryxHomeThreadSearchState) -> Value
    ) -> Value {
        var next = state
        let value = mutation(&next)
        if next != state {
            state = next
        }
        return value
    }
}

extension GaryxMobileModel {
    func fetchHomeThreadSearchPage(
        _ request: GaryxHomeThreadSearchEndpointRequest,
        gatewayRequestToken expectedToken: GaryxGatewayRequestToken
    ) async throws -> GaryxThreadSummariesPage {
        guard expectedToken == gatewayRequestToken,
              gatewayScopeRegistry.activeScope == expectedToken.scope else {
            throw CancellationError()
        }
        let page = try await client().listThreadSummaries(
            rootWorkspacePath: request.rootWorkspacePath,
            tasks: request.tasks,
            query: request.query,
            limit: request.limit,
            cursor: request.cursor
        )
        guard expectedToken == gatewayRequestToken,
              gatewayScopeRegistry.activeScope == expectedToken.scope else {
            throw CancellationError()
        }
        return page
    }

    func refreshHomeThreadSearchRowsStore() {
        _ = homeThreadSearchRowsStore.apply(
            GaryxHomeThreadSearchRowsContext(
                gatewayRequestToken: gatewayRequestToken,
                isGatewayScopeActive: gatewayScopeRegistry.activeScope
                    == gatewayRequestToken.scope,
                agents: agents,
                automationThreadIds: GaryxHomeThreadSectionsBuilder.automationThreadIds(
                    automations
                ),
                pinnedThreadIds: Set(pinnedThreadIds),
                favoritedThreadIds: Set(threadFavoritesState.presentedThreadIds),
                selectedThreadId: selectedThread?.id,
                runningThreadIds: remoteBusyThreadIds
            )
        )
    }
}
