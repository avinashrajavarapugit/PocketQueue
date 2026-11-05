import Foundation
@testable import PocketQueueCore
import Testing

struct HostedSyncTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["POCKETQUEUE_LIVE_FIXTURE"] != nil))
    func nativeSDKAndTwoOfflineStoresSynchronizeAgainstHostedGraphQL() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["POCKETQUEUE_LIVE_FIXTURE"])
        let fixture = try JSONDecoder().decode(HostedFixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let firstUser = try #require(fixture.users.first)
        let secondUser = try #require(fixture.users.last)
        let config = try BackendConfiguration(url: fixture.url, publishableKey: fixture.publishableKey)
        let firstAuth = try SupabaseAuthentication(
            configuration: config, keychainService: "PocketQueue.live-test.\(fixture.runID).one"
        )
        let secondAuth = try SupabaseAuthentication(
            configuration: config, keychainService: "PocketQueue.live-test.\(fixture.runID).two"
        )
        let otherAuth = try SupabaseAuthentication(
            configuration: config, keychainService: "PocketQueue.live-test.\(fixture.runID).other"
        )
        let firstDatabase = try StoreFixture()
        let secondDatabase = try StoreFixture()
        defer { firstDatabase.remove(); secondDatabase.remove() }
        do {
            let firstIdentity = try await firstAuth.signIn(email: firstUser.email, password: firstUser.password)
            let secondIdentity = try await secondAuth.signIn(email: firstUser.email, password: firstUser.password)
            let otherIdentity = try await otherAuth.signIn(email: secondUser.email, password: secondUser.password)
            #expect(firstIdentity.id == firstUser.id)
            #expect(secondIdentity.id == firstUser.id)
            let firstStore = try await firstDatabase.store.activateAccount(firstIdentity.id)
            let secondStore = try await secondDatabase.store.activateAccount(secondIdentity.id)
            let firstClient = GraphQLBookmarkClient(
                configuration: config,
                authentication: firstAuth,
                accountID: firstIdentity.id
            )
            let secondClient = GraphQLBookmarkClient(
                configuration: config,
                authentication: secondAuth,
                accountID: secondIdentity.id
            )
            let otherClient = GraphQLBookmarkClient(
                configuration: config,
                authentication: otherAuth,
                accountID: otherIdentity.id
            )
            let firstSync = BookmarkSyncEngine(store: firstStore, remote: firstClient)
            let secondSync = BookmarkSyncEngine(store: secondStore, remote: secondClient)
            let saved = try await firstStore.save(
                url: BookmarkURL.parse("https://example.com/native-\(UUID().uuidString)"), note: "Device one"
            )
            _ = try await firstSync.synchronize()
            _ = try await secondSync.synchronize()
            #expect(try await secondStore.all().first(where: { $0.id == saved.bookmark.id })?.note == "Device one")
            #expect(try await otherClient.fetchPage(after: nil).records.isEmpty)

            try await secondStore.update(id: saved.bookmark.id, change: .details(note: "Device two offline", tags: []))
            try await firstStore.update(id: saved.bookmark.id, change: .details(note: "Device one online", tags: []))
            _ = try await firstSync.synchronize()
            _ = try await secondSync.synchronize()
            let conflict = try #require(try await secondStore.conflicts().first)
            #expect(conflict.local.bookmark.note == "Device two offline")
            #expect(conflict.remote?.bookmark.note == "Device one online")
            try await secondStore.resolveConflict(saved.bookmark.id, using: .keepDevice)
            _ = try await secondSync.synchronize()
            _ = try await firstSync.synchronize()
            #expect(try await firstStore.all().first(where: { $0.id == saved.bookmark.id })?
                .note == "Device two offline")
            try await firstStore.delete(id: saved.bookmark.id)
            _ = try await firstSync.synchronize()
            _ = try await secondSync.synchronize()
            #expect(try await secondStore.all().allSatisfy { $0.id != saved.bookmark.id })
            try await otherAuth.deleteAccount()
            #expect(try await otherAuth.currentUser() == nil)
        } catch {
            _ = try await firstAuth.signOut()
            _ = try await secondAuth.signOut()
            _ = try await otherAuth.signOut()
            throw error
        }
        _ = try await firstAuth.signOut()
        _ = try await secondAuth.signOut()
        _ = try await otherAuth.signOut()
    }
}

private struct HostedFixture: Decodable {
    struct User: Decodable {
        let id: UUID
        let email: String
        let password: String
    }

    let runID: UUID
    let url: URL
    let publishableKey: String
    let users: [User]
}
