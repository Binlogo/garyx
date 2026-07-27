import Foundation
import SwiftUI
import UIKit

// Codex device-code sign-in UI. The sheet is driven entirely by the Core
// `GaryxCodexLoginPresentation`; unlike Claude there is no code entry — the
// authorize step displays the verification URL and one-time code while the
// model polls the gateway until the Codex CLI confirms.

struct GaryxCodexLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.garyxMotion) private var motion
    @EnvironmentObject private var model: GaryxMobileModel
    let target: GaryxCodexAuthTarget

    @State private var codeCopied = false

    init(target: GaryxCodexAuthTarget = .systemDefault) {
        self.target = target
    }

    private var presentation: GaryxCodexLoginPresentation {
        GaryxCodexLoginPresentation.make(session: model.codexAuthSession)
    }

    var body: some View {
        VStack(spacing: 0) {
            closeBar
            ScrollView {
                VStack(spacing: 20) {
                    hero
                    if let message = presentation.message {
                        Text(message)
                            .font(GaryxFont.callout())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    stepContent
                }
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(Color(.systemBackground))
        .animation(motion.animation(.authenticationStep), value: presentation.step)
        .onChange(of: model.codexAuthSession?.loginId) { _, _ in
            codeCopied = false
        }
        .onDisappear {
            // Dismissal invalidates stale completions and cancels the Gateway
            // session so a pending device-auth CLI or uncommitted managed home
            // cannot linger.
            model.resetCodexAuthFlow()
        }
    }

    // MARK: Chrome

    private var closeBar: some View {
        HStack {
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                GaryxCompactGlassIcon(systemName: "xmark")
            }
            .buttonStyle(GaryxPressableRowStyle())
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    private var background: some View {
        ZStack {
            Color(.systemBackground)
            RadialGradient(
                colors: [toneColor.opacity(0.12), .clear],
                center: .init(x: 0.5, y: 0.08),
                startRadius: 0,
                endRadius: 340
            )
        }
        .ignoresSafeArea()
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 18) {
            heroBadge
            Text(presentation.title)
                .font(GaryxFont.title(weight: .bold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(target.displayName)
                .font(GaryxFont.subheadline(weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 16)
    }

    private var heroBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(toneColor.opacity(presentation.tone == .muted ? 0.10 : 0.14))
                .frame(width: 92, height: 92)
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(toneColor.opacity(0.16), lineWidth: 1)
                }
            Image(systemName: presentation.symbolName)
                .font(GaryxFont.fixedSystem(size: 38, weight: .semibold))
                .foregroundStyle(toneColor)
                .symbolRenderingMode(.hierarchical)
        }
    }

    // MARK: Per-step content

    @ViewBuilder
    private var stepContent: some View {
        switch presentation.step {
        case .intro, .failure:
            EmptyView()
        case .authorize:
            VStack(spacing: 14) {
                if let userCode = presentation.userCode {
                    deviceCodeCard(userCode)
                }
                if presentation.showsProgress {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(presentation.userCode == nil
                             ? "Requesting device code…"
                             : "Waiting for authorization…")
                            .font(GaryxFont.caption())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        case .success:
            detailCard
        }
    }

    /// The one-time code is the artifact the user carries to the browser, so
    /// it reads as a large monospaced token with a one-tap copy.
    private func deviceCodeCard(_ userCode: String) -> some View {
        Button(action: copyUserCode) {
            VStack(spacing: 6) {
                Text(userCode)
                    .font(GaryxFont.fixedSystem(size: 30, weight: .semibold).monospaced())
                    .kerning(2)
                    .foregroundStyle(.primary)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Label(codeCopied ? "Copied" : "Tap to copy", systemImage: codeCopied ? "checkmark" : "doc.on.doc")
                    .font(GaryxFont.caption(weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .padding(.horizontal, 16)
            .background(
                Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(GaryxTheme.hairline, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(GaryxPressableRowStyle())
        .accessibilityLabel("One-time code \(userCode). Tap to copy.")
    }

    private var detailCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(presentation.detailRows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Divider().padding(.leading, 16)
                }
                HStack(spacing: 12) {
                    Text(row.label)
                        .font(GaryxFont.body())
                        .foregroundStyle(.primary)
                    Spacer(minLength: 12)
                    Text(row.value)
                        .font(GaryxFont.body())
                        .foregroundStyle(.secondary)
                        .garyxReadingLineLimit()
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
            }
        }
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .padding(.top, 4)
    }

    // MARK: Bottom actions

    @ViewBuilder
    private var actionBar: some View {
        if presentation.primaryAction != nil || presentation.secondaryAction != nil {
            VStack(spacing: 8) {
                if let primary = presentation.primaryAction {
                    GaryxPrimaryCapsuleButton(
                        title: primary.title,
                        systemImage: primaryIcon
                    ) {
                        runAction(primary)
                    }
                    .disabled(!primary.isEnabled)
                    .opacity(primary.isEnabled ? 1 : 0.45)
                }
                if let secondary = presentation.secondaryAction {
                    Button {
                        runAction(secondary)
                    } label: {
                        Text(secondary.title)
                            .font(GaryxFont.subheadline(weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(GaryxPressableRowStyle())
                    .foregroundStyle(secondary.kind == .startOver ? GaryxTheme.danger : .primary)
                    .disabled(!secondary.isEnabled)
                    .opacity(secondary.isEnabled ? 1 : 0.45)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 14)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Actions

    private func runAction(_ action: GaryxCodexLoginAction) {
        guard action.isEnabled else { return }
        switch action.kind {
        case .start:
            codeCopied = false
            Task { await model.startCodexAuth(target: target) }
        case .openAuthorizationURL:
            if let url = model.codexAuthSession?.authorizationURL {
                openURL(url)
            }
        case .copyUserCode:
            copyUserCode()
        case .done:
            dismiss()
        case .startOver:
            model.resetCodexAuthFlow()
            codeCopied = false
        }
    }

    private func copyUserCode() {
        guard let userCode = model.codexAuthSession?.userCode else { return }
        UIPasteboard.general.string = userCode
        codeCopied = true
    }

    private var primaryIcon: String? {
        guard let kind = presentation.primaryAction?.kind else { return nil }
        switch kind {
        case .start:
            return presentation.step == .failure ? "arrow.clockwise" : "sparkles"
        case .openAuthorizationURL:
            return "safari"
        case .copyUserCode:
            return "doc.on.doc"
        case .done:
            return "checkmark"
        case .startOver:
            return "arrow.counterclockwise"
        }
    }

    private var toneColor: Color {
        presentation.tone.garyxAuthToneColor
    }
}
