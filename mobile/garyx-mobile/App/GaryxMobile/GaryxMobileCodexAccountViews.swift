import Foundation
import SwiftUI

// Codex account management surfaces: the accounts sheet, per-account rows
// with quota, the account detail page, and the add/rename flows. Structurally
// identical to the Claude Code account surfaces; the sign-in sheet itself is
// the device-code flow in GaryxMobileCodexAuthViews.swift.

struct GaryxCodexAccountFlow: Identifiable {
    enum Kind {
        case add
        case login(GaryxCodexAuthTarget)
    }

    let id = UUID()
    let kind: Kind
}

struct GaryxCodexAccountsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: GaryxMobileModel
    @State private var accountFlow: GaryxCodexAccountFlow?
    var selectionOnly = false
    var onSelection: ((GaryxCodexAccountSelection) -> Void)?

    var body: some View {
        NavigationStack {
            List {
                if let error = model.codexAccountsError {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error)
                                .font(GaryxFont.callout())
                                .foregroundStyle(GaryxTheme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Try Again") {
                                Task { await model.loadCodexAccounts() }
                            }
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                        }
                        .padding(.vertical, 3)
                    }
                }

                Section {
                    if accountRows.isEmpty, model.isLoadingCodexAccounts {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Loading accounts…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(accountRows) { account in
                            if selectionOnly {
                                Button {
                                    selectImmediately(account)
                                } label: {
                                    GaryxCodexAccountRow(account: account)
                                }
                                .buttonStyle(.plain)
                                .disabled(model.isMutatingCodexAccount)
                            } else {
                                NavigationLink {
                                    GaryxCodexAccountDetailView(accountStableId: account.id)
                                } label: {
                                    GaryxCodexAccountRow(account: account)
                                }
                                .disabled(model.isMutatingCodexAccount)
                            }
                        }
                    }
                } header: {
                    Text("Codex accounts")
                        .textCase(nil)
                } footer: {
                    Text(selectionOnly
                         ? "Choosing an account resumes every Codex thread paused by quota. Active runs continue unchanged."
                         : "The selected account applies to new and restarted Codex runs. Active runs continue unchanged.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(selectionOnly ? "Switch account" : "Codex")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await model.loadCodexAccounts()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .primaryAction) {
                    if !selectionOnly {
                        Button {
                            accountFlow = GaryxCodexAccountFlow(kind: .add)
                        } label: {
                            Image(systemName: "plus")
                                .foregroundStyle(.primary)
                        }
                        .disabled(model.isMutatingCodexAccount)
                        .accessibilityLabel("Add Codex account")
                    }
                }
            }
        }
        .tint(GaryxTheme.controlTint)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .garyxFullScreenCover(item: $accountFlow, onDismiss: refreshAfterAccountFlow) { flow in
            switch flow.kind {
            case .add:
                GaryxCodexAddAccountFlow()
            case .login(let target):
                GaryxCodexLoginSheet(target: target)
            }
        }
        .task {
            if model.codexAccounts == nil {
                await model.loadCodexAccounts()
            }
        }
    }

    private var accountRows: [GaryxCodexAccountPresentation] {
        guard let accounts = model.codexAccounts else { return [] }
        return accounts.accounts.map {
            GaryxCodexAccountPresentation.make(
                account: $0,
                refreshedAt: accounts.refreshedAt
            )
        }
    }

    private func refreshAfterAccountFlow() {
        Task {
            await model.loadCodexAccounts()
            await model.refreshCodingUsageWidget()
        }
    }

    private func selectImmediately(_ account: GaryxCodexAccountPresentation) {
        guard !account.selected, !model.isMutatingCodexAccount else { return }
        Task {
            if let result = await model.selectCodexAccount(accountId: account.accountId) {
                onSelection?(result)
                dismiss()
            }
        }
    }
}

private struct GaryxCodexAccountRow: View {
    let account: GaryxCodexAccountPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if account.selected {
                        GaryxSelectionCheckmark(style: .circle, size: 17)
                    } else {
                        Color.clear.frame(width: 17, height: 17)
                    }
                }
                .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(account.title)
                            .font(GaryxFont.subheadline(weight: .semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let plan = account.planText {
                            Text(plan)
                                .font(GaryxFont.caption(weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(account.detailText)
                        .font(GaryxFont.caption())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            accountQuota
                .padding(.leading, 30)
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var accountQuota: some View {
        if let usage = account.usage, usage.available, !usage.windows.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(usage.windows) { window in
                    GaryxProviderQuotaConsoleRow(window: window, horizontalPadding: 0)
                }
            }
            .opacity(usage.stale ? 0.55 : 1)
        } else {
            Text(account.usage?.summaryText ?? "No quota data")
                .font(GaryxFont.caption())
                .foregroundStyle(.tertiary)
        }
    }

    private var accessibilityLabel: String {
        let state = account.selected ? "selected" : "not selected"
        return "\(account.title), \(account.detailText), \(state)"
    }
}

private struct GaryxCodexAccountDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: GaryxMobileModel
    let accountStableId: String

    @State private var accountFlow: GaryxCodexAccountFlow?
    @State private var renameAccount: GaryxCodexAccountPresentation?
    @State private var deleteAccount: GaryxCodexAccountPresentation?

    var body: some View {
        Group {
            if let account {
                List {
                    identitySection(account)
                    quotaSection(account)
                    if let error = model.codexAccountsError {
                        accountErrorSection(error)
                    }
                    actionsSection(account)
                    if !account.systemDefault {
                        deleteSection(account)
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await model.loadCodexAccounts()
                }
            } else if model.isLoadingCodexAccounts {
                ProgressView("Loading account…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Account Unavailable",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("This Codex account may have been removed.")
                )
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .tint(GaryxTheme.controlTint)
        .garyxFullScreenCover(item: $accountFlow, onDismiss: refreshAfterAuthentication) { flow in
            switch flow.kind {
            case .add:
                GaryxCodexAddAccountFlow()
            case .login(let target):
                GaryxCodexLoginSheet(target: target)
            }
        }
        .garyxSheet(item: $renameAccount) { account in
            GaryxCodexRenameAccountSheet(account: account)
        }
        .garyxAlert(item: $deleteAccount) { account in
            Alert(
                title: Text("Delete \(account.title)?"),
                message: Text("Garyx will remove this managed Codex login. Shared Codex config and sessions stay in place, active runs continue, and future runs use System default if this account is selected."),
                primaryButton: .destructive(Text("Delete")) {
                    delete(account)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func accountErrorSection(_ error: String) -> some View {
        Section {
            Label {
                Text(error)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.circle")
            }
            .font(GaryxFont.callout())
            .foregroundStyle(GaryxTheme.danger)

            Button("Refresh Accounts") {
                Task { await model.loadCodexAccounts() }
            }
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
        }
    }

    private func identitySection(_ account: GaryxCodexAccountPresentation) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(account.title)
                        .font(GaryxFont.headline())
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let plan = account.planText {
                        Text(plan)
                            .font(GaryxFont.subheadline(weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(account.detailText)
                    .font(GaryxFont.subheadline())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if account.selected {
                    Label("Current account", systemImage: "checkmark.circle.fill")
                        .font(GaryxFont.caption(weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.top, 3)
                }
            }
            .padding(.vertical, 5)
        }
    }

    @ViewBuilder
    private func quotaSection(_ account: GaryxCodexAccountPresentation) -> some View {
        Section {
            if let usage = account.usage, usage.available, !usage.windows.isEmpty {
                ForEach(usage.windows) { window in
                    GaryxProviderQuotaConsoleRow(window: window, horizontalPadding: 0)
                        .listRowInsets(
                            EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
                        )
                }
                .opacity(usage.stale ? 0.55 : 1)
            } else {
                Text(account.usage?.summaryText ?? "No quota data")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Quota")
                .textCase(nil)
        }
    }

    private func actionsSection(_ account: GaryxCodexAccountPresentation) -> some View {
        Section {
            if !account.selected {
                Button {
                    select(account)
                } label: {
                    Label("Use This Account", systemImage: "checkmark.circle")
                }
                .disabled(model.isMutatingCodexAccount)
            }

            Button {
                reauthenticate(account)
            } label: {
                Label("Re-authenticate", systemImage: "arrow.triangle.2.circlepath")
            }

            if !account.systemDefault {
                Button {
                    renameAccount = account
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
        }
        .foregroundStyle(.primary)
    }

    private func deleteSection(_ account: GaryxCodexAccountPresentation) -> some View {
        Section {
            Button(role: .destructive) {
                deleteAccount = account
            } label: {
                Label("Delete Account", systemImage: "trash")
            }
            .disabled(model.isMutatingCodexAccount)
        }
    }

    private var account: GaryxCodexAccountPresentation? {
        guard let accounts = model.codexAccounts,
              let account = accounts.accounts.first(where: { $0.stableId == accountStableId })
        else { return nil }
        return GaryxCodexAccountPresentation.make(
            account: account,
            refreshedAt: accounts.refreshedAt
        )
    }

    private func select(_ account: GaryxCodexAccountPresentation) {
        guard !account.selected, !model.isMutatingCodexAccount else { return }
        Task {
            if await model.selectCodexAccount(accountId: account.accountId) != nil {
                dismiss()
            }
        }
    }

    private func reauthenticate(_ account: GaryxCodexAccountPresentation) {
        let target: GaryxCodexAuthTarget
        if let accountId = account.accountId {
            target = .managedAccount(id: accountId, name: account.title)
        } else {
            target = .systemDefault
        }
        accountFlow = GaryxCodexAccountFlow(kind: .login(target))
    }

    private func delete(_ account: GaryxCodexAccountPresentation) {
        guard let accountId = account.accountId else { return }
        Task {
            if await model.deleteCodexAccount(accountId: accountId) {
                dismiss()
            }
        }
    }

    private func refreshAfterAuthentication() {
        Task {
            await model.loadCodexAccounts()
            await model.refreshCodingUsageWidget()
        }
    }
}

private struct GaryxCodexAddAccountFlow: View {
    @Environment(\.dismiss) private var dismiss
    @State private var accountName = ""
    @State private var loginTarget: GaryxCodexAuthTarget?
    @FocusState private var nameFocused: Bool

    var body: some View {
        Group {
            if let loginTarget {
                GaryxCodexLoginSheet(target: loginTarget)
            } else {
                GaryxFormSheet(
                    title: "Add Codex Account",
                    canSave: canContinue,
                    saveTitle: "Continue",
                    onCancel: { dismiss() },
                    onSave: continueToLogin
                ) {
                    Section {
                        TextField("Account name", text: $accountName)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .focused($nameFocused)
                            .submitLabel(.continue)
                            .onSubmit {
                                if canContinue { continueToLogin() }
                            }
                    } header: {
                        Text("Name")
                            .textCase(nil)
                    } footer: {
                        Text("Use a short name such as Work or Personal. Garyx keeps this login isolated from System default.")
                    }
                }
                .onAppear { nameFocused = true }
            }
        }
    }

    private var trimmedName: String {
        accountName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canContinue: Bool { !trimmedName.isEmpty }

    private func continueToLogin() {
        guard canContinue else { return }
        nameFocused = false
        loginTarget = .newManagedAccount(name: trimmedName)
    }
}

private struct GaryxCodexRenameAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: GaryxMobileModel
    let account: GaryxCodexAccountPresentation
    @State private var name: String
    @State private var isSaving = false
    @FocusState private var nameFocused: Bool

    init(account: GaryxCodexAccountPresentation) {
        self.account = account
        _name = State(initialValue: account.title)
    }

    var body: some View {
        GaryxFormSheet(
            title: "Rename Account",
            canSave: canSave,
            isSaving: isSaving,
            onSave: save
        ) {
            if let error = model.codexAccountsError {
                Section {
                    Label {
                        Text(error)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                    }
                    .font(GaryxFont.callout())
                    .foregroundStyle(GaryxTheme.danger)
                }
            }

            Section {
                TextField("Account name", text: $name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit {
                        if canSave { save() }
                    }
            } header: {
                Text("Name")
                    .textCase(nil)
            }
        }
        .onAppear { nameFocused = true }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !isSaving && !trimmedName.isEmpty && trimmedName != account.title
    }

    private func save() {
        guard canSave, let accountId = account.accountId else { return }
        isSaving = true
        Task {
            let didSave = await model.renameCodexAccount(accountId: accountId, name: trimmedName)
            isSaving = false
            if didSave { dismiss() }
        }
    }
}
