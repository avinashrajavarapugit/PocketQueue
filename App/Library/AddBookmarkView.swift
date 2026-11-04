import PocketQueueCore
import SwiftUI

struct AddBookmarkView: View {
    let model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var note = ""
    @State private var tags = ""
    @State private var validationError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("The interesting thing") {
                    TextField("https://example.com/article", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Link URL")
                        .accessibilityIdentifier("urlField")
                }
                Section("Make it yours") {
                    TextField("Why save this?", text: $note, axis: .vertical)
                        .lineLimit(3 ... 6)
                        .accessibilityIdentifier("noteField")
                    TextField("Tags, separated by commas", text: $tags)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("tagsField")
                }
                Section {
                    Label("Your link is saved first. Preview fetching happens afterward.", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let validationError {
                    Section {
                        Label(validationError, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("saveError")
                    }
                }
            }
            .navigationTitle("Save for later")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isSaving ? "Saving..." : "Save") { save() }
                        .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSaving)
                        .accessibilityIdentifier("confirmSaveButton")
                }
            }
            .interactiveDismissDisabled(model.isSaving)
        }
    }

    private func save() {
        Task {
            if await model.save(url, note: note, tags: tags.components(separatedBy: ",")) {
                dismiss()
            } else {
                validationError = model.errorMessage
                model.errorMessage = nil
            }
        }
    }
}
