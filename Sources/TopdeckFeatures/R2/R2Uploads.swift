// SPDX-License-Identifier: MIT
import AppKit
import Observation
import TopdeckCore

/// Uploads Shelf files to a Cloudflare R2 bucket, only when the user asks. The bucket's address is
/// kept in UserDefaults and its two keys only in the keychain. An upload reads the file and never
/// changes it; one that fails says why on the file.
@MainActor
@Observable
public final class R2Uploads {
    public enum Status: Equatable, Sendable {
        case uploading(Double)
        case uploaded(URL?)
        /// `alreadyExists` when the bucket has a file by that name, which only a replacing upload can overwrite.
        case failed(String, alreadyExists: Bool = false)
    }

    public var bucket: R2Bucket {
        didSet { save() }
    }
    /// Whether both keys are in the keychain.
    public private(set) var hasKeys = false
    public private(set) var statuses: [ShelfItem.ID: Status] = [:]
    /// Raised when an upload finishes or fails.
    @ObservationIgnored public var onActivity: ((Activity) -> Void)?
    /// Puts an uploaded file's link on the clipboard; replaced in tests.
    @ObservationIgnored var copyLink: (URL) -> Void = { link in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keys: R2Keys
    @ObservationIgnored private let client: R2Client
    @ObservationIgnored private var uploads: [ShelfItem.ID: Task<Void, Never>] = [:]
    private static let bucketKey = "r2.bucket"

    public convenience init() {
        self.init(defaults: .standard, keys: .keychain, client: .live)
    }

    init(defaults: UserDefaults, keys: R2Keys, client: R2Client) {
        self.defaults = defaults
        self.keys = keys
        self.client = client
        let saved = defaults.data(forKey: Self.bucketKey)
        bucket = saved.flatMap { try? JSONDecoder().decode(R2Bucket.self, from: $0) } ?? R2Bucket()
        hasKeys = keys.read() != nil
    }

    /// Whether the bucket and keys are filled in, so the Shelf can offer to upload.
    public var isSetUp: Bool { hasKeys && (try? bucket.checked()) != nil }

    /// Keeps both keys in the keychain, replacing any saved before.
    public func saveKeys(accessKeyID: String, secret: String) throws {
        let credentials = R2Credentials(accessKeyID: accessKeyID.trimmed, secret: secret.trimmed)
        guard !credentials.accessKeyID.isEmpty, !credentials.secret.isEmpty else { throw R2Error.notSetUp }
        try keys.save(credentials)
        hasKeys = keys.read() != nil
    }

    public func removeKeys() {
        keys.delete()
        hasKeys = false
    }

    /// Uploads the file at `url` for `item`, unless it's already on its way. A file whose name is taken in
    /// the bucket fails rather than overwrite it, unless `replacing`.
    public func upload(_ item: ShelfItem, from url: URL, replacing: Bool = false) {
        if case .uploading = statuses[item.id] { return }
        guard let credentials = keys.read() else {
            fail(item.id, R2Error.notSetUp)
            return
        }
        statuses[item.id] = .uploading(0)
        let (client, bucket) = (client, bucket)
        uploads[item.id] = Task {
            do {
                let result = try await client.upload(
                    url, to: bucket, credentials: credentials, replacing: replacing
                ) { fraction in
                    Task { @MainActor in self.progress(item.id, fraction) }
                }
                finish(item.id, result)
            } catch {
                fail(item.id, error)
            }
        }
    }

    public func cancel(_ item: ShelfItem) {
        uploads.removeValue(forKey: item.id)?.cancel()
        statuses[item.id] = nil
    }

    /// Forgets how an upload went, such as when its file leaves the shelf.
    public func forget(_ id: ShelfItem.ID) {
        uploads.removeValue(forKey: id)?.cancel()
        statuses[id] = nil
    }

    private func progress(_ id: ShelfItem.ID, _ fraction: Double) {
        guard case .uploading = statuses[id] else { return }
        statuses[id] = .uploading(fraction)
    }

    private func finish(_ id: ShelfItem.ID, _ result: R2Result) {
        uploads[id] = nil
        statuses[id] = .uploaded(result.link)
        if let link = result.link { copyLink(link) }
        let title = result.link == nil ? "Uploaded" : "Link copied"
        onActivity?(Activity(feature: .shelf, symbol: "icloud.and.arrow.up.fill", title: title, duration: .seconds(2)))
    }

    private func fail(_ id: ShelfItem.ID, _ error: any Error) {
        uploads[id] = nil
        let error = error as? R2Error ?? .badResponse
        guard error != .cancelled else {
            statuses[id] = nil
            return
        }
        let reason = error.errorDescription ?? ""
        statuses[id] = .failed(reason, alreadyExists: error == .alreadyExists)
        // Only the reason, which never holds a key.
        Log.features.error("R2 upload failed: \(reason, privacy: .private)")
        let activity = Activity(
            feature: .shelf, symbol: "exclamationmark.icloud.fill", title: "Upload failed", duration: .seconds(3))
        onActivity?(activity)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(bucket) else { return }
        defaults.set(data, forKey: Self.bucketKey)
    }
}

/// Where the keys live: the keychain in the app, memory in tests.
struct R2Keys: Sendable {
    var read: @Sendable () -> R2Credentials?
    var save: @Sendable (R2Credentials) throws -> Void
    var delete: @Sendable () -> Void
}

extension R2Keys {
    private static let service = "Topdeck R2"
    private static let accessKeyName = "access-key-id"
    private static let secretName = "secret-access-key"

    static let keychain = R2Keys(
        read: {
            guard let accessKeyID = APIKeyVault.key(named: accessKeyName, service: service) else { return nil }
            guard let secret = APIKeyVault.key(named: secretName, service: service) else { return nil }
            return R2Credentials(accessKeyID: accessKeyID, secret: secret)
        },
        save: { credentials in
            try APIKeyVault.save(credentials.accessKeyID, named: accessKeyName, service: service)
            try APIKeyVault.save(credentials.secret, named: secretName, service: service)
        },
        delete: {
            APIKeyVault.delete(named: accessKeyName, service: service)
            APIKeyVault.delete(named: secretName, service: service)
        })
}
