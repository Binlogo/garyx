import Foundation
import WidgetKit

// Codex account management + device-code sign-in. Mirrors the Claude Code
// flow in GaryxMobileModel+ProviderAuth.swift, minus the code-submit step:
// polling starts immediately after auth/start and runs until the Codex CLI
// confirms or fails.

extension GaryxMobileModel {
    func loadCodexAccounts(
        runtimeGeneration: GaryxGatewayRequestToken? = nil
    ) async {
        let observedGeneration = runtimeGeneration ?? gatewayRequestToken
        let loadGeneration = UUID()
        codexAccountsLoadGeneration = loadGeneration
        isLoadingCodexAccounts = true
        codexAccountsError = nil
        do {
            let accounts = try await client().codexAccounts()
            guard observedGeneration == gatewayRequestToken,
                  codexAccountsLoadGeneration == loadGeneration else { return }
            codexAccounts = accounts
            isLoadingCodexAccounts = false
        } catch {
            guard !GaryxGatewayRetryClassifier.isCancellation(error),
                  observedGeneration == gatewayRequestToken,
                  codexAccountsLoadGeneration == loadGeneration else { return }
            let message = displayMessage(for: error)
            codexAccountsError = message
            lastError = message
            isLoadingCodexAccounts = false
        }
    }

    @discardableResult
    func selectCodexAccount(
        accountId: String?
    ) async -> GaryxCodexAccountSelection? {
        await mutateCodexAccount { gateway in
            try await gateway.selectCodexAccount(accountId: accountId)
        }
    }

    @discardableResult
    func renameCodexAccount(accountId: String, name: String) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            codexAccountsError = "Enter an account name."
            return false
        }
        return await mutateCodexAccount(refreshesUsage: false) { gateway in
            try await gateway.renameCodexAccount(accountId: accountId, name: trimmedName)
        } != nil
    }

    @discardableResult
    func deleteCodexAccount(accountId: String) async -> Bool {
        await mutateCodexAccount { gateway in
            try await gateway.deleteCodexAccount(accountId: accountId)
        } != nil
    }

    private func mutateCodexAccount<Result>(
        refreshesUsage: Bool = true,
        operation: (GaryxGatewayClient) async throws -> Result
    ) async -> Result? {
        let runtimeGeneration = gatewayRequestToken
        let mutationGeneration = UUID()
        codexAccountMutationGeneration = mutationGeneration
        isMutatingCodexAccount = true
        codexAccountsError = nil
        do {
            let gateway = try client()
            let result = try await operation(gateway)
            guard runtimeGeneration == gatewayRequestToken,
                  codexAccountMutationGeneration == mutationGeneration else { return nil }
            async let accountsRefresh: Void = loadCodexAccounts(runtimeGeneration: runtimeGeneration)
            if refreshesUsage {
                async let usageRefresh: Void = refreshCodingUsageWidget(runtimeGeneration: runtimeGeneration)
                _ = await (accountsRefresh, usageRefresh)
            } else {
                _ = await accountsRefresh
            }
            guard runtimeGeneration == gatewayRequestToken,
                  codexAccountMutationGeneration == mutationGeneration else { return nil }
            isMutatingCodexAccount = false
            return result
        } catch {
            guard !GaryxGatewayRetryClassifier.isCancellation(error),
                  runtimeGeneration == gatewayRequestToken,
                  codexAccountMutationGeneration == mutationGeneration else { return nil }
            let message = displayMessage(for: error)
            codexAccountsError = message
            lastError = message
            isMutatingCodexAccount = false
            return nil
        }
    }

    /// Begins a Codex device-code sign-in. The target selects System default,
    /// reserves a new managed home, or reauthenticates an existing managed
    /// account. Polling starts immediately: the device flow has no submit.
    func startCodexAuth(
        target: GaryxCodexAuthTarget = .systemDefault
    ) async {
        resetCodexAuthFlow()
        let runtimeGeneration = gatewayRequestToken
        let flowGeneration = UUID()
        codexAuthFlowGeneration = flowGeneration
        codexAuthSession = GaryxCodexAuthSession(loginId: "", status: .starting)
        do {
            let gateway = try client()
            let session = try await gateway.startCodexAuth(target.startRequest)
            guard runtimeGeneration == gatewayRequestToken,
                  flowGeneration == codexAuthFlowGeneration else {
                if !session.loginId.isEmpty {
                    _ = try? await gateway.cancelCodexAuth(loginId: session.loginId)
                }
                return
            }
            codexAuthSession = session
            switch session.status {
            case .succeeded:
                await refreshCodexAuthSuccessState(
                    runtimeGeneration: runtimeGeneration,
                    flowGeneration: flowGeneration
                )
            case .failed:
                lastError = session.error
            case .starting, .waitingForAuthorization:
                startCodexAuthPolling(
                    loginId: session.loginId,
                    runtimeGeneration: runtimeGeneration,
                    flowGeneration: flowGeneration
                )
            }
        } catch {
            guard runtimeGeneration == gatewayRequestToken,
                  flowGeneration == codexAuthFlowGeneration else { return }
            let message = displayMessage(for: error)
            codexAuthSession = GaryxCodexAuthSession(
                loginId: "",
                status: .failed,
                error: message
            )
            lastError = message
        }
    }

    func resetCodexAuthFlow() {
        let previousSession = codexAuthSession
        codexAuthFlowGeneration = UUID()
        cancelCodexAuthPolling()
        codexAuthSession = nil
        guard let previousSession,
              !previousSession.loginId.isEmpty,
              let gateway = try? client() else { return }
        Task {
            _ = try? await gateway.cancelCodexAuth(loginId: previousSession.loginId)
        }
    }

    /// A 404 means the gateway no longer knows this login session (in-memory
    /// map, dropped on gateway restart). Surface it as a terminal failure so
    /// the sheet shows an explicit expired screen instead of snapping back.
    private func markCodexAuthSessionExpired() {
        cancelCodexAuthPolling()
        codexAuthSession = GaryxCodexAuthSession(
            loginId: "",
            accountId: codexAuthSession?.accountId,
            status: .failed,
            error: "Your Codex sign-in session expired. Start over to sign in again."
        )
    }

    private func startCodexAuthPolling(
        loginId: String,
        runtimeGeneration: GaryxGatewayRequestToken,
        flowGeneration: UUID
    ) {
        guard !loginId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cancelCodexAuthPolling()
        let pollGeneration = UUID()
        codexAuthPollGeneration = pollGeneration
        codexAuthPollTask = Task { [weak self] in
            guard let self else { return }
            await self.pollCodexAuth(
                loginId: loginId,
                runtimeGeneration: runtimeGeneration,
                flowGeneration: flowGeneration,
                pollGeneration: pollGeneration
            )
        }
    }

    private func pollCodexAuth(
        loginId: String,
        runtimeGeneration: GaryxGatewayRequestToken,
        flowGeneration: UUID,
        pollGeneration: UUID
    ) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
                try Task.checkCancellation()
                let session = try await client().codexAuth(loginId: loginId)
                guard runtimeGeneration == gatewayRequestToken,
                      flowGeneration == codexAuthFlowGeneration,
                      pollGeneration == codexAuthPollGeneration,
                      codexAuthSession?.loginId == loginId else {
                    return
                }
                codexAuthSession = session
                switch session.status {
                case .succeeded:
                    cancelCodexAuthPolling()
                    await refreshCodexAuthSuccessState(
                        runtimeGeneration: runtimeGeneration,
                        flowGeneration: flowGeneration
                    )
                    return
                case .failed:
                    cancelCodexAuthPolling()
                    if let error = session.error {
                        lastError = error
                    }
                    return
                case .starting, .waitingForAuthorization:
                    continue
                }
            } catch {
                guard !GaryxGatewayRetryClassifier.isCancellation(error) else { return }
                guard runtimeGeneration == gatewayRequestToken,
                      flowGeneration == codexAuthFlowGeneration,
                      pollGeneration == codexAuthPollGeneration,
                      codexAuthSession?.loginId == loginId else {
                    return
                }
                if isCodexAuthSessionMissing(error) {
                    markCodexAuthSessionExpired()
                    return
                }
                let message = displayMessage(for: error)
                codexAuthSession = GaryxCodexAuthSession(
                    loginId: loginId,
                    accountId: codexAuthSession?.accountId,
                    status: .failed,
                    url: codexAuthSession?.url,
                    userCode: codexAuthSession?.userCode,
                    error: message
                )
                lastError = message
                cancelCodexAuthPolling()
                return
            }
        }
    }

    private func refreshCodexAuthSuccessState(
        runtimeGeneration: GaryxGatewayRequestToken,
        flowGeneration: UUID
    ) async {
        do {
            let usage = try await client().codingUsage()
            guard runtimeGeneration == gatewayRequestToken,
                  flowGeneration == codexAuthFlowGeneration else { return }
            codingUsage = usage
            GaryxUsageWidgetStore.saveSnapshot(
                GaryxUsageWidgetSnapshot(usage: usage, fetchedAt: Date())
            )
            WidgetCenter.shared.reloadTimelines(ofKind: GaryxCodingUsageWidgetConstants.kind)
        } catch {
            guard runtimeGeneration == gatewayRequestToken,
                  flowGeneration == codexAuthFlowGeneration else { return }
            lastError = displayMessage(for: error)
        }
        await loadCodexAccounts(runtimeGeneration: runtimeGeneration)
    }

    private func cancelCodexAuthPolling() {
        codexAuthPollTask?.cancel()
        codexAuthPollTask = nil
        codexAuthPollGeneration = nil
    }

    private func isCodexAuthSessionMissing(_ error: Error) -> Bool {
        guard case GaryxGatewayError.httpStatus(let status, _, _) = error else {
            return false
        }
        return status == 404
    }
}
