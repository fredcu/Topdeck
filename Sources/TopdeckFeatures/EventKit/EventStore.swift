// SPDX-License-Identifier: MIT
import AppKit
import EventKit
import SwiftUI
import TopdeckSurface

/// The EventKit store for Calendar, created the first time it needs it, so an enabled-but-unopened
/// feature costs nothing.
@MainActor
public final class EventStore {
    public init() {}

    private(set) lazy var store = EKEventStore()
}

/// Where EventKit access stands for one kind of data.
public enum EventAccess: Equatable, Sendable {
    case notDetermined
    case denied
    case granted

    init(_ type: EKEntityType) {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: self = .granted
        case .notDetermined: self = .notDetermined
        default: self = .denied  // denied, restricted, or write-only
        }
    }
}

/// What a card says while it lacks EventKit access: one line, and the button that gets it.
struct EventAccessView: View {
    let access: EventAccess
    let what: String
    let settingsPane: String
    let request: () -> Void

    var body: some View {
        VStack(spacing: Deck.Metric.gap) {
            if access == .denied {
                Text("\(what.capitalized) access is off").deckText(.body)
                Button("Open Privacy Settings") { NSWorkspace.shared.open(.privacySettings(settingsPane)) }
                    .buttonStyle(.deck())
            } else {
                Text("Topdeck reads your \(what) on this Mac only.").deckText(.detail).multilineTextAlignment(.center)
                Button("Continue", action: request).buttonStyle(.deck())  // App Review 5.1.1(iv): not "Allow"
            }
        }
        .padding(Deck.Metric.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
