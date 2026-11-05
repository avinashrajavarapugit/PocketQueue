import Foundation
import Observation
import OSLog

@MainActor
@Observable
public final class CloudAccountModel {
    public private(set) var library: LibraryModel?
    public private(set) var user: CloudUser?
    public private(set) var isBusy = false
    public private(set) var isSyncing = false
    public private(set) var pendingCount = 0
    public private(set) var conflicts: [SyncConflict] = []
    public private(set) var lastSyncedAt: Date?
    public var errorMessage: String?
    public var notice: String?
    public var syncError: String?
    public var isRecoveringPassword = false

    private var store: BookmarkStore
    private let authentication: any CloudAuthenticating
    private let metadata: any MetadataFetching
    private let remoteFactory: @Sendable (UUID) -> any CloudBookmarkTransport
    private let onDataChanged: @MainActor @Sendable () -> Void
    private var engine: BookmarkSyncEngine?
    private var syncTask: Task<Void, Never>?
    private var wantsSync = false
    private var allowsSync = true
    private var generation = 0
    private let logger = Logger(subsystem: "com.avinashrajavarapu.pocketqueue", category: "account")

    public var statusText: String {
        if user == nil {
            return "On-device library"
        }
        if isSyncing {
            return "Syncing your library..."
        }
        if !conflicts.isEmpty {
            return "\(conflicts.count) sync conflicts need review"
        }
        if syncError != nil {
            return "Sync paused. Your changes are saved locally."
        }
        if pendingCount > 0 {
            return "\(pendingCount) changes waiting to sync"
        }
        return lastSyncedAt == nil ? "Cloud connected" : "Cloud up to date"
    }

    public init(
        store: BookmarkStore,
        authentication: any CloudAuthenticating,
        metadata: any MetadataFetching,
        remoteFactory: @escaping @Sendable (UUID) -> any CloudBookmarkTransport,
        onDataChanged: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.store = store
        self.authentication = authentication
        self.metadata = metadata
        self.remoteFactory = remoteFactory
        self.onDataChanged = onDataChanged
    }

    public func restore() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let previousAccount = store.accountID
            let restored = try await authentication.currentUser()
            try await activate(restored)
            if restored == nil, previousAccount != nil {
                notice = "Your sign-in is unavailable. Account changes are retained separately; sign into the same account to resume."
            }
        } catch {
            report(error, operation: "restore")
        }
    }

    public func signIn(email: String, password: String) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let signedIn = try await authentication.signIn(email: email, password: password)
            try await activate(signedIn)
            notice = "Signed in. Your on-device bookmarks remain separate; copy them from Account & sync if you want to upload them."
        } catch {
            report(error, operation: "sign-in")
        }
    }

    public func signUp(email: String, password: String) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            switch try await authentication.signUp(email: email, password: password) {
            case let .signedIn(user):
                try await activate(user)
            case .confirmationRequired:
                notice = "Check your email to confirm your account, then return here to sign in."
            }
        } catch {
            report(error, operation: "sign-up")
        }
    }

    public func reauthenticate(password: String) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        cancelSync()
        do {
            guard let user, let email = user.email else { throw SyncError.accountRequired }
            let verified = try await authentication.signIn(email: email, password: password)
            guard verified.id == user.id else {
                _ = try await authentication.signOut()
                throw SyncError.accountChanged
            }
            try await activate(verified)
            notice = "Sign-in refreshed. Your cached bookmarks and queued changes were kept."
        } catch {
            report(error, operation: "reauthenticate")
        }
    }

    public func recoverToGuestPreservingChanges() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        cancelSync()
        do {
            let outcome = try await authentication.signOut()
            library = nil
            user = nil
            try await activate(nil)
            notice = "Saved sign-in reset. Sign into the same account later to recover its cached bookmarks and queued changes."
            if case .localOnly = outcome {
                notice?.append(" The server could not be reached to revoke the remote session.")
            }
        } catch {
            report(error, operation: "recover-local-session")
        }
    }

    public func requestPasswordReset(email: String) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await authentication.sendPasswordReset(email: email)
            notice = "If an account exists, a reset link will be sent. Open it on this device to choose a new password."
        } catch {
            report(error, operation: "password-reset")
        }
    }

    public func handleCallback(_ url: URL) async {
        guard !isBusy else {
            errorMessage = "Finish the current account action, then open the email link again."
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            switch try await authentication.handleCallback(url) {
            case let .signedIn(user):
                try await activate(user)
                notice = "Email confirmed. Your account is ready."
            case let .passwordRecovery(user):
                try await activate(user)
                isRecoveringPassword = true
            }
        } catch {
            report(error, operation: "auth-callback")
        }
    }

    public func updatePassword(_ password: String) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await authentication.updatePassword(password)
            isRecoveringPassword = false
            notice = "Password updated."
        } catch {
            report(error, operation: "password-update")
        }
    }

    public func copyGuestBookmarks() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let count = try await store.importGuestBookmarks()
            await library?.load()
            library?.requestRefresh()
            try await refreshSyncState()
            notice = "Copied \(count) on-device bookmarks. The originals remain in your on-device library."
            onDataChanged()
            requestSync()
        } catch {
            report(error, operation: "copy-device-library")
        }
    }

    public func signOut() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        cancelSync()
        do {
            let outcome = try await authentication.signOut()
            user = nil
            library = nil
            store = try await store.signOutAndRemoveAccountCache()
            try await activate(nil)
            if case .localOnly = outcome {
                notice = "Signed out on this device. The server could not be reached to revoke the remote session."
            } else {
                notice = "Signed out. Your account's cached data was removed from this device."
            }
        } catch {
            report(error, operation: "sign-out")
        }
    }

    public func deleteAccount(password: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        cancelSync()
        do {
            guard let user, let email = user.email else { throw SyncError.accountRequired }
            let verified = try await authentication.signIn(email: email, password: password)
            guard verified.id == user.id else { throw SyncError.accountChanged }
            try await authentication.deleteAccount()
            self.user = nil
            library = nil
            store = try await store.signOutAndRemoveAccountCache()
            try await activate(nil)
            notice = "Account and cloud data deleted. Your separate on-device library was kept."
        } catch {
            report(error, operation: "delete-account")
        }
    }

    @discardableResult
    public func resolve(_ conflict: SyncConflict, using resolution: ConflictResolution) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            try await store.resolveConflict(
                conflict.id, using: resolution, expectedRemoteVersion: conflict.remote?.version ?? 0
            )
            await library?.load()
            try await refreshSyncState()
            onDataChanged()
            requestSync()
            return true
        } catch {
            report(error, operation: "resolve-conflict")
            do {
                try await refreshSyncState()
            } catch {
                report(error, operation: "refresh-conflict")
            }
            return false
        }
    }

    public func requestSync() {
        guard allowsSync, let engine, user != nil else { return }
        wantsSync = true
        guard syncTask == nil else { return }
        let currentGeneration = generation
        syncTask = Task { [weak self] in
            guard let self else { return }
            isSyncing = true
            defer {
                if currentGeneration == generation {
                    isSyncing = false
                    syncTask = nil
                }
            }
            var passes = 0
            while wantsSync, passes < 3, !Task.isCancelled {
                wantsSync = false
                passes += 1
                do {
                    _ = try await engine.synchronize()
                    guard currentGeneration == generation, !Task.isCancelled else { return }
                    try await refreshSyncState()
                    await library?.load()
                    library?.requestRefresh()
                    syncError = nil
                    lastSyncedAt = .now
                    onDataChanged()
                } catch {
                    guard currentGeneration == generation, !Task.isCancelled else { return }
                    syncError = error.localizedDescription
                    logger.error("Cloud synchronization failed; local outbox retained")
                    do {
                        try await refreshSyncState()
                    } catch {
                        report(error, operation: "read-sync-state")
                    }
                    break
                }
            }
        }
    }

    public func syncNow() async {
        requestSync()
        await syncTask?.value
    }

    public func setForeground(_ active: Bool) {
        let resuming = active && !allowsSync
        allowsSync = active
        if active {
            if resuming, let user {
                engine = BookmarkSyncEngine(store: store, remote: remoteFactory(user.id))
            }
            requestSync()
        } else {
            cancelSync()
        }
    }

    private func activate(_ user: CloudUser?) async throws {
        cancelSync()
        let scoped = try await store.activateAccount(user?.id)
        store = scoped
        self.user = user
        pendingCount = 0
        conflicts = []
        syncError = nil
        lastSyncedAt = nil
        engine = user.map { BookmarkSyncEngine(store: scoped, remote: remoteFactory($0.id)) }
        let model = LibraryModel(store: scoped, metadata: metadata) { [weak self] in
            guard let self else { return }
            onDataChanged()
            requestSync()
        }
        library = model
        await model.load()
        if user != nil {
            try await refreshSyncState()
        }
        onDataChanged()
        requestSync()
    }

    private func cancelSync() {
        generation += 1
        syncTask?.cancel()
        syncTask = nil
        wantsSync = false
        isSyncing = false
    }

    private func refreshSyncState() async throws {
        guard user != nil else { return }
        pendingCount = try await store.pendingChanges().count
        conflicts = try await store.conflicts()
    }

    private func report(_ error: Error, operation: String) {
        logger.error("Account operation failed: \(operation, privacy: .public)")
        errorMessage = error.localizedDescription
    }
}
