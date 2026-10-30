// SPDX-License-Identifier: MIT
// Adapted from MacTools (https://github.com/ggbond268/MacTools) at 9197035:
// Plugins/CloudflareR2/Sources/R2UploadService.swift and R2Configuration.swift.
// Copyright (c) 2026 ggbond268 and contributors. Apache License 2.0, changed for Topdeck; see THIRD_PARTY_NOTICES.md.
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Where Shelf uploads go. Nothing here is secret: the two keys live in the keychain (`R2Keys`).
public struct R2Bucket: Codable, Equatable, Sendable {
    /// The 32-character account ID on the Cloudflare dashboard.
    public var accountID = ""
    public var name = ""
    /// A folder inside the bucket, like `shelf/2026`.
    public var folder = ""
    /// The bucket's public address, an r2.dev subdomain or a custom domain. When set, an upload copies
    /// the file's link.
    public var publicURL = ""

    public init() {}

    var isEmpty: Bool { [accountID, name, folder, publicURL].allSatisfy { $0.trimmed.isEmpty } }

    /// The endpoint, bucket, and folder to send to, or why they can't be used.
    func checked() throws -> (host: String, bucket: String, folder: String) {
        let id = accountID.trimmed.lowercased()
        guard !isEmpty else { throw R2Error.notSetUp }
        // Hex digits only, so the account ID can only ever name a host under R2's own domain.
        guard id.count == 32, id.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw R2Error.invalidAccountID }
        let bucket = name.trimmed
        guard Self.isBucketName(bucket) else { throw R2Error.invalidBucket }
        let folder = try R2ObjectKey.folder(self.folder)
        guard publicURL.trimmed.isEmpty || publicBase != nil else { throw R2Error.invalidPublicURL }
        return ("\(id).r2.cloudflarestorage.com", bucket, folder)
    }

    /// The first thing wrong with what's filled in so far, for Settings. Empty fields aren't wrong yet.
    public var problem: String? {
        let id = accountID.trimmed
        if !id.isEmpty, id.count != 32 || !id.allSatisfy({ $0.isASCII && $0.isHexDigit }) {
            return R2Error.invalidAccountID.errorDescription
        }
        if !name.trimmed.isEmpty, !Self.isBucketName(name.trimmed) { return R2Error.invalidBucket.errorDescription }
        if (try? R2ObjectKey.folder(folder)) == nil { return R2Error.invalidFolder.errorDescription }
        if !publicURL.trimmed.isEmpty, publicBase == nil { return R2Error.invalidPublicURL.errorDescription }
        return nil
    }

    /// The public link to an uploaded object, when the bucket has a public address.
    func link(for key: String) -> URL? {
        guard let base = publicBase else { return nil }
        let path = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: path + "/" + R2ObjectKey.encode(key, keepingSlashes: true))
    }

    /// The public address without a query or fragment, over HTTPS only.
    private var publicBase: String? {
        guard let components = URLComponents(string: publicURL.trimmed) else { return nil }
        guard components.scheme?.lowercased() == "https", components.host?.isEmpty == false else { return nil }
        guard components.query == nil, components.fragment == nil, components.user == nil else { return nil }
        return components.string
    }

    /// R2's rule: 3 to 63 lowercase letters, digits, and hyphens, starting and ending with a letter or digit.
    private static func isBucketName(_ name: String) -> Bool {
        let allowed = name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
        return (3...63).contains(name.count) && allowed && name.first != "-" && name.last != "-"
    }
}

/// Object keys, and the percent-encoding that both the request path and its signature use.
enum R2ObjectKey {
    /// The folder's path segments, without empty ones. `.` and `..` are refused rather than resolved.
    static func folder(_ value: String) throws -> String {
        let segments = value.trimmed.split(separator: "/").map(String.init)
        guard !segments.contains(where: { $0 == "." || $0 == ".." }) else { throw R2Error.invalidFolder }
        return segments.joined(separator: "/")
    }

    /// The file's name, under the folder.
    static func make(fileName: String, folder: String) throws -> String {
        let name = fileName.trimmed
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw R2Error.invalidFile(fileName)
        }
        return folder.isEmpty ? name : "\(folder)/\(name)"
    }

    /// `/bucket/key`, encoded the way SigV4 canonicalizes an S3 path.
    static func path(bucket: String, key: String) -> String {
        "/\(encode(bucket, keepingSlashes: false))/\(encode(key, keepingSlashes: true))"
    }

    /// Every UTF-8 byte except the unreserved ones (and, for a key, `/`) as `%XX`, in uppercase hex.
    static func encode(_ value: String, keepingSlashes: Bool) -> String {
        var encoded = ""
        for byte in value.utf8 {
            if unreserved.contains(byte) || (keepingSlashes && byte == UInt8(ascii: "/")) {
                encoded.unicodeScalars.append(UnicodeScalar(byte))
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }

    private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
}

/// An R2 API token's S3 keys. Printing, dumping, or interpolating these never shows them.
public struct R2Credentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let accessKeyID: String
    let secret: String

    public init(accessKeyID: String, secret: String) {
        self.accessKeyID = accessKeyID
        self.secret = secret
    }

    public var description: String { "R2Credentials(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// AWS Signature Version 4, the scheme R2's S3 API checks.
enum SigV4 {
    /// The `Authorization` header for a request with these already-canonical parts. `headers` are
    /// every header to sign, `host` included.
    static func authorization(
        method: String, path: String, query: String = "", headers: [String: String], payloadHash: String,
        credentials: R2Credentials, region: String, service: String, date: Date
    ) -> String {
        let stamp = timestamp(date)
        let day = String(stamp.prefix(8))
        let canonical = headers.map { ($0.key.lowercased(), $0.value.trimmed) }.sorted { $0.0 < $1.0 }
        let signedHeaders = canonical.map(\.0).joined(separator: ";")
        let canonicalHeaders = canonical.map { "\($0.0):\($0.1)\n" }.joined()
        let request = [method, path, query, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let requestHash = hex(SHA256.hash(data: Data(request.utf8)))
        let toSign = ["AWS4-HMAC-SHA256", stamp, scope, requestHash].joined(separator: "\n")
        var key = SymmetricKey(data: Data("AWS4\(credentials.secret)".utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: key))
        return "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), "
            + "Signature=\(signature)"
    }

    /// `20130524T000000Z`: the request time in UTC, as `x-amz-date` carries it.
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// A finished upload: the object's key, and its public link when the bucket has a public address.
public struct R2Result: Equatable, Sendable {
    public let key: String
    public let link: URL?
}

/// Sends one file to R2 as a single signed PUT over HTTPS. It only reads the file.
struct R2Client: Sendable {
    /// Sends the request with the file as its body, reporting the fraction sent; replaced in tests.
    var send: @Sendable (URLRequest, URL, @escaping @Sendable (Double) -> Void) async throws -> (Data, URLResponse)
    var now: @Sendable () -> Date = { .now }

    /// R2 takes up to 5 GiB in one PUT. Larger files need a multipart upload, which this doesn't do.
    static let largestFile: Int64 = 5 << 30

    func upload(
        _ file: URL, to bucket: R2Bucket, credentials: R2Credentials,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> R2Result {
        let (request, key) = try signedRequest(for: file, to: bucket, credentials: credentials)
        let reply: (Data, URLResponse)
        do {
            reply = try await send(request, file, progress)
        } catch {
            throw R2Error(transport: error)
        }
        guard let response = reply.1 as? HTTPURLResponse else { throw R2Error.badResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw R2Error.rejected(status: response.statusCode, code: R2Error.code(in: reply.0))
        }
        return R2Result(key: key, link: bucket.link(for: key))
    }

    /// The signed PUT for `file`, and the key it's stored under.
    func signedRequest(for file: URL, to bucket: R2Bucket, credentials: R2Credentials) throws -> (URLRequest, String) {
        let (host, bucketName, folder) = try bucket.checked()
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard file.isFileURL, values?.isRegularFile == true else { throw R2Error.invalidFile(file.lastPathComponent) }
        guard Int64(values?.fileSize ?? 0) <= Self.largestFile else { throw R2Error.tooLarge }
        let key = try R2ObjectKey.make(fileName: file.lastPathComponent, folder: folder)
        let path = R2ObjectKey.path(bucket: bucketName, key: key)
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.percentEncodedPath = path
        guard let url = components.url, url.scheme == "https" else { throw R2Error.invalidAccountID }

        // The body travels over TLS, so it isn't hashed: hashing a large file first would read it twice.
        let payloadHash = "UNSIGNED-PAYLOAD"
        let contentType = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
        let date = now()
        let headers = [
            "content-type": contentType ?? "application/octet-stream", "host": host,
            "x-amz-content-sha256": payloadHash, "x-amz-date": SigV4.timestamp(date),
        ]
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "PUT"
        // URLSession sets Host itself, from the URL.
        for (field, value) in headers where field != "host" {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let authorization = SigV4.authorization(
            method: "PUT", path: path, headers: headers, payloadHash: payloadHash, credentials: credentials,
            region: "auto", service: "s3", date: date)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return (request, key)
    }
}

extension R2Client {
    /// An ephemeral session, so nothing is cached and no cookies are kept, that refuses redirects:
    /// the signed request only ever goes to R2, over HTTPS.
    static let live = R2Client(send: { request, file, progress in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return try await session.upload(for: request, fromFile: file, delegate: UploadDelegate(progress: progress))
    })
}

private final class UploadDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let progress: @Sendable (Double) -> Void

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        progress(min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend))))
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

/// Why an upload didn't happen. The text names what to fix and never includes a key, a signature, or
/// R2's own error message, which can echo the access key ID.
public enum R2Error: LocalizedError, Equatable {
    case notSetUp
    case invalidAccountID
    case invalidBucket
    case invalidFolder
    case invalidPublicURL
    case invalidFile(String)
    case tooLarge
    /// R2 answered with an error status, and the error code from its reply when there was one.
    case rejected(status: Int, code: String?)
    case offline
    case insecure
    case network(Int)
    case cancelled
    case badResponse

    init(transport error: any Error) {
        guard let code = (error as? URLError)?.code else {
            self = .badResponse
            return
        }
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: self = .offline
        case .secureConnectionFailed, .serverCertificateUntrusted, .appTransportSecurityRequiresSecureConnection:
            self = .insecure
        case .cancelled: self = .cancelled
        default: self = .network(code.rawValue)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notSetUp: "Add your R2 bucket and keys in Settings, under Shelf."
        case .invalidAccountID: "The account ID is the 32 letters and digits on your Cloudflare dashboard."
        case .invalidBucket: "Bucket names have 3 to 63 lowercase letters, digits, and hyphens."
        case .invalidFolder: "The folder can't have . or .. in its path."
        case .invalidPublicURL: "The public URL has to start with https:// and have no query."
        case .invalidFile(let name): "\(name) isn't a file R2 can take. Folders don't upload."
        case .tooLarge: "R2 takes files up to 5 GB in one upload."
        case .rejected(let status, let code): Self.reason(status: status, code: code)
        case .offline: "You're offline."
        case .insecure: "Couldn't make a secure connection to R2."
        case .network(let code): "Couldn't reach R2 (error \(code))."
        case .cancelled: "The upload was cancelled."
        case .badResponse: "R2 sent back something unexpected."
        }
    }

    private static func reason(status: Int, code: String?) -> String {
        switch (status, code) {
        case (_, "InvalidAccessKeyId"?), (_, "SignatureDoesNotMatch"?), (401, _):
            "R2 didn't accept the keys. Check them in Settings."
        case (_, "AccessDenied"?), (403, _): "These keys can't write to this bucket."
        case (_, "NoSuchBucket"?), (404, _): "This account has no bucket by that name."
        case (_, "EntityTooLarge"?), (413, _): R2Error.tooLarge.errorDescription ?? ""
        case (500..., _): "R2 had a problem (HTTP \(status)). Try again."
        default: "R2 refused the upload (HTTP \(status)\(code.map { ", \($0)" } ?? ""))."
        }
    }

    /// The `<Code>` from an S3 error reply, if it's a plain word. The rest of the reply is never read:
    /// a signature error repeats the access key ID and the string that was signed.
    static func code(in body: Data) -> String? {
        let text = String(decoding: body.prefix(1 << 12), as: UTF8.self)
        guard let start = text.range(of: "<Code>") else { return nil }
        guard let end = text.range(of: "</Code>", range: start.upperBound..<text.endIndex) else { return nil }
        let code = text[start.upperBound..<end.lowerBound]
        guard (1...64).contains(code.count), code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return String(code)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
