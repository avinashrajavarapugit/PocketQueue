import Foundation
@testable import PocketQueueCore
import Security
import Testing

struct AuthStorageTests {
    @Test func storesUpdatesRemovesAndUsesDeviceOnlyProtection() throws {
        let backend = AuthMemoryKeychain()
        let storage = try KeychainAuthStorage(service: "test.storage", backend: backend)
        #expect(try storage.retrieve(key: "session") == nil)
        try storage.store(key: "session", value: Data("first".utf8))
        #expect(try storage.retrieve(key: "session") == Data("first".utf8))
        try storage.store(key: "session", value: Data("second".utf8))
        #expect(try storage.retrieve(key: "session") == Data("second".utf8))
        try storage.remove(key: "session")
        try storage.remove(key: "session")
        #expect(try storage.retrieve(key: "session") == nil)
        #expect(backend.secureAttributesUsed)
    }

    @Test func servicesAreIsolated() throws {
        let backend = AuthMemoryKeychain()
        let first = try KeychainAuthStorage(service: "test.first", backend: backend)
        let second = try KeychainAuthStorage(service: "test.second", backend: backend)
        try first.store(key: "session", value: Data("fixture".utf8))
        #expect(try second.retrieve(key: "session") == nil)
        #expect(throws: CloudAuthError.invalidConfiguration) {
            try KeychainAuthStorage(service: " ", backend: backend)
        }
    }

    @Test func readWriteAndDeleteFailuresAreNotSwallowed() throws {
        let backend = AuthMemoryKeychain()
        let storage = try KeychainAuthStorage(service: "test.failures", backend: backend)
        backend.fail(read: errSecInteractionNotAllowed)
        #expect(throws: CloudAuthError.keychain(errSecInteractionNotAllowed)) {
            try storage.retrieve(key: "session")
        }
        #expect(throws: CloudAuthError.keychain(errSecInteractionNotAllowed)) { try storage.checkFailure() }
        storage.resetFailure()
        backend.fail(write: errSecAuthFailed)
        #expect(throws: CloudAuthError.keychain(errSecAuthFailed)) {
            try storage.store(key: "session", value: Data())
        }
        storage.resetFailure()
        backend.fail(delete: errSecNotAvailable)
        #expect(throws: CloudAuthError.keychain(errSecNotAvailable)) { try storage.remove(key: "session") }
    }

    @Test func initializationFailsWhenKeychainCannotBeRead() throws {
        let fixture = try AuthFixture()
        fixture.backend.fail(read: errSecInteractionNotAllowed)
        #expect(throws: CloudAuthError.keychain(errSecInteractionNotAllowed)) {
            try SupabaseAuthentication(
                configuration: fixture.configuration, storage: fixture.storage,
                fetch: { try await fixture.http.fetch($0) }
            )
        }
    }
}
