import Foundation

// Codex account + sign-in models. Account selection belongs to the provider;
// the client never receives a home path and never snapshots an account onto a
// thread. Codex login is a device-code flow: the gateway returns a
// verification URL and a one-time user code, the user authorizes from any
// browser, and the client only polls status — there is no code paste-back.

public struct GaryxCodexAccounts: Codable, Equatable, Sendable {
    public var activeAccountId: String?
    public var accounts: [GaryxCodexAccount]
    public var refreshedAt: String

    public init(
        activeAccountId: String? = nil,
        accounts: [GaryxCodexAccount],
        refreshedAt: String
    ) {
        self.activeAccountId = activeAccountId?.trimmingCharacters(in: .whitespacesAndNewlines)
            .garyxGatewayTrimmedNilIfEmpty
        self.accounts = accounts
        self.refreshedAt = refreshedAt
    }

    enum CodingKeys: String, CodingKey {
        case activeAccountId = "active_account_id"
        case accounts
        case refreshedAt = "refreshed_at"
    }

    public var selectedAccount: GaryxCodexAccount? {
        accounts.first(where: \.selected)
    }
}

public struct GaryxCodexAccount: Codable, Equatable, Sendable {
    public var id: String?
    public var name: String
    public var systemDefault: Bool
    public var selected: Bool
    public var email: String?
    public var plan: String?
    public var chatgptAccountId: String?
    public var usage: GaryxProviderUsage

    public init(
        id: String? = nil,
        name: String,
        systemDefault: Bool,
        selected: Bool,
        email: String? = nil,
        plan: String? = nil,
        chatgptAccountId: String? = nil,
        usage: GaryxProviderUsage
    ) {
        self.id = id?.trimmingCharacters(in: .whitespacesAndNewlines).garyxGatewayTrimmedNilIfEmpty
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.systemDefault = systemDefault
        self.selected = selected
        self.email = email?.trimmingCharacters(in: .whitespacesAndNewlines).garyxGatewayTrimmedNilIfEmpty
        self.plan = plan?.trimmingCharacters(in: .whitespacesAndNewlines).garyxGatewayTrimmedNilIfEmpty
        self.chatgptAccountId = chatgptAccountId?.trimmingCharacters(in: .whitespacesAndNewlines)
            .garyxGatewayTrimmedNilIfEmpty
        self.usage = usage
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case systemDefault = "system_default"
        case selected
        case email
        case plan
        case chatgptAccountId = "chatgpt_account_id"
        case usage
    }

    public var stableId: String { id ?? "system-default" }
}

/// Pure account-row projection shared by the Provider overview and account
/// switcher. SwiftUI only composes these values and dispatches actions.
public struct GaryxCodexAccountPresentation: Equatable, Identifiable, Sendable {
    public var id: String
    public var accountId: String?
    public var title: String
    public var detailText: String
    public var planText: String?
    public var systemDefault: Bool
    public var selected: Bool
    public var usage: GaryxProviderUsageDisplayModel?

    public static func make(
        account: GaryxCodexAccount,
        refreshedAt: String?,
        now: Date = Date()
    ) -> GaryxCodexAccountPresentation {
        let detail: String
        if let email = account.email {
            detail = email
        } else if account.systemDefault {
            detail = "This Mac's default Codex login"
        } else {
            detail = "Managed Codex login"
        }
        return GaryxCodexAccountPresentation(
            id: account.stableId,
            accountId: account.id,
            title: account.name,
            detailText: detail,
            planText: account.plan ?? account.usage.plan,
            systemDefault: account.systemDefault,
            selected: account.selected,
            usage: GaryxProviderUsageDisplayModel.make(
                from: account.usage,
                refreshedAt: refreshedAt,
                now: now
            )
        )
    }
}

public struct GaryxCodexAccountSelectionRequest: Encodable, Equatable, Sendable {
    public var accountId: String?

    public init(accountId: String?) {
        self.accountId = accountId?.trimmingCharacters(in: .whitespacesAndNewlines)
            .garyxGatewayTrimmedNilIfEmpty
    }

    enum CodingKeys: String, CodingKey { case accountId = "account_id" }
}

/// Selection result. Unlike Claude there is no session-reconcile document;
/// the quota-recovery summary is the whole payload.
public struct GaryxCodexAccountSelection: Codable, Equatable, Sendable {
    public var activeAccountId: String?
    public var selectionChanged: Bool
    public var recovery: GaryxQuotaRecoverySummary
    public var recoveryWarning: String?

    public init(
        activeAccountId: String? = nil,
        selectionChanged: Bool = true,
        recovery: GaryxQuotaRecoverySummary = GaryxQuotaRecoverySummary(),
        recoveryWarning: String? = nil
    ) {
        self.activeAccountId = activeAccountId
        self.selectionChanged = selectionChanged
        self.recovery = recovery
        self.recoveryWarning = recoveryWarning
    }

    enum CodingKeys: String, CodingKey {
        case activeAccountId = "active_account_id"
        case selectionChanged = "selection_changed"
        case recovery
        case recoveryWarning = "recovery_warning"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeAccountId = try container.decodeIfPresent(String.self, forKey: .activeAccountId)
        selectionChanged = try container.decodeIfPresent(Bool.self, forKey: .selectionChanged) ?? true
        recovery = try container.decodeIfPresent(
            GaryxQuotaRecoverySummary.self,
            forKey: .recovery
        ) ?? GaryxQuotaRecoverySummary()
        recoveryWarning = try container.decodeIfPresent(String.self, forKey: .recoveryWarning)
    }
}

public struct GaryxCodexAccountRenameRequest: Encodable, Equatable, Sendable {
    public var name: String

    public init(name: String) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum GaryxCodexAuthTarget: Equatable, Sendable {
    case systemDefault
    case newManagedAccount(name: String)
    case managedAccount(id: String, name: String)

    public var displayName: String {
        switch self {
        case .systemDefault:
            return "System default"
        case .newManagedAccount(let name), .managedAccount(_, let name):
            return name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public var accountId: String? {
        guard case .managedAccount(let id, _) = self else { return nil }
        return id.trimmingCharacters(in: .whitespacesAndNewlines).garyxGatewayTrimmedNilIfEmpty
    }

    public var managedAccountName: String? {
        guard case .newManagedAccount(let name) = self else { return nil }
        return name.trimmingCharacters(in: .whitespacesAndNewlines).garyxGatewayTrimmedNilIfEmpty
    }

    /// The wire request for this target. Codex has no mode/sso/email options.
    public var startRequest: GaryxCodexAuthStartRequest {
        GaryxCodexAuthStartRequest(
            managedAccountName: managedAccountName,
            accountId: accountId
        )
    }
}

public enum GaryxCodexAuthStatus: String, Codable, Equatable, Sendable {
    case starting
    case waitingForAuthorization = "waiting_for_authorization"
    case succeeded
    case failed

    public var isTerminal: Bool {
        self == .succeeded || self == .failed
    }
}

public struct GaryxCodexAuthStartRequest: Encodable, Equatable, Sendable {
    public var managedAccountName: String?
    public var accountId: String?

    public init(
        managedAccountName: String? = nil,
        accountId: String? = nil
    ) {
        self.managedAccountName = managedAccountName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .garyxGatewayTrimmedNilIfEmpty
        self.accountId = accountId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .garyxGatewayTrimmedNilIfEmpty
    }

    enum CodingKeys: String, CodingKey {
        case managedAccountName = "managed_account_name"
        case accountId = "account_id"
    }
}

public struct GaryxCodexAuthSession: Codable, Equatable, Sendable {
    public var loginId: String
    public var accountId: String?
    public var status: GaryxCodexAuthStatus
    public var url: String?
    public var userCode: String?
    public var identity: GaryxJSONValue?
    public var error: String?
    public var exitCode: Int?

    public init(
        loginId: String,
        accountId: String? = nil,
        status: GaryxCodexAuthStatus,
        url: String? = nil,
        userCode: String? = nil,
        identity: GaryxJSONValue? = nil,
        error: String? = nil,
        exitCode: Int? = nil
    ) {
        self.loginId = loginId
        self.accountId = accountId?.trimmingCharacters(in: .whitespacesAndNewlines)
            .garyxGatewayTrimmedNilIfEmpty
        self.status = status
        self.url = url?.trimmingCharacters(in: .whitespacesAndNewlines).garyxGatewayTrimmedNilIfEmpty
        self.userCode = userCode?.trimmingCharacters(in: .whitespacesAndNewlines)
            .garyxGatewayTrimmedNilIfEmpty
        self.identity = identity
        self.error = error?.trimmingCharacters(in: .whitespacesAndNewlines).garyxGatewayTrimmedNilIfEmpty
        self.exitCode = exitCode
    }

    enum CodingKeys: String, CodingKey {
        case loginId = "login_id"
        case accountId = "account_id"
        case status
        case url
        case userCode = "user_code"
        case identity
        case error
        case exitCode = "exit_code"
    }

    public var authorizationURL: URL? {
        guard let url else { return nil }
        return URL(string: url)
    }

    /// Signed-in identity decoded by the gateway from the login credentials.
    public var identityEmail: String? {
        identityString(forKeys: ["email"])
    }

    public var identityPlan: String? {
        identityString(forKeys: ["plan"])
    }

    private func identityString(forKeys keys: [String]) -> String? {
        guard case .object(let object)? = identity?.garyxGatewayJSONStringDecodedIfNeeded else {
            return nil
        }
        return object.garyxGatewayStringValue(forKeys: keys)
    }
}

// MARK: - Guided device-code login sheet

/// One screen of the Codex login sheet. The device flow has no code-entry
/// step: `waiting_for_authorization` renders the URL + one-time code and
/// polls until the CLI confirms.
public enum GaryxCodexLoginStep: Equatable, Sendable {
    case intro
    case authorize
    case success
    case failure
}

public enum GaryxCodexLoginActionKind: Equatable, Sendable {
    /// Begin (or restart) a login: POST auth/start for the chosen target.
    case start
    /// Open the verification URL in the browser.
    case openAuthorizationURL
    /// Copy the one-time code to the pasteboard.
    case copyUserCode
    /// Dismiss the sheet after a successful sign-in.
    case done
    /// Discard the current login session and return to the intro screen.
    case startOver
}

public struct GaryxCodexLoginAction: Equatable, Sendable {
    public var kind: GaryxCodexLoginActionKind
    public var title: String
    public var isEnabled: Bool

    public init(
        _ kind: GaryxCodexLoginActionKind,
        title: String,
        isEnabled: Bool = true
    ) {
        self.kind = kind
        self.title = title
        self.isEnabled = isEnabled
    }
}

/// A labelled account attribute shown on the success screen.
public struct GaryxCodexLoginDetailRow: Equatable, Sendable, Identifiable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    public var id: String { label }
}

public struct GaryxCodexLoginPresentation: Equatable, Sendable {
    public var step: GaryxCodexLoginStep
    public var symbolName: String
    public var title: String
    public var message: String?
    public var tone: GaryxClaudeCodeAuthPresentationTone
    public var showsProgress: Bool
    /// The one-time device code to display prominently, when available.
    public var userCode: String?
    public var detailRows: [GaryxCodexLoginDetailRow]
    public var primaryAction: GaryxCodexLoginAction?
    public var secondaryAction: GaryxCodexLoginAction?

    public init(
        step: GaryxCodexLoginStep,
        symbolName: String,
        title: String,
        message: String? = nil,
        tone: GaryxClaudeCodeAuthPresentationTone,
        showsProgress: Bool = false,
        userCode: String? = nil,
        detailRows: [GaryxCodexLoginDetailRow] = [],
        primaryAction: GaryxCodexLoginAction? = nil,
        secondaryAction: GaryxCodexLoginAction? = nil
    ) {
        self.step = step
        self.symbolName = symbolName
        self.title = title
        self.message = message?.trimmingCharacters(in: .whitespacesAndNewlines).garyxGatewayTrimmedNilIfEmpty
        self.tone = tone
        self.showsProgress = showsProgress
        self.userCode = userCode
        self.detailRows = detailRows
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
    }

    public static func step(for status: GaryxCodexAuthStatus?) -> GaryxCodexLoginStep {
        switch status {
        case .none:
            return .intro
        case .starting, .waitingForAuthorization:
            return .authorize
        case .succeeded:
            return .success
        case .failed:
            return .failure
        }
    }

    public static func make(
        session: GaryxCodexAuthSession?
    ) -> GaryxCodexLoginPresentation {
        let step = step(for: session?.status)
        switch step {
        case .intro:
            return GaryxCodexLoginPresentation(
                step: .intro,
                symbolName: "sparkles",
                title: "Sign in to Codex",
                message: "Garyx shows a one-time code. Enter it on the ChatGPT device page to finish signing in.",
                tone: .muted,
                primaryAction: GaryxCodexLoginAction(.start, title: "Sign in with ChatGPT")
            )

        case .authorize:
            let ready = session?.userCode != nil && session?.authorizationURL != nil
            return GaryxCodexLoginPresentation(
                step: .authorize,
                symbolName: "circle.grid.3x3",
                title: ready ? "Enter Code in Browser" : "Preparing Sign-In",
                message: ready
                    ? "Open the verification page, enter this code, and approve access. This screen finishes automatically."
                    : "Requesting your device code…",
                tone: .muted,
                showsProgress: true,
                userCode: session?.userCode,
                primaryAction: GaryxCodexLoginAction(
                    .openAuthorizationURL,
                    title: ready ? "Open Verification Page" : "Preparing…",
                    isEnabled: ready
                ),
                secondaryAction: ready
                    ? GaryxCodexLoginAction(.copyUserCode, title: "Copy Code")
                    : nil
            )

        case .success:
            return GaryxCodexLoginPresentation(
                step: .success,
                symbolName: "checkmark.circle.fill",
                title: "Signed In",
                message: "You're signed in and ready to use Codex.",
                tone: .good,
                detailRows: successRows(session: session),
                primaryAction: GaryxCodexLoginAction(.done, title: "Done")
            )

        case .failure:
            return GaryxCodexLoginPresentation(
                step: .failure,
                symbolName: "exclamationmark.triangle.fill",
                title: "Sign-In Failed",
                message: session?.error ?? "Codex sign-in didn't complete. Please try again.",
                tone: .danger,
                primaryAction: GaryxCodexLoginAction(.start, title: "Try Again"),
                secondaryAction: GaryxCodexLoginAction(.startOver, title: "Start Over")
            )
        }
    }

    private static func successRows(session: GaryxCodexAuthSession?) -> [GaryxCodexLoginDetailRow] {
        var rows: [GaryxCodexLoginDetailRow] = []
        rows.append(
            GaryxCodexLoginDetailRow(
                label: "Account",
                value: session?.identityEmail ?? "Codex account"
            )
        )
        if let plan = session?.identityPlan {
            rows.append(GaryxCodexLoginDetailRow(label: "Plan", value: plan))
        }
        return rows
    }
}
