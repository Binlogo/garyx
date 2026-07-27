import XCTest
@testable import GaryxMobileCore

final class GaryxCodexAuthTests: XCTestCase {
    func testAccountsDecodeGatewaySnakeCase() throws {
        let accounts = try JSONDecoder().decode(
            GaryxCodexAccounts.self,
            from: Data(
                """
                {
                  "active_account_id": "11111111-2222-4333-8444-555555555555",
                  "accounts": [
                    {
                      "id": null,
                      "name": "System default",
                      "system_default": true,
                      "selected": false,
                      "usage": {"id": "codex", "name": "Codex", "available": false}
                    },
                    {
                      "id": "11111111-2222-4333-8444-555555555555",
                      "name": "Work",
                      "system_default": false,
                      "selected": true,
                      "email": "bot@example.com",
                      "plan": "pro",
                      "chatgpt_account_id": "00000000-0000-4000-8000-000000000001",
                      "usage": {"id": "codex", "name": "Codex", "available": true, "plan": "pro"}
                    }
                  ],
                  "refreshed_at": "2026-07-26T12:00:00Z"
                }
                """.utf8
            )
        )

        XCTAssertEqual(accounts.accounts.count, 2)
        let selected = try XCTUnwrap(accounts.selectedAccount)
        XCTAssertEqual(selected.name, "Work")
        XCTAssertEqual(selected.email, "bot@example.com")
        XCTAssertEqual(selected.plan, "pro")
        XCTAssertEqual(selected.chatgptAccountId, "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(accounts.accounts[0].stableId, "system-default")
        XCTAssertTrue(accounts.accounts[0].systemDefault)
    }

    func testAccountSelectionDecodesRecoverySummaryAndLegacyDefaults() throws {
        let selection = try JSONDecoder().decode(
            GaryxCodexAccountSelection.self,
            from: Data(
                """
                {
                  "active_account_id": "managed-test",
                  "selection_changed": true,
                  "recovery": {
                    "matched_threads": 2,
                    "expedited_threads": 2,
                    "already_claimed_threads": 0
                  }
                }
                """.utf8
            )
        )
        XCTAssertEqual(selection.activeAccountId, "managed-test")
        XCTAssertTrue(selection.selectionChanged)
        XCTAssertEqual(selection.recovery.matchedThreads, 2)

        let legacy = try JSONDecoder().decode(
            GaryxCodexAccountSelection.self,
            from: Data(#"{"active_account_id":null}"#.utf8)
        )
        XCTAssertTrue(legacy.selectionChanged)
        XCTAssertEqual(legacy.recovery, GaryxQuotaRecoverySummary())
    }

    func testAuthSessionDecodesDeviceCodeFields() throws {
        let session = try JSONDecoder().decode(
            GaryxCodexAuthSession.self,
            from: Data(
                """
                {
                  "login_id": "login-test",
                  "account_id": "managed-test",
                  "status": "waiting_for_authorization",
                  "url": "https://auth.openai.com/codex/device",
                  "user_code": "TEST1-CODE9",
                  "error": null,
                  "exit_code": null
                }
                """.utf8
            )
        )

        XCTAssertEqual(session.loginId, "login-test")
        XCTAssertEqual(session.status, .waitingForAuthorization)
        XCTAssertFalse(session.status.isTerminal)
        XCTAssertEqual(session.userCode, "TEST1-CODE9")
        XCTAssertEqual(
            session.authorizationURL?.absoluteString,
            "https://auth.openai.com/codex/device"
        )
    }

    func testAuthSessionDecodesIdentityOnSuccess() throws {
        let session = try JSONDecoder().decode(
            GaryxCodexAuthSession.self,
            from: Data(
                """
                {
                  "login_id": "login-test",
                  "status": "succeeded",
                  "url": null,
                  "user_code": null,
                  "identity": {
                    "email": "bot@example.com",
                    "plan": "pro",
                    "chatgpt_account_id": "00000000-0000-4000-8000-000000000001"
                  },
                  "error": null,
                  "exit_code": 0
                }
                """.utf8
            )
        )

        XCTAssertEqual(session.status, .succeeded)
        XCTAssertTrue(session.status.isTerminal)
        XCTAssertEqual(session.identityEmail, "bot@example.com")
        XCTAssertEqual(session.identityPlan, "pro")
    }

    // MARK: Target encoding

    func testSystemDefaultTargetEncodesBareRequest() throws {
        let data = try JSONEncoder().encode(GaryxCodexAuthTarget.systemDefault.startRequest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["managed_account_name"] ?? nil)
        XCTAssertNil(object["account_id"] ?? nil)
    }

    func testNewManagedTargetEncodesNameOnly() throws {
        let target = GaryxCodexAuthTarget.newManagedAccount(name: "  Work  ")
        let data = try JSONEncoder().encode(target.startRequest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["managed_account_name"] as? String, "Work")
        XCTAssertNil(object["account_id"] ?? nil)
        XCTAssertEqual(target.displayName, "Work")
    }

    func testManagedTargetEncodesAccountIdOnly() throws {
        let target = GaryxCodexAuthTarget.managedAccount(id: "managed-test", name: "Work")
        let data = try JSONEncoder().encode(target.startRequest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["account_id"] as? String, "managed-test")
        XCTAssertNil(object["managed_account_name"] ?? nil)
    }

    // MARK: Presentation

    func testAccountPresentationPrefersEmailThenSystemDefaultCopy() {
        let managed = GaryxCodexAccountPresentation.make(
            account: GaryxCodexAccount(
                id: "managed-test",
                name: "Work",
                systemDefault: false,
                selected: true,
                email: "bot@example.com",
                plan: "pro",
                usage: GaryxProviderUsage(id: "codex", name: "Codex", available: true)
            ),
            refreshedAt: nil
        )
        XCTAssertEqual(managed.detailText, "bot@example.com")
        XCTAssertEqual(managed.planText, "pro")
        XCTAssertTrue(managed.selected)

        let system = GaryxCodexAccountPresentation.make(
            account: GaryxCodexAccount(
                name: "System default",
                systemDefault: true,
                selected: false,
                usage: GaryxProviderUsage(id: "codex", name: "Codex", available: false)
            ),
            refreshedAt: nil
        )
        XCTAssertEqual(system.detailText, "This Mac's default Codex login")
        XCTAssertEqual(system.id, "system-default")
    }

    func testLoginPresentationStepsForDeviceFlow() {
        XCTAssertEqual(GaryxCodexLoginPresentation.step(for: nil), .intro)
        XCTAssertEqual(GaryxCodexLoginPresentation.step(for: .starting), .authorize)
        XCTAssertEqual(GaryxCodexLoginPresentation.step(for: .waitingForAuthorization), .authorize)
        XCTAssertEqual(GaryxCodexLoginPresentation.step(for: .succeeded), .success)
        XCTAssertEqual(GaryxCodexLoginPresentation.step(for: .failed), .failure)

        let waiting = GaryxCodexLoginPresentation.make(
            session: GaryxCodexAuthSession(
                loginId: "login-test",
                status: .waitingForAuthorization,
                url: "https://auth.openai.com/codex/device",
                userCode: "TEST1-CODE9"
            )
        )
        XCTAssertEqual(waiting.step, .authorize)
        XCTAssertEqual(waiting.userCode, "TEST1-CODE9")
        XCTAssertTrue(waiting.showsProgress)
        XCTAssertEqual(waiting.primaryAction?.kind, .openAuthorizationURL)
        XCTAssertTrue(waiting.primaryAction?.isEnabled == true)
        XCTAssertEqual(waiting.secondaryAction?.kind, .copyUserCode)

        let preparing = GaryxCodexLoginPresentation.make(
            session: GaryxCodexAuthSession(loginId: "login-test", status: .starting)
        )
        XCTAssertEqual(preparing.primaryAction?.isEnabled, false)
        XCTAssertNil(preparing.secondaryAction)

        let success = GaryxCodexLoginPresentation.make(
            session: GaryxCodexAuthSession(
                loginId: "login-test",
                status: .succeeded,
                identity: .object([
                    "email": .string("bot@example.com"),
                    "plan": .string("pro"),
                ])
            )
        )
        XCTAssertEqual(success.step, .success)
        XCTAssertEqual(success.detailRows.first?.value, "bot@example.com")
        XCTAssertEqual(success.detailRows.last?.value, "pro")

        let failure = GaryxCodexLoginPresentation.make(
            session: GaryxCodexAuthSession(loginId: "login-test", status: .failed, error: "boom")
        )
        XCTAssertEqual(failure.step, .failure)
        XCTAssertEqual(failure.message, "boom")
        XCTAssertEqual(failure.primaryAction?.kind, .start)
    }

    func testProviderSettingsAuthSectionRoutesCodex() {
        let codex = GaryxModelProviderDefaults.providers.first {
            $0.providerType == "codex_app_server"
        }
        if let codex {
            XCTAssertEqual(GaryxProviderSettingsPresentation.authSection(for: codex), .codex)
        }
        let claude = GaryxModelProviderDefaults.providers.first {
            $0.providerType == "claude_code"
        }
        if let claude {
            XCTAssertEqual(GaryxProviderSettingsPresentation.authSection(for: claude), .claudeCode)
        }
    }
}
