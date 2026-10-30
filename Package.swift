// swift-tools-version: 6.2
// SPDX-License-Identifier: MIT
import PackageDescription

// Every target builds in the Swift 6 language mode: complete strict-concurrency checking. Topdeck's
// own code treats warnings as errors; the vendored OpenUsage code keeps upstream's warnings as
// warnings, so it can stay close to upstream.
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "TopdeckKit",
    platforms: [.macOS("14.6")],
    products: [
        .library(name: "TopdeckCore", targets: ["TopdeckCore"]),
        .library(name: "TopdeckSurface", targets: ["TopdeckSurface"]),
        .library(name: "TopdeckFeatures", targets: ["TopdeckFeatures"]),
        .library(name: "TopdeckUsage", targets: ["TopdeckUsage"]),
        .library(name: "TopdeckMixer", targets: ["TopdeckMixer"]),
    ],
    dependencies: [
        // Recorders and global shortcuts for Windows (MIT, see THIRD_PARTY_NOTICES.md).
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "3.1.0")
    ],
    targets: [
        // State machine, feature lifecycle, diagnostics. No AppKit, so it tests anywhere.
        .target(name: "TopdeckCore", swiftSettings: strict),
        // Panel, SwiftUI surface, and notch geometry.
        .target(
            name: "TopdeckSurface", dependencies: ["TopdeckCore"],
            // The notch's own icons from Tabler Icons (tabler.io; MIT, see THIRD_PARTY_NOTICES.md).
            resources: [.copy("Resources/Icons")], swiftSettings: strict),
        // Feature modules: each one a NotchFeature plus its views.
        .target(name: "TopdeckFeatures", dependencies: ["TopdeckCore", "KeyboardShortcuts"], swiftSettings: strict),
        // The GitHub build's developer tabs: AI Usage, OpenUsage's providers (MIT, in OpenUsage/) with
        // Topdeck's tab, and Agents, Claude Code and Codex hooks (in Agents/).
        .target(
            name: "TopdeckUsage", dependencies: ["TopdeckCore", "TopdeckFeatures"],
            resources: [
                .copy("Resources/pricing_litellm_snapshot.json"),
                .copy("Resources/pricing_models_dev_snapshot.json"),
                .copy("Resources/pricing_supplement.json"),
                // Provider marks from theSVG (thesvg.org; CC0 or MIT, see THIRD_PARTY_NOTICES.md).
                .copy("Resources/Logos"),
            ]),
        // The GitHub build's per-app volume, in the Media tab: Core Audio process taps, and a private
        // call that tells which app a helper process (Safari's WebKit, say) plays for.
        .target(name: "TopdeckMixer", dependencies: ["TopdeckCore", "TopdeckFeatures"], swiftSettings: strict),
        .testTarget(name: "TopdeckCoreTests", dependencies: ["TopdeckCore"], swiftSettings: strict),
        .testTarget(name: "TopdeckSurfaceTests", dependencies: ["TopdeckSurface"], swiftSettings: strict),
        .testTarget(name: "TopdeckFeaturesTests", dependencies: ["TopdeckFeatures"], swiftSettings: strict),
        .testTarget(name: "TopdeckUsageTests", dependencies: ["TopdeckUsage"], swiftSettings: strict),
        .testTarget(name: "TopdeckMixerTests", dependencies: ["TopdeckMixer"], swiftSettings: strict),
        // OpenUsage's own tests (MIT) for the providers, mappers, and pricing we adapted, on its fixtures.
        .testTarget(name: "OpenUsageTests", dependencies: ["TopdeckUsage"]),
        // XCTest metrics (clock, CPU, memory, signposts) for the core's hot paths.
        .testTarget(name: "PerformanceTests", dependencies: ["TopdeckCore"], swiftSettings: strict),
    ]
)
