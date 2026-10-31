// SPDX-License-Identifier: MIT
// swift-format-ignore-file

import Foundation

/// One of Cline's plan limits.
struct ClineLimit: Hashable, Sendable {
    var label: String
    var usedPercent: Double
    var windowMinutes: Int
    var resetsAt: Date?
}

enum ClineQuotaError: Error, LocalizedError, Equatable {
    case notSignedIn
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Cline isn't signed in on this Mac."
        case .connectionFailed: "Cline's limits request failed. Check your connection."
        case .invalidResponse: "Cline's limits response changed."
        case .requestFailed(let status): "Cline's limits request failed (HTTP \(status))."
        }
    }
}

/// Cline's subscription limits (5-hour, weekly, monthly), from the endpoint its own CLI asks, with the
/// access token the CLI keeps in `~/.cline/data/settings/providers.json`. The token is only read: it is
/// never refreshed or written back, and goes only to Cline.
struct ClineQuotaClient: Sendable {
    static let url = URL(string: "https://api.cline.bot/api/v1/users/me/plan/usage-limits")!

    var httpClient: HTTPClient
    var home: @Sendable () -> URL

    init(
        httpClient: HTTPClient = URLSessionHTTPClient(),
        home: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.httpClient = httpClient
        self.home = home
    }

    var providersFile: URL { home().appending(path: ".cline/data/settings/providers.json") }

    /// The CLI's current access token, or nil when it has none that is still good. The CLI can keep a
    /// refreshed `cline` entry beside an expired `cline-pass` one, and both sign in the same account.
    func token(now: Date = Date()) -> String? {
        guard let data = try? Data(contentsOf: providersFile),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let providers = root["providers"] as? [String: Any]
        else { return nil }
        for name in ["cline-pass", "cline"] {
            guard let settings = (providers[name] as? [String: Any])?["settings"] as? [String: Any],
                let auth = settings["auth"] as? [String: Any], let access = auth["accessToken"] as? String,
                !access.isEmpty
            else { continue }
            if let expiry = (auth["expiresAt"] as? NSNumber)?.doubleValue,
                Date(timeIntervalSince1970: expiry / 1000) <= now.addingTimeInterval(60)
            {
                continue
            }
            return access
        }
        return nil
    }

    func limits(now: Date = Date()) async throws -> [ClineLimit] {
        guard let token = token(now: now) else { throw ClineQuotaError.notSignedIn }
        let response: HTTPResponse
        do {
            response = try await httpClient.send(
                HTTPRequest(
                    method: "GET", url: Self.url,
                    headers: ["Authorization": "Bearer \(token)", "Accept": "application/json"]))
        } catch {
            throw ClineQuotaError.connectionFailed
        }
        guard response.statusCode == 200 else { throw ClineQuotaError.requestFailed(response.statusCode) }
        guard let limits = Self.parse(response.body) else { throw ClineQuotaError.invalidResponse }
        return limits
    }

    /// The limits a response carries, in the order 5-hour, weekly, monthly; nil when it has none or is not
    /// Cline's answer. A limit that is missing stays missing.
    static func parse(_ data: Data) -> [ClineLimit]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], root["success"] as? Bool == true,
            let body = root["data"] as? [String: Any], let limits = body["limits"] as? [[String: Any]]
        else { return nil }
        let windows: [(type: String, label: String, minutes: Int)] = [
            ("five_hour", "5-hour", 300), ("weekly", "Weekly", 10_080), ("monthly", "Monthly", 43_200),
        ]
        let found = windows.compactMap { window -> ClineLimit? in
            guard let limit = limits.first(where: { $0["type"] as? String == window.type }),
                let number = limit["percentUsed"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                number.doubleValue.isFinite, (0...100).contains(number.doubleValue)
            else { return nil }
            let reset = (limit["resetsAt"] as? String).flatMap { OpenUsageISO8601.date(from: $0) }
            return ClineLimit(label: window.label, usedPercent: number.doubleValue, windowMinutes: window.minutes, resetsAt: reset)
        }
        return found.isEmpty ? nil : found
    }
}
