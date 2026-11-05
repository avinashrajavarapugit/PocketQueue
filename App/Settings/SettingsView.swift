import PocketQueueCore
import SwiftUI

struct SettingsView: View {
    let account: CloudAccountModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("PocketQueue", systemImage: "tray.full.fill")
                        .font(.title2.bold())
                    Text("A quieter place for the things you want to revisit.")
                        .foregroundStyle(.secondary)
                    Text("Version 1.0").font(.caption).foregroundStyle(.secondary)
                }
                Section("Optional cloud sync") {
                    NavigationLink {
                        AccountView(account: account)
                    } label: {
                        Label("Account & sync", systemImage: "person.crop.circle")
                    }
                    .accessibilityIdentifier("accountSettingsLink")
                    Text(account.statusText).font(.footnote).foregroundStyle(.secondary)
                }
                Section("Private by design") {
                    Label("No ads or analytics. Account optional.", systemImage: "person.crop.circle.badge.checkmark")
                    Label("On-device and cloud libraries stay separate", systemImage: "iphone")
                    Text("""
                    Signing in enables a separate account library stored in Supabase. \
                    Your existing on-device bookmarks are only uploaded when you explicitly copy them.
                    """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    Text("""
                    Preview requests contact the websites you save. Those websites can see your IP address. \
                    Remote thumbnails may contact their image providers. \
                    No browsing cookies are sent by the preview client.
                    """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                Section("Offline, honestly") {
                    Text("""
                    Saved URLs, titles, tags, and notes are available offline. \
                    Full articles and videos are not downloaded. \
                    Thumbnails are optional and may be evicted from the cache.
                    """)
                }
                Section("Save from other apps") {
                    if SharedEnvironment.isStandalone {
                        Text("""
                        You are using the standalone build. Paste links with the + button. \
                        Share extensions and widgets require the full build with App Group signing.
                        """)
                    } else {
                        Text("""
                        In Safari, tap Share, then choose PocketQueue. If needed, use More to enable it. \
                        Shared links appear when you return to your library.
                        """)
                    }
                }
                Section("Read next widget") {
                    Text("""
                    On your Home Screen, long-press an empty area, add a widget, and search for PocketQueue. \
                    Widget updates are scheduled by iOS and may not appear immediately.
                    """)
                }
            }
            .navigationTitle("About & privacy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
