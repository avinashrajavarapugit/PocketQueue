import Auth
import Foundation
@testable import PocketQueueCore
import Security
import Testing

final class AuthMemoryKeychain: AuthKeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var readStatus: OSStatus?
    private var writeStatus: OSStatus?
    private var deleteStatus: OSStatus?
    private var attributesValid = true

    func fail(read: OSStatus? = nil, write: OSStatus? = nil, delete: OSStatus? = nil) {
        lock.withLock {
            readStatus = read
            writeStatus = write
            deleteStatus = delete
        }
    }

    var secureAttributesUsed: Bool {
        lock.withLock { attributesValid }
    }

    func read(_ query: [String: Any]) -> (OSStatus, Data?) {
        lock.withLock {
            validate(query)
            if let readStatus {
                return (readStatus, nil)
            }
            guard let data = values[key(query)] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            validate(attributes)
            validateAccessibility(attributes)
            if let writeStatus {
                return writeStatus
            }
            if values[key(attributes)] != nil {
                return errSecDuplicateItem
            }
            values[key(attributes)] = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            validate(query)
            validateAccessibility(attributes)
            if let writeStatus {
                return writeStatus
            }
            guard values[key(query)] != nil else { return errSecItemNotFound }
            values[key(query)] = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            validate(query)
            if let deleteStatus {
                return deleteStatus
            }
            return values.removeValue(forKey: key(query)) == nil ? errSecItemNotFound : errSecSuccess
        }
    }

    private func key(_ query: [String: Any]) -> String {
        "\(query[kSecAttrService as String] as? String ?? ""):\(query[kSecAttrAccount as String] as? String ?? "")"
    }

    private func validate(_ query: [String: Any]) {
        attributesValid = attributesValid
            && query[kSecAttrAccessGroup as String] == nil
            && query[kSecAttrSynchronizable as String] as? Bool == false
            && query[kSecClass as String] as? String == kSecClassGenericPassword as String
    }

    private func validateAccessibility(_ attributes: [String: Any]) {
        attributesValid = attributesValid
            && attributes[kSecAttrAccessible as String] as? String
            == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    }
}

actor AuthHTTPFixture {
    struct Reply: Sendable {
        var status = 200
        var data = Data("{}".utf8)
        var error: URLError?
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply] = []) {
        self.replies = replies
    }

    func fetch(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
        let reply = replies.removeFirst()
        if let error = reply.error {
            throw error
        }
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json", "X-Supabase-Api-Version": "2024-01-01"]
        ))
        return (reply.data, response)
    }
}

struct AuthFixture: Sendable {
    let configuration: BackendConfiguration
    let backend: AuthMemoryKeychain
    let storage: KeychainAuthStorage
    let http: AuthHTTPFixture
    let auth: SupabaseAuthentication
    let key: String

    init(replies: [AuthHTTPFixture.Reply] = []) throws {
        configuration = try BackendConfiguration(
            url: #require(URL(string: "https://fixture.example")),
            publishableKey: "sb_publishable_test_fixture"
        )
        backend = AuthMemoryKeychain()
        storage = try KeychainAuthStorage(service: "test.fixture", backend: backend)
        http = AuthHTTPFixture(replies)
        auth = try SupabaseAuthentication(configuration: configuration, storage: storage, fetch: { [http] in
            try await http.fetch($0)
        })
        key = SupabaseAuthentication.sessionKey(configuration)
    }

    func seed(_ session: Session = Self.session()) throws {
        try storage.store(key: key, value: JSONEncoder().encode(session))
    }

    static func session(expired: Bool = false) -> Session {
        let now = Date()
        return Session(
            accessToken: "fixture-access-token",
            tokenType: "bearer",
            expiresIn: 3600,
            expiresAt: now.timeIntervalSince1970 + (expired ? -3600 : 3600),
            refreshToken: "fixture-refresh-token",
            user: User(
                id: UUID(), appMetadata: [:], userMetadata: [:], aud: "authenticated",
                email: "fixture@example.com", createdAt: now, updatedAt: now
            )
        )
    }

    static func sessionReply(_ session: Session = Self.session()) throws -> AuthHTTPFixture.Reply {
        try .init(data: AuthClient.Configuration.jsonEncoder.encode(session))
    }
}
