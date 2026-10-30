// SPDX-License-Identifier: MIT AND Apache-2.0
// Adapted from MacTools (https://github.com/mactools-app/MacTools) at 9197035, Plugins/Homebrew:
// HomebrewModels.swift, HomebrewCommandRunner.swift, and HomebrewController.swift.
// Copyright the MacTools authors. Apache License 2.0; see THIRD_PARTY_NOTICES.md.
// Changed for Topdeck: renamed; the list comes from one `brew info --json=v2 --installed`, corrected by
// `brew outdated --json=v2`, decoded leniently; package names are validated before they reach brew;
// commands are built here and run through ToolProcess; no custom brew path, search, install, taps, or
// pinning.
import Foundation

/// An installed formula or cask.
public struct BrewPackage: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case formula, cask }

    public var id: String { "\(kind.rawValue):\(fullName)" }
    /// Its short name, as shown.
    public let name: String
    /// What brew is given: the short name for Homebrew's own, `user/repo/name` from another tap.
    public let fullName: String
    public let kind: Kind
    public let version: String
    /// The newest version, when it's outdated.
    public var latest: String?
    public let summary: String
    public let isPinned: Bool

    public init(
        name: String, fullName: String? = nil, kind: Kind, version: String, latest: String? = nil,
        summary: String = "", isPinned: Bool = false
    ) {
        self.name = name
        self.fullName = fullName ?? name
        self.kind = kind
        self.version = version
        self.latest = latest
        self.summary = summary
        self.isPinned = isPinned
    }

    public var isOutdated: Bool { latest != nil }
}

/// Something to do with Homebrew.
public enum BrewAction: Hashable, Sendable {
    /// Fetches the newest formulae and casks, so the list knows what's outdated.
    case update
    case upgrade(BrewPackage)
    case upgradeAll
    case uninstall(BrewPackage)
    case doctor

    public var title: String {
        switch self {
        case .update: "Check for Updates"
        case .upgrade(let package): "Upgrade \(package.name)"
        case .upgradeAll: "Upgrade All"
        case .uninstall(let package): "Uninstall \(package.name)"
        case .doctor: "Doctor"
        }
    }

    /// Asks first.
    public var isDestructive: Bool {
        if case .uninstall = self { return true }
        return false
    }

    /// brew's arguments, or nil for a package whose name doesn't pass `AdminNames.isValidPackage`.
    public var arguments: [String]? {
        switch self {
        case .update: ["update"]
        case .upgrade(let package): Self.arguments("upgrade", package)
        case .upgradeAll: ["upgrade"]
        case .uninstall(let package): Self.arguments("uninstall", package)
        case .doctor: ["doctor"]
        }
    }

    private static func arguments(_ command: String, _ package: BrewPackage) -> [String]? {
        guard AdminNames.isValidPackage(package.fullName) else { return nil }
        return [command, package.kind == .cask ? "--cask" : "--formula", package.fullName]
    }
}

public enum Brew {
    /// Where Homebrew installs itself: Apple silicon, then Intel.
    static let standardPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    /// The brew command on this Mac, or nil when Homebrew isn't installed.
    public static func locate(fileManager: FileManager = .default, paths: [String] = standardPaths) -> String? {
        paths.first { path in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
                && fileManager.isExecutableFile(atPath: path)
        }
    }

    /// The environment brew runs in. An app opened from Finder has a bare PATH, so brew's own folder
    /// goes first. No auto-update before each command, no emoji, color, or hints in the output, and
    /// nothing interactive.
    public static func environment(brew: String, base: [String: String]) -> [String: String] {
        var environment = base
        let folder = (brew as NSString).deletingLastPathComponent
        let path = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        environment["PATH"] = ([folder] + path.filter { $0 != folder }).joined(separator: ":")
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_EMOJI"] = "1"
        environment["HOMEBREW_NO_COLOR"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["NONINTERACTIVE"] = "1"
        return environment
    }

    public enum ParseError: Error { case notJSON }

    /// `brew info --json=v2 --installed`: every installed formula and cask, sorted by name.
    public static func parseInstalled(_ data: Data) throws -> [BrewPackage] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notJSON
        }
        var packages: [BrewPackage] = []
        for formula in root["formulae"] as? [[String: Any]] ?? [] {
            guard let name = formula["name"] as? String,
                let installed = formula["installed"] as? [[String: Any]], let last = installed.last
            else { continue }
            let version = last["version"] as? String ?? ""
            let stable = (formula["versions"] as? [String: Any])?["stable"] as? String
            let outdated = formula["outdated"] as? Bool ?? false
            packages.append(
                BrewPackage(
                    name: name, fullName: formula["full_name"] as? String, kind: .formula, version: version,
                    latest: outdated ? stable : nil, summary: formula["desc"] as? String ?? "",
                    isPinned: formula["pinned"] as? Bool ?? false))
        }
        for cask in root["casks"] as? [[String: Any]] ?? [] {
            guard let token = cask["token"] as? String, let version = cask["installed"] as? String else { continue }
            let outdated = cask["outdated"] as? Bool ?? false
            let summary = cask["desc"] as? String ?? (cask["name"] as? [String])?.first ?? ""
            packages.append(
                BrewPackage(
                    name: token, fullName: cask["full_token"] as? String, kind: .cask, version: version,
                    latest: outdated ? cask["version"] as? String : nil, summary: summary))
        }
        return packages.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `brew outdated --json=v2`: the newest version of each outdated package, keyed by package ID.
    public static func parseOutdated(_ data: Data) throws -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notJSON
        }
        var latest: [String: String] = [:]
        for (key, kind) in [("formulae", BrewPackage.Kind.formula), ("casks", .cask)] {
            for entry in root[key] as? [[String: Any]] ?? [] {
                guard let name = entry["name"] as? String, let current = entry["current_version"] as? String
                else { continue }
                latest["\(kind.rawValue):\(name)"] = current
            }
        }
        return latest
    }

    /// The installed list with the newest versions `brew outdated` reports, which wins over `brew info`.
    public static func merge(_ packages: [BrewPackage], outdated: [String: String]) -> [BrewPackage] {
        packages.map { package in
            var package = package
            package.latest = outdated[package.id] ?? outdated["\(package.kind.rawValue):\(package.name)"]
            return package
        }
    }
}
