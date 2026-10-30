// SPDX-License-Identifier: MIT
import SwiftUI

extension R2Uploads {
    /// The bucket to upload Shelf files to, and its keys, for the Shelf's Settings page.
    public var settingsView: some View { R2Settings(uploads: self) }

    /// Whether the Shelf offers uploads: once anything is filled in, so the reason one can't run yet shows.
    var isOffered: Bool { hasKeys || !bucket.isEmpty }
}

private struct R2Settings: View {
    @Bindable var uploads: R2Uploads
    @State private var accessKeyID = ""
    @State private var secret = ""
    @State private var failure: String?

    var body: some View {
        Group {
            TextField("Account ID", text: $uploads.bucket.accountID)
            TextField("Bucket", text: $uploads.bucket.name)
            TextField("Folder", text: $uploads.bucket.folder, prompt: Text("Optional"))
            TextField("Public URL", text: $uploads.bucket.publicURL, prompt: Text("https://"))
            if let problem = uploads.bucket.problem {
                Text(problem).foregroundStyle(.red)
            }
            if uploads.hasKeys {
                LabeledContent("Keys") {
                    HStack {
                        Text("Saved in your keychain").foregroundStyle(.secondary)
                        Button("Remove", role: .destructive) { uploads.removeKeys() }
                    }
                }
            } else {
                SecureField("Access key ID", text: $accessKeyID)
                SecureField("Secret access key", text: $secret)
                    .onSubmit(save)
                Button("Save Keys", action: save).disabled(accessKeyID.isEmpty || secret.isEmpty)
            }
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
        }
        .autocorrectionDisabled()
    }

    /// Hands both keys to the keychain and clears the fields, so they're held nowhere else.
    private func save() {
        do {
            try uploads.saveKeys(accessKeyID: accessKeyID, secret: secret)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        accessKeyID = ""
        secret = ""
    }
}
