import Foundation
@testable import PocketQueueCore
import Security
import Testing

struct AuthCallbackTests {
    @Test func recoveryIntentAndVerifierSurviveClientRecreation() async throws {
        let session = AuthFixture.session()
        let fixture = try AuthFixture(replies: [.init(), AuthFixture.sessionReply(session)])
        try await fixture.auth.sendPasswordReset(email: "fixture@example.com")
        let verifier = try #require(try fixture.storage.retrieve(key: "\(fixture.key)-code-verifier"))
        #expect(try fixture.storage.retrieve(key: "\(fixture.key)-recovery-verifier") == verifier)
        let restored = try SupabaseAuthentication(
            configuration: fixture.configuration, storage: fixture.storage,
            fetch: { try await fixture.http.fetch($0) }
        )
        let callback = try #require(URL(string: "pocketqueue://auth/callback?code=fixture-code"))
        let result = try await restored.handleCallback(callback)
        guard case let .passwordRecovery(user) = result else { Issue.record("Expected recovery"); return }
        #expect(user.id == session.user.id)
        #expect(try fixture.storage.retrieve(key: "\(fixture.key)-code-verifier") == nil)
        #expect(try fixture.storage.retrieve(key: "\(fixture.key)-recovery-verifier") == nil)
        let requests = await fixture.http.requests
        #expect(requests.first?.url?.path == "/auth/v1/recover")
        #expect(requests.last?.url?.query == "grant_type=pkce")
        let body = try #require(requests.last?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["code_verifier"] == String(data: verifier, encoding: .utf8))
        await #expect(throws: CloudAuthError.invalidCallback) { try await restored.handleCallback(callback) }
    }

    @Test func callbackTypeCannotForgeRecoveryIntent() async throws {
        let fixture = try AuthFixture(replies: [AuthFixture.sessionReply()])
        try fixture.storage.store(key: "\(fixture.key)-code-verifier", value: Data("fixture-verifier".utf8))
        let callback = try #require(URL(string: "pocketqueue://auth/callback?code=fixture&type=recovery"))
        let outcome = try await fixture.auth.handleCallback(callback)
        guard case .signedIn = outcome else { Issue.record("Untrusted type must not imply recovery"); return }
    }

    @Test func callbackRequiresPersistedVerifierBeforeSendingCode() async throws {
        let fixture = try AuthFixture()
        let callback = try #require(URL(string: "pocketqueue://auth/callback?code=fixture"))
        await #expect(throws: CloudAuthError.invalidCallback) { try await fixture.auth.handleCallback(callback) }
        #expect(await fixture.http.requests.isEmpty)
    }

    @Test func verifierStorageFailurePreventsResetNetworkRequest() async throws {
        let fixture = try AuthFixture()
        fixture.backend.fail(write: errSecInteractionNotAllowed)
        await #expect(throws: CloudAuthError.keychain(errSecInteractionNotAllowed)) {
            try await fixture.auth.sendPasswordReset(email: "fixture@example.com")
        }
        #expect(await fixture.http.requests.isEmpty)
    }

    @Test func resetIntentSurvivesLostNetworkResponse() async throws {
        let fixture = try AuthFixture()
        await #expect(throws: CloudAuthError.networkUnavailable) {
            try await fixture.auth.sendPasswordReset(email: "fixture@example.com")
        }
        let verifier = try #require(try fixture.storage.retrieve(key: "\(fixture.key)-code-verifier"))
        #expect(try fixture.storage.retrieve(key: "\(fixture.key)-recovery-verifier") == verifier)
    }
}
