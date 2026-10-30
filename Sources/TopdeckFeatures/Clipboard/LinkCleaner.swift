// SPDX-License-Identifier: MIT
import Foundation

/// Takes tracking parameters out of a copied web link: campaign tags (`utm_…`) and the click IDs
/// ad and mail services add. Everything else in the link stays exactly as it was copied, encoding
/// included. A link that doesn't parse as it stands is left alone. No AppKit, so it tests anywhere.
enum LinkCleaner {
    static let trackingPrefixes = ["utm_"]
    static let trackingNames: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid",
        "li_fat_id", "igshid", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id", "oly_enc_id",
        "vero_id", "_openstat", "srsltid",
    ]

    /// `text` without tracking parameters when it's one http or https link, with the spaces around it
    /// kept; otherwise `text` unchanged.
    static func clean(_ text: String) -> String {
        let link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = text.range(of: link), !link.isEmpty, let cleaned = cleanLink(link) else { return text }
        return text.replacingCharacters(in: range, with: cleaned)
    }

    /// The link without tracking parameters, or nil when it has none or doesn't parse as it stands.
    private static func cleanLink(_ link: String) -> String? {
        guard !link.contains(where: \.isWhitespace), let components = URLComponents(string: link),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            components.host?.isEmpty == false, let question = link.firstIndex(of: "?")
        else { return nil }
        let end = link[question...].firstIndex(of: "#") ?? link.endIndex
        let query = link[link.index(after: question)..<end]
        // The query as copied must be the one Foundation read, so nothing it re-encoded is rewritten.
        guard components.percentEncodedQuery == String(query) else { return nil }
        let parameters = query.split(separator: "&", omittingEmptySubsequences: false)
        let kept = parameters.filter { !isTracking($0) }
        guard kept.count < parameters.count else { return nil }
        let rest = kept.isEmpty ? "" : "?" + kept.joined(separator: "&")
        return String(link[..<question]) + rest + String(link[end...])
    }

    private static func isTracking(_ parameter: Substring) -> Bool {
        let raw = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let name = (String(raw).removingPercentEncoding ?? String(raw)).lowercased()
        let tagged = trackingPrefixes.contains { name.hasPrefix($0) && name.count > $0.count }
        return tagged || trackingNames.contains(name)
    }
}
