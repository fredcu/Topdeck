// SPDX-License-Identifier: MIT
import Foundation
import Testing

@testable import TopdeckFeatures

/// The example keys from AWS's Signature Version 4 documentation.
private let accessKeyID = "AKIAIOSFODNN7EXAMPLE"
private let secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
private let credentials = R2Credentials(accessKeyID: accessKeyID, secret: secret)
/// 2013-05-24T00:00:00Z, the time of AWS's S3 examples.
private let exampleDate = Date(timeIntervalSince1970: 1_369_353_600)
private let endpoint = URL(string: "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/a")!

struct R2SigningTests {
    private let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// "GET Object" from AWS's S3 docs, "Signature Calculations for the Authorization Header".
    @Test func signsAWSsGetObjectExample() {
        let headers = [
            "Host": "examplebucket.s3.amazonaws.com", "Range": "bytes=0-9", "x-amz-content-sha256": emptyHash,
            "x-amz-date": "20130524T000000Z",
        ]
        let authorization = SigV4.authorization(
            method: "GET", path: "/test.txt", headers: headers, payloadHash: emptyHash, credentials: credentials,
            region: "us-east-1", service: "s3", date: exampleDate)
        #expect(authorization.hasPrefix("AWS4-HMAC-SHA256 Credential=\(accessKeyID)/20130524/us-east-1/s3/"))
        #expect(authorization.contains(", SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, "))
        #expect(authorization.hasSuffix(", Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"))
    }

    /// "PUT Object" from the same page: its key, `test$file.text`, has to be encoded to sign.
    @Test func signsAWSsPutObjectExampleWithAnEncodedKey() {
        let payloadHash = "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"
        let path = "/" + R2ObjectKey.encode("test$file.text", keepingSlashes: true)
        #expect(path == "/test%24file.text")
        let headers = [
            "Date": "Fri, 24 May 2013 00:00:00 GMT", "Host": "examplebucket.s3.amazonaws.com",
            "x-amz-content-sha256": payloadHash, "x-amz-date": "20130524T000000Z",
            "x-amz-storage-class": "REDUCED_REDUNDANCY",
        ]
        let authorization = SigV4.authorization(
            method: "PUT", path: path, headers: headers, payloadHash: payloadHash, credentials: credentials,
            region: "us-east-1", service: "s3", date: exampleDate)
        let signed = "date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class"
        #expect(authorization.contains(", SignedHeaders=\(signed), "))
        #expect(authorization.hasSuffix(", Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"))
    }

    /// `get-vanilla` from AWS's Signature Version 4 test suite.
    @Test func signsTheTestSuitesVanillaGet() {
        let suiteKeys = R2Credentials(accessKeyID: "AKIDEXAMPLE", secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
        let headers = ["Host": "example.amazonaws.com", "X-Amz-Date": "20150830T123600Z"]
        let date = Date(timeIntervalSince1970: 1_440_938_160)
        let authorization = SigV4.authorization(
            method: "GET", path: "/", headers: headers, payloadHash: emptyHash, credentials: suiteKeys,
            region: "us-east-1", service: "service", date: date)
        #expect(authorization.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/"))
        #expect(authorization.contains(", SignedHeaders=host;x-amz-date, "))
        #expect(authorization.hasSuffix(", Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"))
    }

    /// The whole R2 request: HTTPS to the account's endpoint, the encoded path, and a signature over
    /// exactly the headers that are sent.
    @Test func signsAnR2UploadRequest() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "R2Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Screen Shot 1+1.png")
        try Data("png".utf8).write(to: file)

        let client = R2Client(send: { _, _, _ in throw URLError(.cancelled) }, now: { exampleDate })
        let (request, key) = try client.signedRequest(
            for: file, to: .example, credentials: credentials, replacing: true)
        #expect(key == "drops/Screen Shot 1+1.png")
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.scheme == "https")
        #expect(request.url?.host == "0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com")
        #expect(request.url?.absoluteString.hasSuffix("/shelf-files/drops/Screen%20Shot%201%2B1.png") == true)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/png")
        #expect(request.value(forHTTPHeaderField: "x-amz-content-sha256") == "UNSIGNED-PAYLOAD")
        #expect(request.value(forHTTPHeaderField: "x-amz-date") == "20130524T000000Z")
        let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.hasPrefix("AWS4-HMAC-SHA256 Credential=\(accessKeyID)/20130524/auto/s3/aws4_request, "))
        #expect(authorization.contains(", SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, "))
        #expect(authorization.hasSuffix(", Signature=0318f3f484449fb5f179290844a4e806c0f4c5f7e9fa05b7ad7818f8cbb20115"))
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil, "replacing leaves it out")
    }

    /// By default the request asks R2 to refuse a key that is taken, and signs that header so it can't be
    /// stripped on the way.
    @Test func refusesToOverwriteByDefault() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "R2Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Screen Shot 1+1.png")
        try Data("png".utf8).write(to: file)

        let client = R2Client(send: { _, _, _ in throw URLError(.cancelled) }, now: { exampleDate })
        let (request, _) = try client.signedRequest(for: file, to: .example, credentials: credentials)
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == "*")
        let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
        let signed = "content-type;host;if-none-match;x-amz-content-sha256;x-amz-date"
        #expect(authorization.contains(", SignedHeaders=\(signed), "))
        let (replacing, _) = try client.signedRequest(
            for: file, to: .example, credentials: credentials, replacing: true)
        #expect(replacing.value(forHTTPHeaderField: "Authorization") != authorization)
    }
}

struct R2ObjectKeyTests {
    @Test func encodesEverythingButUnreservedCharacters() {
        #expect(R2ObjectKey.encode("AZaz09-._~", keepingSlashes: false) == "AZaz09-._~")
        let encoded = R2ObjectKey.encode("2026 trip/café ü+&=%?#.jpg", keepingSlashes: true)
        #expect(encoded == "2026%20trip/caf%C3%A9%20%C3%BC%2B%26%3D%25%3F%23.jpg")
        #expect(R2ObjectKey.encode("a/b", keepingSlashes: false) == "a%2Fb")
        #expect(R2ObjectKey.encode("截图.png", keepingSlashes: true) == "%E6%88%AA%E5%9B%BE.png")
    }

    @Test func pathKeepsTheKeysSlashesButNotTheBucketsName() {
        #expect(R2ObjectKey.path(bucket: "shelf-files", key: "a/b c.txt") == "/shelf-files/a/b%20c.txt")
    }

    @Test func keysAreTheFileNameUnderTheFolder() throws {
        #expect(try R2ObjectKey.folder(" /shelf//2026/ ") == "shelf/2026")
        #expect(try R2ObjectKey.folder("") == "")
        #expect(try R2ObjectKey.make(fileName: "a.txt", folder: "shelf/2026") == "shelf/2026/a.txt")
        #expect(try R2ObjectKey.make(fileName: "a.txt", folder: "") == "a.txt")
        #expect(throws: R2Error.invalidFolder) { try R2ObjectKey.folder("shelf/../secrets") }
        #expect(throws: R2Error.invalidFolder) { try R2ObjectKey.folder("./x") }
        for name in ["", " ", ".", "..", "a/b", "a\0b"] {
            #expect(throws: R2Error.invalidFile(name)) { try R2ObjectKey.make(fileName: name, folder: "") }
        }
    }

    @Test func publicLinksAreEncodedAndHTTPSOnly() throws {
        var bucket = R2Bucket.example
        bucket.publicURL = "https://files.example.com/"
        #expect(bucket.link(for: "drops/a b+.png")?.absoluteString == "https://files.example.com/drops/a%20b%2B.png")
        bucket.publicURL = ""
        #expect(bucket.link(for: "a.png") == nil)
        for address in ["http://files.example.com", "files.example.com", "https://x.dev/?a=1", "https://u:p@x.dev"] {
            bucket.publicURL = address
            #expect(throws: R2Error.invalidPublicURL) { try bucket.checked() }
            #expect(bucket.problem != nil)
        }
    }

    @Test func onlyAnAccountIDCanNameTheHost() {
        var bucket = R2Bucket.example
        for id in ["evil.example.com/", "0123456789abcdef0123456789abcde", "0123456789abcdef0123456789abcdeg"] {
            bucket.accountID = id
            #expect(throws: R2Error.invalidAccountID) { try bucket.checked() }
        }
        bucket = .example
        for name in ["ab", "Shelf", "-shelf", "shelf_files", "a.b"] {
            bucket.name = name
            #expect(throws: R2Error.invalidBucket) { try bucket.checked() }
        }
        #expect(throws: R2Error.notSetUp) { try R2Bucket().checked() }
        #expect(R2Bucket().problem == nil, "empty fields aren't wrong yet")
    }
}

/// Keys and secrets never reach error text, logs of the credentials, files, or UserDefaults.
@MainActor
struct R2SecretTests {
    private let folder: URL
    private let defaults: UserDefaults
    private let suite = "R2Tests.\(UUID().uuidString)"

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "R2Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)!
    }

    private func leaks(_ text: String) -> Bool { text.contains(accessKeyID) || text.contains(secret) }

    private func isUploading(_ status: R2Uploads.Status?) -> Bool {
        guard case .uploading = status else { return false }
        return true
    }

    @Test func credentialsNeverPrintTheirKeys() {
        var dumped = ""
        dump(credentials, to: &dumped)
        for text in ["\(credentials)", String(describing: credentials), String(reflecting: credentials), dumped] {
            #expect(!leaks(text), "\(text)")
        }
    }

    /// A signature error from S3 repeats the access key ID and what was signed. Only its code is kept.
    @Test func rejectionsKeepOnlyTheErrorCode() async throws {
        let body = """
            <?xml version="1.0" encoding="UTF-8"?><Error><Code>SignatureDoesNotMatch</Code>\
            <Message>The request signature we calculated does not match</Message>\
            <AWSAccessKeyId>\(accessKeyID)</AWSAccessKeyId><StringToSign>AWS4-HMAC-SHA256 \(secret)</StringToSign>\
            </Error>
            """
        let error = try await failedUpload(status: 403, body: Data(body.utf8))
        #expect(error == .rejected(status: 403, code: "SignatureDoesNotMatch"))
        #expect(error.errorDescription == "R2 didn't accept the keys. Check them in Settings.")
        #expect(R2Error.code(in: Data("<Code>\(accessKeyID)</Code>".utf8)) == nil, "a code is letters only")
        #expect(R2Error.code(in: Data("<Code>\(secret)</Code>".utf8)) == nil)
    }

    @Test func aTakenNameIsNotOverwritten() async throws {
        let error = try await failedUpload(status: 412, body: Data("<Code>PreconditionFailed</Code>".utf8))
        #expect(error == .alreadyExists)
        #expect(error.errorDescription == "A file with this name is already in the bucket.")
    }

    /// The file's menu offers Replace after a 412, and that upload leaves the header out.
    @Test func replacingUploadsOverATakenName() async throws {
        let file = folder.appending(path: "a.txt")
        try Data("a".utf8).write(to: file)
        let client = R2Client(send: { request, _, _ in
            let status = request.value(forHTTPHeaderField: "If-None-Match") == nil ? 200 : 412
            let response = HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil, headerFields: nil)
            return (Data(), response ?? URLResponse())
        })
        let uploads = R2Uploads(defaults: defaults, keys: MemoryKeys().r2Keys, client: client)
        uploads.bucket = .example
        try uploads.saveKeys(accessKeyID: accessKeyID, secret: secret)
        let item = ShelfItem(bookmark: Data(), name: "a.txt")

        uploads.upload(item, from: file)
        let taken = R2Uploads.Status.failed("A file with this name is already in the bucket.", alreadyExists: true)
        #expect(await eventually { uploads.statuses[item.id] == taken })
        uploads.upload(item, from: file, replacing: true)
        #expect(await eventually { uploads.statuses[item.id] == .uploaded(nil) })
    }

    @Test func noErrorTextHoldsAKey() async throws {
        var errors: [R2Error] = [
            .notSetUp, .invalidAccountID, .invalidBucket, .invalidFolder, .invalidPublicURL, .invalidFile("a.txt"),
            .tooLarge, .alreadyExists, .offline, .insecure, .network(-1001), .cancelled, .badResponse,
            .rejected(status: 500, code: nil), .rejected(status: 400, code: "InvalidArgument"),
        ]
        errors.append(try await failedUpload(status: 401, body: Data("<Code>\(accessKeyID)</Code>".utf8)))
        errors.append(R2Error(transport: URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: endpoint])))
        errors.append(R2Error(transport: URLError(.notConnectedToInternet)))
        for error in errors {
            let text = [error.errorDescription ?? "", "\(error)", String(reflecting: error)].joined(separator: " ")
            #expect(!leaks(text), "\(text)")
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    /// A failed upload says why on the file, and leaves the file, UserDefaults, and the folder as they were.
    @Test func aFailedUploadSaysWhyAndChangesNothing() async throws {
        let file = folder.appending(path: "report.pdf")
        try Data("draft".utf8).write(to: file)
        let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let keys = MemoryKeys()
        let uploads = R2Uploads(defaults: defaults, keys: keys.r2Keys, client: Self.client(status: 403, body: Data()))
        uploads.bucket = .example
        try uploads.saveKeys(accessKeyID: " \(accessKeyID) ", secret: secret)
        #expect(uploads.hasKeys && uploads.isSetUp)
        var activities: [String] = []
        uploads.onActivity = { activities.append($0.title) }

        let item = ShelfItem(bookmark: Data(), name: "report.pdf")
        uploads.upload(item, from: file)
        #expect(await eventually { !isUploading(uploads.statuses[item.id]) })
        #expect(uploads.statuses[item.id] == .failed("These keys can't write to this bucket."))
        #expect(activities == ["Upload failed"])
        #expect(try Data(contentsOf: file) == Data("draft".utf8))
        #expect(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["report.pdf"])

        let stored = defaults.persistentDomain(forName: suite) ?? [:]
        #expect(stored.keys.sorted() == ["r2.bucket"], "only the bucket's address")
        let saved = stored.values.map { value in
            (value as? Data).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
        }
        #expect(!saved.contains(where: leaks))
        #expect(keys.stored?.accessKeyID == accessKeyID, "trimmed, and only in the key store")
    }

    @Test func aFinishedUploadCopiesItsLink() async throws {
        let file = folder.appending(path: "a b.png")
        try Data("png".utf8).write(to: file)
        let keys = MemoryKeys()
        let uploads = R2Uploads(defaults: defaults, keys: keys.r2Keys, client: Self.client(status: 200, body: Data()))
        var bucket = R2Bucket.example
        bucket.publicURL = "https://files.example.com"
        uploads.bucket = bucket
        try uploads.saveKeys(accessKeyID: accessKeyID, secret: secret)
        var copied: [URL] = []
        uploads.copyLink = { copied.append($0) }

        let item = ShelfItem(bookmark: Data(), name: "a b.png")
        uploads.upload(item, from: file)
        let link = URL(string: "https://files.example.com/drops/a%20b.png")
        #expect(await eventually { uploads.statuses[item.id] == .uploaded(link) })
        #expect(copied.map(\.absoluteString) == ["https://files.example.com/drops/a%20b.png"])

        uploads.removeKeys()
        #expect(!uploads.hasKeys && keys.stored == nil)
        let reloaded = R2Uploads(defaults: defaults, keys: keys.r2Keys, client: Self.client(status: 200, body: Data()))
        #expect(reloaded.bucket == bucket, "the bucket's address comes back after a relaunch")
    }

    @Test func nothingUploadsWithoutKeys() {
        let client = Self.client(status: 200, body: Data())
        let uploads = R2Uploads(defaults: defaults, keys: MemoryKeys().r2Keys, client: client)
        uploads.bucket = .example
        let item = ShelfItem(bookmark: Data(), name: "a.txt")
        uploads.upload(item, from: folder.appending(path: "a.txt"))
        #expect(uploads.statuses[item.id] == .failed(R2Error.notSetUp.errorDescription ?? ""))
        #expect(throws: R2Error.notSetUp) { try uploads.saveKeys(accessKeyID: accessKeyID, secret: " ") }
    }

    private static func client(status: Int, body: Data) -> R2Client {
        R2Client(send: { request, _, progress in
            progress(1)
            let url = request.url ?? endpoint
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
            return (body, response ?? URLResponse())
        })
    }

    private func failedUpload(status: Int, body: Data) async throws -> R2Error {
        let file = folder.appending(path: "a.txt")
        try Data("a".utf8).write(to: file)
        do {
            _ = try await Self.client(status: status, body: body).upload(file, to: .example, credentials: credentials)
        } catch let error as R2Error {
            return error
        }
        Issue.record("the upload should have failed")
        return .badResponse
    }
}

/// Keys kept in memory instead of the keychain.
private final class MemoryKeys: @unchecked Sendable {
    var stored: R2Credentials?

    var r2Keys: R2Keys {
        R2Keys(read: { self.stored }, save: { self.stored = $0 }, delete: { self.stored = nil })
    }
}

extension R2Bucket {
    fileprivate static var example: R2Bucket {
        var bucket = R2Bucket()
        bucket.accountID = "0123456789abcdef0123456789abcdef"
        bucket.name = "shelf-files"
        bucket.folder = "drops"
        return bucket
    }
}
