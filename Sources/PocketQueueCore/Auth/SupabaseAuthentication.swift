import Auth
import Foundation

public actor SupabaseAuthentication: CloudAuthenticating {
    private let configuration: BackendConfiguration
    private let storage: KeychainAuthStorage
    private let client: AuthClient
    private let fetch: AuthClient.FetchHandler
    private let storageKey: String
    private var tokenTask: Task<String, any Error>?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        configuration: BackendConfiguration,
        keychainService: String = "com.avinashrajavarapu.pocketqueue.auth"
    ) throws {
        try self.init(
            configuration: configuration,
            storage: KeychainAuthStorage(service: keychainService),
            fetch: { try await AuthNetworkTransport.session.data(for: $0) }
        )
    }

    init(
        configuration: BackendConfiguration,
        storage: KeychainAuthStorage,
        fetch: @escaping AuthClient.FetchHandler
    ) throws {
        self.configuration = configuration
        self.storage = storage
        self.fetch = fetch
        let storageKey = Self.sessionKey(configuration)
        self.storageKey = storageKey
        _ = try storage.retrieve(key: storageKey)
        client = AuthClient(configuration: .init(
            url: configuration.url.appendingPathComponent("auth/v1"),
            headers: ["apikey": configuration.publishableKey],
            flowType: .pkce,
            redirectToURL: BackendConfiguration.callbackURL,
            storageKey: storageKey,
            localStorage: storage,
            logger: nil,
            fetch: { request in
                try storage.checkFailure()
                if request.url?.path == "/auth/v1/recover" {
                    guard let verifier = try storage.retrieve(key: "\(storageKey)-code-verifier") else {
                        throw CloudAuthError.invalidCallback
                    }
                    // Persist intent before sending: the email can be delivered even if the response is lost.
                    try storage.store(key: "\(storageKey)-recovery-verifier", value: verifier)
                }
                return try await fetch(request)
            },
            autoRefreshToken: false,
            emitLocalSessionAsInitialSession: true
        ))
    }

    static func sessionKey(_ configuration: BackendConfiguration) -> String {
        "pocketqueue.auth.\(configuration.url.host() ?? "").\(configuration.url.port ?? 443)"
    }

    public func currentUser() async throws -> CloudUser? {
        try await perform {
            try self.localSession().map { Self.cloudUser($0.user) }
        }
    }

    public func signIn(email: String, password: String) async throws -> CloudUser {
        try await perform {
            let email = try Self.validEmail(email)
            try Self.validPassword(password)
            let session = try await self.client.signIn(email: email, password: password)
            try self.clearPendingCallback()
            return Self.cloudUser(session.user)
        }
    }

    public func signUp(email: String, password: String) async throws -> SignUpOutcome {
        try await perform {
            let email = try Self.validEmail(email)
            try Self.validPassword(password)
            try self.clearPendingCallback()
            let response = try await self.client.signUp(email: email, password: password)
            if let session = response.session {
                try self.clearPendingCallback()
                return .signedIn(Self.cloudUser(session.user))
            }
            return .confirmationRequired
        }
    }

    public func accessToken() async throws -> String {
        if let tokenTask {
            return try await tokenTask.value
        }
        let task = Task {
            try await self.perform {
                try await self.client.session.accessToken
            }
        }
        tokenTask = task
        defer { tokenTask = nil }
        return try await task.value
    }

    public func signOut() async throws -> SignOutOutcome {
        try await perform {
            var outcome = SignOutOutcome.complete
            var storageError: CloudAuthError?
            do {
                if let session = try self.localSession() {
                    do {
                        try await self.post(
                            path: "auth/v1/logout",
                            token: session.accessToken,
                            query: [URLQueryItem(name: "scope", value: "global")]
                        )
                    } catch { outcome = .localOnly }
                }
            } catch let error as CloudAuthError {
                if case .keychain = error {
                    storageError = error
                }
                outcome = .localOnly
            }
            try self.clearLocalCredentials()
            if let storageError {
                throw storageError
            }
            return outcome
        }
    }

    public func handleCallback(_ url: URL) async throws -> AuthCallbackOutcome {
        try await perform {
            try Self.validateCallback(url)
            guard let verifier = try self.storage.retrieve(key: self.verifierKey), !verifier.isEmpty else {
                throw CloudAuthError.invalidCallback
            }
            let recovery = try self.storage.retrieve(key: self.recoveryKey) == verifier
            let session = try await self.client.session(from: url)
            try self.clearPendingCallback()
            let user = Self.cloudUser(session.user)
            return recovery ? .passwordRecovery(user) : .signedIn(user)
        }
    }

    public func sendPasswordReset(email: String) async throws {
        try await perform {
            let email = try Self.validEmail(email)
            try self.clearPendingCallback()
            try await self.client.resetPasswordForEmail(email)
        }
    }

    public func updatePassword(_ password: String) async throws {
        try await perform {
            try Self.validPassword(password)
            _ = try await self.client.update(user: UserAttributes(password: password))
        }
    }

    public func deleteAccount() async throws {
        try await perform {
            let token = try await self.client.session.accessToken
            try self.storage.checkFailure()
            try await self.post(path: "rest/v1/rpc/delete_my_account", token: token)
            try self.clearLocalCredentials()
        }
    }

    private var verifierKey: String {
        "\(storageKey)-code-verifier"
    }

    private var recoveryKey: String {
        "\(storageKey)-recovery-verifier"
    }

    private func localSession() throws -> Session? {
        guard let data = try storage.retrieve(key: storageKey) else { return nil }
        do {
            return try JSONDecoder().decode(Session.self, from: data)
        } catch {
            throw CloudAuthError.corruptSession
        }
    }

    private func clearPendingCallback() throws {
        try storage.remove(key: verifierKey)
        try storage.remove(key: recoveryKey)
    }

    private func clearLocalCredentials() throws {
        var failure: (any Error)?
        for key in [storageKey, verifierKey, recoveryKey] {
            do {
                try storage.remove(key: key)
            } catch {
                failure = error
            }
        }
        if let failure {
            throw failure
        }
    }

    private func post(path: String, token: String, query: [URLQueryItem] = []) async throws {
        var components = URLComponents(
            url: configuration.url.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty {
            components?.queryItems = query
        }
        guard let url = components?.url else { throw CloudAuthError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 30
        let (_, response) = try await fetch(request)
        guard let response = response as? HTTPURLResponse else { throw CloudAuthError.unexpectedResponse }
        guard (200 ..< 300).contains(response.statusCode) else { throw CloudAuthError.serviceRejected }
    }

    /// Serialize all session mutations across suspension points, including sign-out versus refresh.
    private func perform<Value: Sendable>(
        _ operation: () async throws -> Value
    ) async throws -> Value {
        await acquire()
        defer { release() }
        storage.resetFailure()
        do {
            try Task.checkCancellation()
            let value = try await operation()
            try storage.checkFailure()
            return value
        } catch {
            try storage.checkFailure()
            throw Self.mapError(error)
        }
    }

    private func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    static func validateCallback(_ url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "pocketqueue", parts.host == "auth", parts.path == "/callback",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let query = parts.queryItems,
              query.allSatisfy({ ["code", "type"].contains($0.name) }),
              Set(query.map(\.name)).count == query.count,
              let code = query.first(where: { $0.name == "code" })?.value,
              !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw CloudAuthError.invalidCallback }
    }

    private static func validEmail(_ email: String) throws -> String {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              !email.contains(where: \.isWhitespace)
        else { throw CloudAuthError.invalidEmail }
        return email
    }

    private static func validPassword(_ password: String) throws {
        guard !password.isEmpty else { throw CloudAuthError.invalidPassword }
    }

    private static func cloudUser(_ user: User) -> CloudUser {
        CloudUser(id: user.id, email: user.email)
    }

    static func mapError(_ error: any Error) -> CloudAuthError {
        if let error = error as? CloudAuthError {
            return error
        }
        if error is CancellationError {
            return .cancelled
        }
        if let error = error as? URLError {
            return error.code == .cancelled ? .cancelled : .networkUnavailable
        }
        if let error = error as? AuthError {
            return mapSDKError(error)
        }
        return .unexpectedResponse
    }

    private static func mapSDKError(_ error: AuthError) -> CloudAuthError {
        switch error {
        case .sessionMissing, .refreshDiscarded: return .notAuthenticated
        case .weakPassword: return .invalidPassword
        case .pkceGrantCodeExchange: return .invalidCallback
        case let .api(_, code, _, _):
            if code == .invalidCredentials {
                return .invalidCredentials
            }
            if code == .emailNotConfirmed {
                return .confirmationRequired
            }
            return .serviceRejected
        default: return .serviceRejected
        }
    }
}
