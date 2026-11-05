import Auth
import Foundation
@testable import PocketQueueCore
import Testing

struct AuthValidationTests {
    @Test(arguments: [
        "http://fixture.example", "https://user:password@fixture.example", "https://fixture.example/path",
        "https://fixture.example?query=1", "https://fixture.example/#fragment", "pocketqueue://auth/callback",
    ])
    func rejectsUnsafeBackendURLs(_ value: String) throws {
        let url = try #require(URL(string: value))
        #expect(throws: CloudAuthError.invalidConfiguration) {
            try BackendConfiguration(url: url, publishableKey: "sb_publishable_fixture")
        }
    }

    @Test(arguments: [
        "",
        " ",
        "sb_secret_fixture",
        "SB_SECRET_fixture",
        "sb_publishable_",
        "arbitrary",
        "sb_publishable_ x",
    ])
    func rejectsInvalidKeys(_ value: String) throws {
        let url = try #require(URL(string: "https://fixture.example"))
        #expect(throws: CloudAuthError.invalidConfiguration) {
            try BackendConfiguration(url: url, publishableKey: value)
        }
    }

    @Test func acceptsAnonButRejectsServiceRoleJWT() throws {
        let url = try #require(URL(string: "https://fixture.example"))
        func key(role: String) -> String {
            let payload = Data("{\"role\":\"\(role)\"}".utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
            return "fixture.\(payload).signature"
        }
        _ = try BackendConfiguration(url: url, publishableKey: key(role: "anon"))
        #expect(throws: CloudAuthError.invalidConfiguration) {
            try BackendConfiguration(url: url, publishableKey: key(role: "service_role"))
        }
        #expect(BackendConfiguration.callbackURL.absoluteString == "pocketqueue://auth/callback")
    }

    @Test(arguments: [
        "https://auth/callback?code=x", "pocketqueue://other/callback?code=x",
        "pocketqueue://auth/other?code=x", "pocketqueue://user@auth/callback?code=x",
        "pocketqueue://auth:443/callback?code=x", "pocketqueue://auth/callback",
        "pocketqueue://auth/callback?code=", "pocketqueue://auth/callback?code=a&code=b",
        "pocketqueue://auth/callback#access_token=x&refresh_token=y",
        "pocketqueue://auth/callback?code=x#access_token=y",
        "pocketqueue://auth/callback?error=denied&error_description=private",
    ])
    func rejectsUntrustedCallbacksWithoutNetwork(_ value: String) async throws {
        let fixture = try AuthFixture()
        let url = try #require(URL(string: value))
        await #expect(throws: CloudAuthError.invalidCallback) {
            try await fixture.auth.handleCallback(url)
        }
        #expect(await fixture.http.requests.isEmpty)
    }

    @Test func inputValidationDoesNotSendNetworkRequests() async throws {
        let fixture = try AuthFixture()
        await #expect(throws: CloudAuthError.invalidEmail) {
            try await fixture.auth.signIn(email: "invalid", password: "fixture")
        }
        await #expect(throws: CloudAuthError.invalidPassword) {
            try await fixture.auth.signUp(email: "fixture@example.com", password: "")
        }
        await #expect(throws: CloudAuthError.invalidEmail) {
            try await fixture.auth.sendPasswordReset(email: "a @example.com")
        }
        await #expect(throws: CloudAuthError.invalidPassword) {
            try await fixture.auth.updatePassword("")
        }
        #expect(await fixture.http.requests.isEmpty)
    }

    @Test func mapsErrorsWithoutExposingSDKMessages() {
        #expect(SupabaseAuthentication.mapError(AuthError.sessionMissing) == .notAuthenticated)
        #expect(SupabaseAuthentication.mapError(URLError(.notConnectedToInternet)) == .networkUnavailable)
        #expect(SupabaseAuthentication.mapError(CancellationError()) == .cancelled)
        let error = SupabaseAuthentication.mapError(AuthError.weakPassword(message: "private", reasons: []))
        #expect(error == .invalidPassword)
        #expect(error.localizedDescription.contains("private") == false)
    }
}
