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
        // window. Prevent those off-screen controls from receiving either
        // touch or accessibility activation at the collapsed endpoint.
        .allowsHitTesting(isExpanded)
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

    func cancelSearch() {
        queryText = ""
        _ = mutate { $0.replaceQuery(nil) }
        cancelTransport()
    }

    func setChromeState(_ nextState: GaryxChromeMorphPresentationState) {
        chromeState = nextState
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
                query: request.query,
                cursor: request.cursor
            )
            try Task.checkCancellation()
            _ = mutate { $0.complete(request, page: page) }
        } catch {
            let message = GaryxMobileModel.isCancellationError(error)
                ? "Could not load threads"
                : model.displayMessage(for: error)
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
        query: String,
        cursor: String?
    ) async throws -> GaryxThreadSummariesPage {
        let runtimeGeneration = gatewayRequestToken
        let page = try await client().listThreadSummaries(
            tasks: .include,
            query: query,
            limit: 30,
            cursor: cursor
        )
        guard runtimeGeneration == gatewayRequestToken else {
            throw CancellationError()
        }
        return page
    }

    func homeThreadSearchRows(
        _ threads: [GaryxThreadSummary]
    ) -> [GaryxHomeThreadRow] {
        GaryxHomeThreadSearchRowsBuilder.build(
            GaryxHomeThreadSearchRowsInput(
                threads: threads,
                agents: agents,
                automations: automations,
                pinnedThreadIds: pinnedThreadIds,
                favoritedThreadIds: threadFavoritesState.presentedThreadIds,
                selectedThreadId: selectedThread?.id,
                runningThreadIds: remoteBusyThreadIds
            )
        )
    }
}
