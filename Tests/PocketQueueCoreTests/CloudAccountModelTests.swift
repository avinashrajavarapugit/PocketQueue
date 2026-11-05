import Foundation
@testable import PocketQueueCore
import Testing

@MainActor
struct CloudAccountModelTests {
    @Test func reauthenticationPreservesQueuedChangesWithoutSigningOut() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let auth = AccountAuthenticationFixture()
        let backend = AccountBackendFixture()
        await backend.setOffline(true)
        let model = makeModel(fixture: fixture, auth: auth, backend: backend)
        await model.restore()
        await model.signIn(email: "test@example.com", password: "Password12345")
        #expect(await model.library?.save("example.com/queued", note: "Never discard") == true)
        await model.syncNow()
        let user = try #require(model.user)
        let scoped = BookmarkStore(databaseURL: fixture.databaseURL, accountID: user.id)
        let original = try #require(try await scoped.pendingChanges().first)
        await model.reauthenticate(password: "wrong")
        #expect(model.errorMessage != nil)
        #expect(try await scoped.pendingChanges().first?.operationID == original.operationID)
        await model.reauthenticate(password: "Password12345")
        await model.syncNow()
        #expect(model.user?.id == user.id)
        #expect(model.library?.bookmarks.first?.note == "Never discard")
        #expect(try await scoped.pendingChanges().first?.operationID == original.operationID)
    }

    @Test func missingOrCorruptCredentialsCanRecoverGuestModeWithoutPurgingOutbox() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let auth = AccountAuthenticationFixture()
        let backend = AccountBackendFixture()
        await backend.setOffline(true)
        let original = makeModel(fixture: fixture, auth: auth, backend: backend)
        await original.restore()
        await original.signIn(email: "test@example.com", password: "Password12345")
        #expect(await original.library?.save("example.com/recovery", note: "Recover me") == true)
        await original.syncNow()
        let identity = try #require(original.user)
        original.setForeground(false)
        await auth.setCorruptSession(true)
        let restored = CloudAccountModel(
            store: BookmarkStore(databaseURL: fixture.databaseURL, accountID: identity.id),
            authentication: auth, metadata: AccountMetadataFixture(), remoteFactory: { _ in backend }
        )
        await restored.restore()
        #expect(restored.library == nil)
        #expect(restored.errorMessage != nil)
        await restored.recoverToGuestPreservingChanges()
        #expect(restored.library != nil)
        #expect(restored.user == nil)
        await restored.signIn(email: "test@example.com", password: "Password12345")
        await restored.syncNow()
        #expect(restored.library?.bookmarks.first?.note == "Recover me")
        #expect(restored.pendingCount == 1)
        restored.setForeground(false)
        await auth.removeSession()
        let missing = CloudAccountModel(
            store: BookmarkStore(databaseURL: fixture.databaseURL, accountID: identity.id),
            authentication: auth, metadata: AccountMetadataFixture(), remoteFactory: { _ in backend }
        )
        await missing.restore()
        #expect(missing.user == nil)
        await missing.signIn(email: "test@example.com", password: "Password12345")
        await missing.syncNow()
        #expect(missing.library?.bookmarks.first?.note == "Recover me")
        #expect(missing.pendingCount == 1)
    }

    @Test func guestLibraryIsNotUploadedUntilUserCopiesIt() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        _ = try await fixture.store.save(url: BookmarkURL.parse("example.com/guest"), note: "Private guest note")
        let auth = AccountAuthenticationFixture()
        let backend = AccountBackendFixture()
        let model = makeModel(fixture: fixture, auth: auth, backend: backend)
        await model.restore()
        #expect(model.user == nil)
        #expect(model.library?.bookmarks.count == 1)
        await model.signIn(email: "test@example.com", password: "Password12345")
        await model.syncNow()
        #expect(model.library?.bookmarks.isEmpty == true)
        #expect(await backend.records.isEmpty)
        await model.copyGuestBookmarks()
        await model.syncNow()
        #expect(model.library?.bookmarks.first?.note == "Private guest note")
        #expect(model.pendingCount == 0)
        #expect(await backend.records.count == 1)
        await model.signOut()
        #expect(model.user == nil)
        #expect(model.library?.bookmarks.first?.note == "Private guest note")
    }

    @Test func offlineChangesRemainQueuedAndRecoverOnResume() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let auth = AccountAuthenticationFixture()
        let backend = AccountBackendFixture()
        let model = makeModel(fixture: fixture, auth: auth, backend: backend)
        await model.restore()
        await model.signIn(email: "test@example.com", password: "Password12345")
        await model.syncNow()
        model.setForeground(false)
        let library = try #require(model.library)
        #expect(await library.save("example.com/offline"))
        #expect(await backend.records.isEmpty)
        await backend.setOffline(true)
        model.setForeground(true)
        await model.syncNow()
        #expect(model.pendingCount == 1)
        #expect(model.syncError != nil)
        #expect(library.bookmarks.count == 1)
        await backend.setOffline(false)
        await model.syncNow()
        #expect(model.pendingCount == 0)
        #expect(model.syncError == nil)
    }

    @Test func confirmationAndRecoveryAreVisibleWithoutPretendingSignInSucceeded() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let model = makeModel(fixture: fixture, auth: AccountAuthenticationFixture(), backend: AccountBackendFixture())
        await model.restore()
        await model.signUp(email: "test@example.com", password: "Password12345")
        #expect(model.user == nil)
        #expect(model.notice?.contains("confirm") == true)
        await model.requestPasswordReset(email: "test@example.com")
        #expect(model.notice?.contains("reset link") == true)
        try await model.handleCallback(#require(URL(string: "pocketqueue://auth/callback?code=test")))
        #expect(model.user != nil)
        #expect(model.isRecoveringPassword)
        await model.updatePassword("NewPassword123")
        #expect(!model.isRecoveringPassword)
        await model.syncNow()
    }

    @Test func failedSignInAndOfflineSignOutHaveExplicitOutcomes() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let auth = AccountAuthenticationFixture()
        let model = makeModel(fixture: fixture, auth: auth, backend: AccountBackendFixture())
        await model.restore()
        await model.signIn(email: "fail@example.com", password: "wrong")
        #expect(model.user == nil)
        #expect(model.errorMessage != nil)
        await model.signIn(email: "test@example.com", password: "Password12345")
        await model.syncNow()
        await auth.setOfflineSignOut()
        await model.signOut()
        #expect(model.user == nil)
        #expect(model.notice?.contains("could not be reached") == true)
        #expect(model.library?.bookmarks.isEmpty == true)
    }

    @Test func deletionReauthenticatesAndReturnsToSeparateGuestLibrary() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let auth = AccountAuthenticationFixture()
        let model = makeModel(fixture: fixture, auth: auth, backend: AccountBackendFixture())
        await model.restore()
        await model.signIn(email: "test@example.com", password: "Password12345")
        await model.syncNow()
        await model.deleteAccount(password: "wrong")
        #expect(model.user != nil)
        #expect(await auth.deleted == false)
        await model.deleteAccount(password: "Password12345")
        #expect(model.user == nil)
        #expect(await auth.deleted)
    }

    private func makeModel(
        fixture: StoreFixture, auth: AccountAuthenticationFixture, backend: AccountBackendFixture
    ) -> CloudAccountModel {
        CloudAccountModel(
            store: fixture.store, authentication: auth, metadata: AccountMetadataFixture(),
            remoteFactory: { _ in backend }
        )
    }
}

private struct AccountMetadataFixture: MetadataFetching {
    func fetch(_: URL) -> LinkMetadata {
        LinkMetadata(title: "Fixture")
    }
}

private actor AccountAuthenticationFixture: CloudAuthenticating {
    private let id = UUID()
    private var user: CloudUser?
    private var offlineSignOut = false
    private var corruptSession = false
    private(set) var deleted = false

    func currentUser() throws -> CloudUser? {
        if corruptSession {
            throw CocoaError(.coderReadCorrupt)
        }
        return user
    }

    func setCorruptSession(_ value: Bool) {
        corruptSession = value
    }

    func removeSession() {
        user = nil
    }

    func accessToken() throws -> String {
        guard user != nil else { throw SyncError.accountRequired }
        return "fixture-token"
    }

    func signIn(email: String, password: String) throws -> CloudUser {
        guard password.count >= 12, email != "fail@example.com" else { throw SyncError.accountRequired }
        let user = CloudUser(id: id, email: email)
        self.user = user
        return user
    }

    func signUp(email _: String, password _: String) -> SignUpOutcome {
        .confirmationRequired
    }

    func setOfflineSignOut() {
        offlineSignOut = true
    }

    func signOut() -> SignOutOutcome {
        user = nil
        corruptSession = false
        return offlineSignOut ? .localOnly : .complete
    }

    func handleCallback(_: URL) -> AuthCallbackOutcome {
        let user = CloudUser(id: id, email: "test@example.com")
        self.user = user
        return .passwordRecovery(user)
    }

    func sendPasswordReset(email _: String) {}
    func updatePassword(_: String) {}
    func deleteAccount() {
        deleted = true; user = nil
    }
}

private actor AccountBackendFixture: CloudBookmarkTransport {
    private(set) var records: [UUID: RemoteBookmark] = [:]
    private var offline = false
    func setOffline(_ value: Bool) {
        offline = value
    }

    func apply(_ change: PendingChange) throws -> MutationResult {
        if offline {
            throw URLError(.notConnectedToInternet)
        }
        let record = RemoteBookmark(
            bookmark: change.bookmark,
            version: change.baseVersion + 1,
            isDeleted: change.isDeleted
        )
        records[change.id] = record
        return .init(status: .applied, record: record)
    }

    func fetchPage(after _: String?) throws -> BookmarkPage {
        if offline {
            throw URLError(.notConnectedToInternet)
        }
        return BookmarkPage(records: Array(records.values))
    }
}
