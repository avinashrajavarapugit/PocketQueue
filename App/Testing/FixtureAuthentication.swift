#if DEBUG
    import Foundation
    import PocketQueueCore

    actor FixtureAuthentication: CloudAuthenticating {
        private struct StoredUser: Codable {
            let id: UUID
            let email: String
        }

        private let fileURL: URL
        private var corruptSession = ProcessInfo.processInfo.arguments.contains("--corrupt-auth-session")

        init(fileURL: URL) {
            self.fileURL = fileURL
        }

        func currentUser() throws -> CloudUser? {
            if corruptSession {
                throw CocoaError(.coderReadCorrupt)
            }
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            let saved = try JSONDecoder().decode(StoredUser.self, from: Data(contentsOf: fileURL))
            return CloudUser(id: saved.id, email: saved.email)
        }

        func signIn(email: String, password: String) throws -> CloudUser {
            guard email.contains("@"), password.count >= 12, email != "fail@example.com" else {
                throw URLError(.userAuthenticationRequired)
            }
            let existing = try currentUser()
            let user = StoredUser(id: existing?.email == email ? existing?.id ?? UUID() : UUID(), email: email)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(user).write(to: fileURL, options: .atomic)
            return CloudUser(id: user.id, email: user.email)
        }

        func signUp(email: String, password: String) throws -> SignUpOutcome {
            guard email.contains("@"), password.count >= 12 else { throw URLError(.userAuthenticationRequired) }
            return .confirmationRequired
        }

        func signOut() throws -> SignOutOutcome {
            corruptSession = false
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            return .complete
        }

        func accessToken() throws -> String {
            guard try currentUser() != nil else { throw SyncError.accountRequired }
            return "ui-test-token"
        }

        func handleCallback(_ url: URL) throws -> AuthCallbackOutcome {
            guard url.scheme == "pocketqueue", url.host() == "auth", url.path == "/callback",
                  let user = try currentUser() else { throw SyncError.accountRequired }
            return .passwordRecovery(user)
        }

        func sendPasswordReset(email: String) throws {
            guard email.contains("@") else { throw URLError(.userAuthenticationRequired) }
        }

        func updatePassword(_ password: String) throws {
            guard password.count >= 12 else { throw URLError(.userAuthenticationRequired) }
        }

        func deleteAccount() throws {
            _ = try signOut()
        }
    }

    actor FixtureCloudTransport: CloudBookmarkTransport {
        private var records: [UUID: RemoteBookmark] = [:]
        private var conflictOnFirstWrite: Bool

        init(conflictOnFirstWrite: Bool = false) {
            self.conflictOnFirstWrite = conflictOnFirstWrite
        }

        func apply(_ change: PendingChange) -> MutationResult {
            if conflictOnFirstWrite {
                conflictOnFirstWrite = false
                var bookmark = change.bookmark
                bookmark.note = "Cloud version from another device"
                let record = RemoteBookmark(bookmark: bookmark, version: change.baseVersion + 1)
                records[change.id] = record
                return MutationResult(status: .conflict, record: record)
            }
            let record = RemoteBookmark(
                bookmark: change.bookmark, version: change.baseVersion + 1, isDeleted: change.isDeleted
            )
            records[change.id] = record
            return MutationResult(status: .applied, record: record)
        }

        func fetchPage(after _: String?) -> BookmarkPage {
            BookmarkPage(records: Array(records.values))
        }
    }
#endif
