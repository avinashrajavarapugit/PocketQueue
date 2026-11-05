#if DEBUG
    import Foundation
    import PocketQueueCore

    enum LiveBackendTestSupport {
        private struct User: Decodable {
            let id: UUID
            let email: String
            let password: String
        }

        private struct Credentials: Decodable {
            let purpose: String
            let users: [User]
        }

        static var enabled: Bool {
            ProcessInfo.processInfo.arguments.contains("--live-backend-testing")
        }

        @MainActor
        static func signIn(_ account: CloudAccountModel) async {
            do {
                let directory = try FileManager.default.url(
                    for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
                )
                let path = directory.appending(path: "BackendTestCredentials.json")
                let fixture = try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: path))
                guard fixture.purpose == "PocketQueue ephemeral integration", let user = fixture.users.first else {
                    throw SyncError.accountRequired
                }
                await account.signIn(email: user.email, password: user.password)
                if account.user?.id != user.id {
                    account.errorMessage = "The live backend test account could not be authenticated."
                }
            } catch {
                account.errorMessage = "The private live-backend fixture could not be loaded."
            }
        }
    }
#endif
