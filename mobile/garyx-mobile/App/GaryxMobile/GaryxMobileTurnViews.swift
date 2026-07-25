import SwiftUI

/// Named coordinate space attached to the transcript CONTENT stack (not the
/// scroll viewport). Positions measured in it are scroll-invariant: they only
/// change when the layout itself changes, which is what makes it the right
/// ruler for older-history prepend compensation — the anchor row's
/// content-space displacement IS the exact height inserted above it,
/// unaffected by concurrent tail growth or reader scrolling.
let garyxConversationContentSpaceName = "garyx-conversation-content"

/// The single owner of the gap between transcript rows.
///
/// Both the row stack that produces the gap and the window planner that
/// accounts for the gaps a collapse removes read this one value: a drift
/// between them would silently shift every spacer by (N-1) x delta with no
/// test failing (review #TASK-2707 N11).
let garyxConversationRowSpacing: CGFloat = 14

/// Stable sink for the transcript's per-row callbacks.
///
/// Callbacks live behind a reference so a row view can be `Equatable`: closure
/// values are never equal, so passing them per row forced SwiftUI to rebuild
/// every row body on every root update. The transcript owns one sink for the
/// lifetime of its occurrence and only mutates the handlers inside it.
final class GaryxTurnRowCallbackSink {
    var onNearHistoryBoundary: () -> Void = {}
    /// One callback carries both facts the transcript needs from a row:
    /// its scroll-invariant content-space start (prepend compensation) and its
    /// own height (window planning). Height is intrinsic, so it stays valid
    /// while the row is collapsed — unlike a position, which goes stale the
    /// moment the row stops reporting (review #TASK-2707 BLOCKER-2).
    var onRowContentGeometryChange: (_ rowId: String, _ minY: CGFloat, _ height: CGFloat) -> Void
        = { _, _, _ in }
}

struct GaryxMobileTurnRowsView: View {
    let rows: [GaryxMobileTurnRow]
    let prefetchBoundaryRowCount: Int
    let sink: GaryxTurnRowCallbackSink
    /// Windowing plan from `GaryxTranscriptWindowPlanner`. Empty means "lay
    /// every row out", which is also the state before the first measurement.
    let windowPlan: [GaryxTranscriptWindowPlanner.Segment]

    init(
        rows: [GaryxMobileTurnRow],
        prefetchBoundaryRowCount: Int = 0,
        sink: GaryxTurnRowCallbackSink = GaryxTurnRowCallbackSink(),
        windowPlan: [GaryxTranscriptWindowPlanner.Segment] = []
    ) {
        self.rows = rows
        self.prefetchBoundaryRowCount = prefetchBoundaryRowCount
        self.sink = sink
        self.windowPlan = windowPlan
    }

    var body: some View {
        // Rows are the single source of truth for WHAT exists; the plan only
        // proposes what collapses. A row the plan does not mention renders
        // live, so a plan computed one frame ago can delay a collapse but can
        // never hide content — the failure mode review #TASK-2707 measured as
        // a 204ms invisible message right after sending.
        ForEach(renderEntries) { entry in
            switch entry.kind {
            case .row(let rowIndex):
                GaryxMobileTurnRowView(
                    row: rows[rowIndex],
                    isWithinHistoryPrefetchBoundary: rowIndex <= prefetchBoundaryRowCount,
                    sink: sink
                )
                .equatable()
            case .spacer(let height):
                Color.clear
                    .frame(height: height)
                    .accessibilityHidden(true)
            }
        }
        .onAppear {
            GaryxRoutePushPerformanceProbe.shared?.markConversationContent(rowCount: rows.count)
        }
        .onChange(of: rows.count) { _, count in
            GaryxRoutePushPerformanceProbe.shared?.markConversationContent(rowCount: count)
        }
    }

    private enum RenderKind {
        case row(rowIndex: Int)
        case spacer(height: CGFloat)
    }

    /// Stable identity per entry: a row keeps its own id so SwiftUI preserves
    /// its state across replans; a spacer is identified by the first row it
    /// folds away.
    private struct RenderEntry: Identifiable {
        let id: String
        let kind: RenderKind
    }

    /// Walk the row list in order, folding only runs the plan collapses.
    private var renderEntries: [RenderEntry] {
        guard !windowPlan.isEmpty else {
            return rows.enumerated().map { index, row in
                RenderEntry(id: row.id, kind: .row(rowIndex: index))
            }
        }
        var collapsedHeightByFirstRowID: [String: CGFloat] = [:]
        var collapsedRowIDs: [String: String] = [:]  // row id -> run's first row id
        for segment in windowPlan {
            guard case .spacer(let height, let ids) = segment, let first = ids.first else {
                continue
            }
            collapsedHeightByFirstRowID[first] = height
            for id in ids {
                collapsedRowIDs[id] = first
            }
        }

        var entries: [RenderEntry] = []
        var emittedRuns: Set<String> = []
        for (index, row) in rows.enumerated() {
            guard let runFirstID = collapsedRowIDs[row.id],
                  let height = collapsedHeightByFirstRowID[runFirstID] else {
                entries.append(RenderEntry(id: row.id, kind: .row(rowIndex: index)))
                continue
            }
            // One spacer per collapsed run, at the position of its first row.
            if emittedRuns.insert(runFirstID).inserted {
                entries.append(
                    RenderEntry(id: "garyx-collapsed-\(runFirstID)", kind: .spacer(height: height))
                )
            }
        }
        return entries
    }
}

/// One turn row. Equality covers everything that can change its rendering;
/// the sink is compared by identity because its handlers are stable for the
/// occupancy's lifetime.
struct GaryxMobileTurnRowView: View, Equatable {
    @Environment(\.garyxMotion) private var motion
    let row: GaryxMobileTurnRow
    let isWithinHistoryPrefetchBoundary: Bool
    let sink: GaryxTurnRowCallbackSink

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row
            && lhs.isWithinHistoryPrefetchBoundary == rhs.isWithinHistoryPrefetchBoundary
            && lhs.sink === rhs.sink
    }

    var body: some View {
        // The row wrapper VStack exists so the whole turn row has ONE
        // geometry to observe. Its spacing matches the transcript stack,
        // so the wrapped layout stays pixel-identical to the previously
        // flattened children.
        VStack(alignment: .leading, spacing: garyxConversationRowSpacing) {
            content
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(garyxConversationContentSpaceName))
        } action: { frame in
            sink.onRowContentGeometryChange(row.id, frame.minY, frame.height)
        }
        .onAppear {
            guard isWithinHistoryPrefetchBoundary else { return }
            sink.onNearHistoryBoundary()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let userBlock = row.userBlock {
            GaryxMobileTranscriptBlockView(block: userBlock)
                .transition(motion.transition(.transcriptAppear))
        }

        ForEach(Array(row.activityRows.enumerated()), id: \.element.id) { _, activityRow in
            GaryxMobileTurnActivityRowView(row: activityRow)
                .transition(motion.transition(.transcriptAppear))
        }

        // Server render_state appends capsule cards after the turn's final
        // answer. Dumb-render only — placement and existence are server-derived.
        if !row.capsuleCards.isEmpty {
            GaryxMobileCapsuleChatCardsView(
                turnId: row.id,
                cards: row.capsuleCards
            )
            .transition(motion.transition(.transcriptAppear))
        }
    }
}

struct GaryxMobileTurnActivityRowView: View {
    let row: GaryxMobileTurnRow.ActivityRow

    var body: some View {
        switch row {
        case .flat(let block):
            GaryxMobileTranscriptBlockView(block: block)
        case .turn(let turn):
            GaryxTurnSummaryView(turn: turn) {
                ForEach(turn.steps) { step in
                    GaryxMobileTranscriptBlockView(block: step)
                }
            }
            if let finalBlock = turn.finalBlock {
                GaryxMobileTranscriptBlockView(block: finalBlock)
            }
        }
    }
}

struct GaryxMobileTranscriptBlockView: View {
    let block: GaryxMobileTranscriptBlock

    var body: some View {
        switch block {
        case .message(let message), .toolGroup(let message):
            GaryxMessageBubble(message: message)
                .id(message.id)
        }
    }
}

struct GaryxTurnSummaryView<Content: View>: View {
    @Environment(\.garyxMotion) private var motion
    let turn: GaryxMobileAgentTurn
    let content: Content

    @State private var expanded: Bool
    @State private var userControlled = false
    @State private var mountStart = Date()

    init(
        turn: GaryxMobileAgentTurn,
        @ViewBuilder content: () -> Content
    ) {
        self.turn = turn
        self.content = content()
        _expanded = State(initialValue: turn.isRunning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                userControlled = true
                withAnimation(motion.animation(.turnDisclosure)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    summaryText
                        .fixedSize(horizontal: true, vertical: false)

                    Rectangle()
                        .fill(GaryxTheme.hairline)
                        .frame(height: 1)

                    Image(systemName: "chevron.down")
                        .font(GaryxFont.fixedSystem(size: 10, weight: .semibold))
                        .foregroundStyle(GaryxTheme.secondaryText)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                        .animation(motion.spatialAnimation(.turnDisclosure), value: expanded)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(GaryxPressableRowStyle())
            .accessibilityLabel(expanded ? "Collapse turn details" : "Expand turn details")

            if expanded && turn.hasBody {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .transition(motion.transition(.turnDisclosure, moveFrom: .top))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: isRunning) { _, isRunning in
            guard !userControlled else { return }
            withAnimation(motion.animation(.turnAutoDisclosure)) {
                expanded = isRunning
            }
        }
    }

    private var isRunning: Bool {
        turn.isRunning
    }

    @ViewBuilder
    private var summaryText: some View {
        if isRunning {
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                GaryxShimmerText(
                    text: summaryLabel(now: context.date),
                    font: GaryxFont.footnote(weight: .medium)
                )
                .garyxReadingLineLimit()
            }
        } else {
            summaryTextLabel(summaryLabel(now: Date()))
        }
    }

    private func summaryTextLabel(_ label: String) -> some View {
        Text(label)
            .font(GaryxFont.footnote(weight: .medium))
            .foregroundStyle(isRunning ? GaryxTheme.accent : GaryxTheme.secondaryText)
            .garyxReadingLineLimit()
    }

    private func summaryLabel(now: Date) -> String {
        let elapsed = elapsedLabel(now: now)
        if isRunning {
            return elapsed.isEmpty ? "Working" : "Working for \(elapsed)"
        }
        return elapsed.isEmpty ? "Worked" : "Worked for \(elapsed)"
    }

    private func elapsedLabel(now: Date) -> String {
        let start = Self.timestamp(from: turn.startedAt)
        if isRunning {
            let start = start ?? mountStart
            return Self.formatElapsed(now.timeIntervalSince(start))
        }
        guard let start, let finished = Self.timestamp(from: turn.finishedAt) else {
            return ""
        }
        return Self.formatElapsed(finished.timeIntervalSince(start))
    }

    private static func timestamp(from value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter.garyxMobileFractional.date(from: value)
            ?? ISO8601DateFormatter.garyxMobileInternet.date(from: value)
    }

    private static func formatElapsed(_ seconds: TimeInterval) -> String {
        let safe = max(0, Int(seconds.rounded()))
        if safe < 60 {
            return "\(safe)s"
        }
        let minutes = safe / 60
        let remainder = safe % 60
        if minutes < 60 {
            return remainder > 0 ? "\(minutes)m \(remainder)s" : "\(minutes)m"
        }
        let hours = minutes / 60
        let restMinutes = minutes % 60
        return restMinutes > 0 ? "\(hours)h \(restMinutes)m" : "\(hours)h"
    }
}

private extension ISO8601DateFormatter {
    static let garyxMobileFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let garyxMobileInternet: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
