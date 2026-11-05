import Auth
import Foundation
@testable import PocketQueueCore
import Security
import Testing

struct AuthSessionTests {
    @Test func restoresExpiredSessionWithoutNetwork() async throws {
        let fixture = try AuthFixture()
        let session = AuthFixture.session(expired: true)
        try fixture.seed(session)
        let user = try await fixture.auth.currentUser()
        #expect(user == CloudUser(id: session.user.id, email: session.user.email))
        #expect(await fixture.http.requests.isEmpty)
        await #expect(throws: CloudAuthError.networkUnavailable) { try await fixture.auth.accessToken() }
        #expect(try await fixture.auth.currentUser() == user)
    }

    @Test func missingAndCorruptSessionsAreDistinct() async throws {
        let fixture = try AuthFixture()
        #expect(try await fixture.auth.currentUser() == nil)
        await #expect(throws: CloudAuthError.notAuthenticated) { try await fixture.auth.accessToken() }
        try fixture.storage.store(key: fixture.key, value: Data("broken".utf8))
        await #expect(throws: CloudAuthError.corruptSession) { try await fixture.auth.currentUser() }
        let outcome = try await fixture.auth.signOut()
        guard case .localOnly = outcome else { Issue.record("Expected local-only cleanup"); return }
        #expect(try await fixture.auth.currentUser() == nil)
    }

    @Test(arguments: [false, true])
    func corruptStartupSessionCanBeResetUnlessKeychainDeletionFails(failDeletion: Bool) async throws {
        let fixture = try AuthFixture()
        let keys = [fixture.key, "\(fixture.key)-code-verifier", "\(fixture.key)-recovery-verifier"]
        for key in keys {
            try fixture.storage.store(key: key, value: Data("corrupt-fixture".utf8))
        }
        let restored = try SupabaseAuthentication(
            configuration: fixture.configuration, storage: fixture.storage,
            fetch: { try await fixture.http.fetch($0) }
        )
        await #expect(throws: CloudAuthError.corruptSession) { try await restored.currentUser() }

        if failDeletion {
            fixture.backend.fail(delete: errSecInteractionNotAllowed)
            await #expect(throws: CloudAuthError.keychain(errSecInteractionNotAllowed)) {
                try await restored.signOut()
            }
            for key in keys {
                #expect(try fixture.storage.retrieve(key: key) != nil)
            }
            fixture.backend.fail()
        }

        let outcome = try await restored.signOut()
        guard case .localOnly = outcome
        else { Issue.record("Corrupt session cannot confirm remote revocation"); return }
        for key in keys {
            #expect(try fixture.storage.retrieve(key: key) == nil)
        }
        #expect(try await restored.currentUser() == nil)
        await #expect(throws: CloudAuthError.notAuthenticated) { try await restored.accessToken() }
        #expect(await fixture.http.requests.isEmpty)

        let repeated = try await restored.signOut()
        guard case .complete = repeated else { Issue.record("Already-cleared sign out should complete"); return }
    }

    @Test func signInPersistsSessionAndMapsRejections() async throws {
        let session = AuthFixture.session()
        let fixture = try AuthFixture(replies: [
            AuthFixture.sessionReply(session),
            .init(status: 400, data: Data("{\"code\":\"invalid_credentials\",\"msg\":\"private\"}".utf8)),
        ])
        let user = try await fixture.auth.signIn(email: "fixture@example.com", password: "fixture")
        #expect(user.id == session.user.id)
        #expect(try await fixture.auth.currentUser() == user)
        await #expect(throws: CloudAuthError.invalidCredentials) {
            try await fixture.auth.signIn(email: "fixture@example.com", password: "fixture")
        }
    }

    @Test func signUpSupportsConfirmationAndImmediateSession() async throws {
        let session = AuthFixture.session()
        let userData = try AuthClient.Configuration.jsonEncoder.encode(session.user)
        let fixture = try AuthFixture(replies: [.init(data: userData), AuthFixture.sessionReply(session)])
        let first = try await fixture.auth.signUp(email: "fixture@example.com", password: "fixture")
        guard case .confirmationRequired = first else { Issue.record("Expected confirmation"); return }
        #expect(try await fixture.auth.currentUser() == nil)
        #expect(try fixture.storage.retrieve(key: "\(fixture.key)-code-verifier") != nil)
        let second = try await fixture.auth.signUp(email: "fixture@example.com", password: "fixture")
        guard case let .signedIn(user) = second else { Issue.record("Expected session"); return }
        #expect(user.id == session.user.id)
    }

    @Test func sdkStorageFailureCannotMasqueradeAsSignInSuccess() async throws {
        let fixture = try AuthFixture(replies: [AuthFixture.sessionReply()])
        fixture.backend.fail(write: errSecNotAvailable)
        await #expect(throws: CloudAuthError.keychain(errSecNotAvailable)) {
            try await fixture.auth.signIn(email: "fixture@example.com", password: "fixture")
        }
        fixture.backend.fail()
        #expect(try await fixture.auth.currentUser() == nil)
    }

    @Test func concurrentTokenRequestsRefreshOnce() async throws {
        let session = AuthFixture.session()
        let fixture = try AuthFixture(replies: [AuthFixture.sessionReply(session)])
        try fixture.seed(AuthFixture.session(expired: true))
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0 ..< 20 {
                group.addTask { try await fixture.auth.accessToken() }
            }
            for try await token in group {
                #expect(token == session.accessToken)
            }
        }
        #expect(await fixture.http.requests.count == 1)
    }

    @Test func concurrentOfflineTokenRequestsShareOneFailure() async throws {
        let fixture = try AuthFixture()
        try fixture.seed(AuthFixture.session(expired: true))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 20 {
                group.addTask {
                    await #expect(throws: CloudAuthError.networkUnavailable) {
                        try await fixture.auth.accessToken()
                    }
                }
            }
        }
        // Pinned SDK retries an offline transport failure once; twenty callers share that operation.
        #expect(await fixture.http.requests.count == 2)
        #expect(try await fixture.auth.currentUser() != nil)
    }

    @Test func offlineSignOutClearsSessionAndAllPKCEState() async throws {
        let fixture = try AuthFixture()
        try fixture.seed()
        try fixture.storage.store(key: "\(fixture.key)-code-verifier", value: Data("fixture".utf8))
        try fixture.storage.store(key: "\(fixture.key)-recovery-verifier", value: Data("fixture".utf8))
        let outcome = try await fixture.auth.signOut()
        guard case .localOnly = outcome else { Issue.record("Expected local-only sign out"); return }
        #expect(try await fixture.auth.currentUser() == nil)
        #expect(try fixture.storage.retrieve(key: "\(fixture.key)-code-verifier") == nil)
        #expect(try fixture.storage.retrieve(key: "\(fixture.key)-recovery-verifier") == nil)
    }

    @Test func signOutReportsRevocationFailureIncludingUnauthorized() async throws {
        let fixture = try AuthFixture(replies: [.init(status: 401)])
        try fixture.seed()
        let outcome = try await fixture.auth.signOut()
        guard case .localOnly = outcome else { Issue.record("401 must not imply revocation"); return }
        #expect(try await fixture.auth.currentUser() == nil)
    }

    @Test func signOutFailsWhenLocalDeletionFailsAndCanBeRetried() async throws {
        let fixture = try AuthFixture(replies: [.init(), .init()])
        try fixture.seed()
        fixture.backend.fail(delete: errSecInteractionNotAllowed)
        await #expect(throws: CloudAuthError.keychain(errSecInteractionNotAllowed)) {
            try await fixture.auth.signOut()
        }
        fixture.backend.fail()
        let outcome = try await fixture.auth.signOut()
        guard case .complete = outcome else { Issue.record("Expected complete sign out"); return }
        #expect(try await fixture.auth.currentUser() == nil)
    }

    @Test func deletionUsesAuthenticatedRPCAndClearsOnlyAfterSuccess() async throws {
        let fixture = try AuthFixture(replies: [.init(status: 500), .init(status: 204)])
        try fixture.seed()
        await #expect(throws: CloudAuthError.serviceRejected) { try await fixture.auth.deleteAccount() }
        #expect(try await fixture.auth.currentUser() != nil)
        try await fixture.auth.deleteAccount()
        #expect(try await fixture.auth.currentUser() == nil)
        let requests = await fixture.http.requests
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.url?.path == "/rest/v1/rpc/delete_my_account")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "apikey") == fixture.configuration.publishableKey)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access-token")
            #expect(request.httpBody == Data("{}".utf8))
        }
    }

    @Test func offlineDeletionRetainsLocalAccount() async throws {
        let fixture = try AuthFixture()
        try fixture.seed()
        await #expect(throws: CloudAuthError.networkUnavailable) { try await fixture.auth.deleteAccount() }
        #expect(try await fixture.auth.currentUser() != nil)
    }
}
