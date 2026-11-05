import PocketQueueCore
import SwiftUI

struct AccountView: View {
    private enum Field: Hashable { case email, password, deletion, reauthentication }

    @Bindable var account: CloudAccountModel
    @FocusState private var focusedField: Field?
    @State private var email = ""
    @State private var password = ""
    @State private var creatingAccount = false
    @State private var confirmSignOut = false
    @State private var confirmCopy = false
    @State private var confirmDelete = false
    @State private var deletionPassword = ""
    @State private var reauthenticationPassword = ""
    @State private var confirmReset = false

    var body: some View {
        Form {
            if let user = account.user {
                Section("Signed in") {
                    Text(user.email ?? "Your account").textSelection(.enabled)
                    Label(account.statusText, systemImage: "icloud")
                        .accessibilityIdentifier("accountSyncStatus")
                    if let date = account.lastSyncedAt {
                        Text("Last sync: \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = account.syncError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .accessibilityIdentifier("syncError")
                    }
                    Button("Sync now", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await account.syncNow() }
                    }
                    .disabled(account.isSyncing || account.isBusy)
                    .accessibilityIdentifier("syncNowButton")
                }
                Section("Your on-device bookmarks") {
                    Text(
                        "They remain separate and are not uploaded automatically. Copying keeps the original on-device library."
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                    Button("Copy on-device bookmarks to cloud", systemImage: "icloud.and.arrow.up") {
                        confirmCopy = true
                    }
                    .disabled(account.isBusy)
                    .accessibilityIdentifier("copyGuestButton")
                }
                if !account.conflicts.isEmpty {
                    Section("Resolve sync conflicts") {
                        ForEach(account.conflicts) { conflict in
                            NavigationLink {
                                ConflictView(account: account, conflictID: conflict.id)
                            } label: {
                                Label(
                                    conflict.local.bookmark.title,
                                    systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                                )
                            }
                            .accessibilityIdentifier("conflict-\(conflict.id)")
                        }
                    }
                }
                Section {
                    SecureField("Account password", text: $reauthenticationPassword)
                        .textContentType(.password)
                        .focused($focusedField, equals: .reauthentication)
                        .accessibilityIdentifier("reauthPasswordField")
                    Button("Sign in again") {
                        focusedField = nil
                        Task {
                            await account.reauthenticate(password: reauthenticationPassword)
                            reauthenticationPassword = ""
                        }
                    }
                    .disabled(reauthenticationPassword.isEmpty || account.isBusy)
                    .accessibilityIdentifier("reauthenticateButton")
                    if account.syncError != nil {
                        Button("Reset sign-in and keep queued changes") { confirmReset = true }
                    }
                } header: {
                    Text("Refresh sign-in without losing changes")
                } footer: {
                    Text(
                        "Use this after a session expires. Your cached bookmarks, conflicts, and unsent changes are preserved."
                    )
                }
                Section {
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                        .disabled(account.isBusy)
                        .accessibilityIdentifier("signOutButton")
                } footer: {
                    Text("Signing out removes this account's cache and unsent changes from this device. Sync first.")
                }
                Section {
                    SecureField("Re-enter password to delete", text: $deletionPassword)
                        .textContentType(.password)
                        .focused($focusedField, equals: .deletion)
                        .accessibilityIdentifier("deleteAccountPassword")
                    Button("Delete account permanently", role: .destructive) {
                        focusedField = nil
                        confirmDelete = true
                    }
                    .disabled(deletionPassword.isEmpty || account.isBusy)
                    .accessibilityIdentifier("deleteAccountButton")
                } header: {
                    Text("Delete account")
                } footer: {
                    Text(
                        "This deletes your account and all its cloud bookmarks. Your separate on-device library is kept."
                    )
                }
            } else {
                Section {
                    Label("Your library, on every device", systemImage: "icloud")
                        .font(.headline)
                    Text("Cloud sync is optional. Saving and reading your on-device library never requires an account.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Picker("Account action", selection: $creatingAccount) {
                        Text("Sign in").tag(false)
                        Text("Create account").tag(true)
                    }
                    .pickerStyle(.segmented)
                    TextField("Email", text: $email)
                        .focused($focusedField, equals: .email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("authEmailField")
                    SecureField("Password", text: $password)
                        .focused($focusedField, equals: .password)
                        .textContentType(creatingAccount ? .newPassword : .password)
                        .accessibilityIdentifier("authPasswordField")
                    Button(creatingAccount ? "Create account" : "Sign in") {
                        focusedField = nil
                        Task {
                            if creatingAccount {
                                await account.signUp(email: email, password: password)
                            } else {
                                await account.signIn(email: email, password: password)
                            }
                            password = ""
                        }
                    }
                    .disabled(email.isEmpty || password.isEmpty || account.isBusy)
                    .accessibilityIdentifier("authSubmitButton")
                    Button("Forgot password?") {
                        focusedField = nil
                        Task { await account.requestPasswordReset(email: email) }
                    }
                    .disabled(email.isEmpty || account.isBusy)
                } footer: {
                    Text("""
                    Use at least 12 characters with uppercase and lowercase letters and a number. \
                    New accounts require email confirmation.
                    """)
                }
            }
            if account.isBusy {
                Section { ProgressView("Working securely...") }
            }
            if let message = account.notice {
                Section { Text(message).accessibilityIdentifier("accountNotice") }
            }
            if let error = account.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("accountError")
                }
            }
        }
        .navigationTitle("Account & sync")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Upload a copy of your on-device bookmarks and notes?", isPresented: $confirmCopy) {
            Button("Copy to my account") { Task { await account.copyGuestBookmarks() } }
        }
        .confirmationDialog(
            "Sign out and remove this account's local cache and any unsent changes?",
            isPresented: $confirmSignOut, titleVisibility: .visible
        ) {
            Button("Sign out and clear cache", role: .destructive) { Task { await account.signOut() } }
        }
        .confirmationDialog(
            "Clear the saved sign-in and return to your on-device library? Account changes will be kept separately.",
            isPresented: $confirmReset, titleVisibility: .visible
        ) {
            Button("Reset sign-in") { Task { await account.recoverToGuestPreservingChanges() } }
        }
        .confirmationDialog(
            "Permanently delete your account and cloud bookmarks?",
            isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Delete my account", role: .destructive) {
                Task {
                    await account.deleteAccount(password: deletionPassword)
                    deletionPassword = ""
                    reauthenticationPassword = ""
                }
            }
        }
        .onDisappear {
            password = ""
            deletionPassword = ""
            reauthenticationPassword = ""
        }
    }
}

private struct ConflictView: View {
    let account: CloudAccountModel
    let conflictID: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let conflict = account.conflicts.first(where: { $0.id == conflictID }) {
                content(conflict)
            } else {
                ContentUnavailableView("Conflict resolved", systemImage: "checkmark.circle")
            }
        }
        .navigationTitle("Resolve conflict")
    }

    private func content(_ conflict: SyncConflict) -> some View {
        Form {
            Section("On this device") {
                ConflictSnapshot(bookmark: conflict.local.bookmark, isDeleted: conflict.local.isDeleted)
            }
            Section("In the cloud") {
                if let remote = conflict.remote {
                    ConflictSnapshot(bookmark: remote.bookmark, isDeleted: remote.isDeleted)
                    Text("Cloud revision \(remote.version)").font(.caption)
                } else {
                    Text("This bookmark no longer exists in the cloud.")
                }
            }
            Section {
                Text("""
                Neither version is silently overwritten. \
                Keeping this device submits a new change against the displayed cloud revision.
                """)
                .font(.footnote)
                Button("Keep this device's version") {
                    Task {
                        if await account.resolve(conflict, using: .keepDevice) {
                            dismiss()
                        }
                    }
                }
                .disabled(account.isBusy)
                .accessibilityIdentifier("keepDeviceVersionButton")
                Button("Use the cloud version", role: .destructive) {
                    Task {
                        if await account.resolve(conflict, using: .useCloud) {
                            dismiss()
                        }
                    }
                }
                .disabled(account.isBusy)
            }
            if let error = account.errorMessage {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
        }
    }
}

private struct ConflictSnapshot: View {
    let bookmark: Bookmark
    let isDeleted: Bool

    var body: some View {
        Text(bookmark.title).font(.headline)
        Text(bookmark.url.absoluteString).font(.caption).textSelection(.enabled)
        if isDeleted {
            Label("Deleted", systemImage: "trash").foregroundStyle(.red)
        }
        Text(bookmark.note.isEmpty ? "No note" : bookmark.note).textSelection(.enabled)
        Text(bookmark.tags.isEmpty ? "No tags" : bookmark.tags.map { "#\($0)" }.joined(separator: " ")).font(.caption)
        Label(bookmark.isRead ? "Read" : "Unread", systemImage: bookmark.isRead ? "checkmark.circle" : "circle")
        Label(
            bookmark.isFavorite ? "Favorite" : "Not a favorite",
            systemImage: bookmark.isFavorite ? "star.fill" : "star"
        )
        DisclosureGroup("Preview details") {
            Text("Status: \(bookmark.metadataState.rawValue)").font(.caption)
            if let message = bookmark.metadataMessage {
                Text(message).font(.caption)
            }
            Text(bookmark.imageURL?.absoluteString ?? "No preview image").font(.caption).textSelection(.enabled)
        }
    }
}

struct PasswordRecoveryView: View {
    @Bindable var account: CloudAccountModel
    @State private var password = ""
    @State private var confirmation = ""

    var body: some View {
        NavigationStack {
            Form {
                SecureField("New password", text: $password).textContentType(.newPassword)
                SecureField("Confirm new password", text: $confirmation).textContentType(.newPassword)
                Text("Use at least 12 characters, including uppercase and lowercase letters and a number.")
                    .font(.footnote)
                if let error = account.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                Button("Update password") { Task { await account.updatePassword(password) } }
                    .disabled(password.count < 12 || password != confirmation || account.isBusy)
            }
            .navigationTitle("Choose a new password")
            .interactiveDismissDisabled()
        }
    }
}
