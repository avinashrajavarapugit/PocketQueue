import SwiftUI

struct SettingsView: View {
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
                Section("Private by design") {
                    Label("No account, ads, or analytics", systemImage: "person.crop.circle.badge.checkmark")
                    Label("Bookmarks and notes stay on this device", systemImage: "iphone")
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
