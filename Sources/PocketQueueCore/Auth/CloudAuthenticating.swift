import Foundation

public struct BackendConfiguration: Sendable {
    public let url: URL
    public let publishableKey: String
    public static let callbackURL: URL = {
        guard let url = URL(string: "pocketqueue://auth/callback") else {
            preconditionFailure("Invalid static callback URL")
        }
        return url
    }()

    public init(url: URL, publishableKey: String) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              !publishableKey.isEmpty,
              !publishableKey.contains(where: { $0.isWhitespace || $0.isNewline }),
              !publishableKey.lowercased().hasPrefix("sb_secret_"),
              Self.isPublicKey(publishableKey)
        else { throw CloudAuthError.invalidConfiguration }
        self.url = url
        self.publishableKey = publishableKey
    }

    private static func isPublicKey(_ key: String) -> Bool {
        if key.hasPrefix("sb_publishable_") {
            return key.count > "sb_publishable_".count
        }
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        // This is a key-type check, not JWT signature verification.
        return claims["role"] as? String == "anon"
    }
}

public struct CloudUser: Sendable, Equatable {
    public let id: UUID
    public let email: String?

    public init(id: UUID, email: String?) {
        self.id = id
        self.email = email
    }
}

public enum SignUpOutcome: Sendable {
    case signedIn(CloudUser)
    case confirmationRequired
}

public enum SignOutOutcome: Sendable {
    case complete
    /// Remote revocation was unavailable; all local credentials were successfully removed.
    case localOnly
}

public enum AuthCallbackOutcome: Sendable {
    case signedIn(CloudUser)
    case passwordRecovery(CloudUser)
}

public protocol CloudAuthenticating: Sendable {
    func currentUser() async throws -> CloudUser?
    func signIn(email: String, password: String) async throws -> CloudUser
    func signUp(email: String, password: String) async throws -> SignUpOutcome
    func signOut() async throws -> SignOutOutcome
    func accessToken() async throws -> String
    func handleCallback(_ url: URL) async throws -> AuthCallbackOutcome
    func sendPasswordReset(email: String) async throws
    func updatePassword(_ password: String) async throws
    func deleteAccount() async throws
}

/// Deliberately excludes server messages, URLs, response bodies, and credential values.
public enum CloudAuthError: Error, Sendable, Equatable, LocalizedError {
    case invalidConfiguration
    case invalidEmail
    case invalidPassword
    case invalidCallback
    case notAuthenticated
    case invalidCredentials
    case confirmationRequired
    case networkUnavailable
    case serviceRejected
    case unexpectedResponse
    case corruptSession
    case keychain(Int32)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The cloud configuration is invalid."
        case .invalidEmail: "Enter a valid email address."
        case .invalidPassword: "Enter a password that meets the account requirements."
        case .invalidCallback: "This sign-in link is invalid or no longer pending on this device."
        case .notAuthenticated: "Sign in to continue."
        case .invalidCredentials: "The sign-in credentials were not accepted."
        case .confirmationRequired: "Confirm your email address before signing in."
        case .networkUnavailable: "The cloud service could not be reached."
        case .serviceRejected: "The cloud service could not complete the request."
        case .unexpectedResponse: "The cloud service returned an unexpected response."
        case .corruptSession: "The saved session could not be restored. Sign out and try again."
        case .keychain: "Secure credential storage is unavailable. Please try again."
        case .cancelled: "The operation was cancelled."
        }
    }
}
