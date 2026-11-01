// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import TopdeckSurface

/// The Mac page's System screen: the busiest processes first, then launch services and Homebrew, in one
/// segmented control. A part whose feature is off is not there: without System Admin the screen is the process
/// table alone and has no control; without Performance it is the admin lists as before.
public struct SystemScreen: View {
    enum Part: CaseIterable {
        case processes, services, homebrew

        var title: String {
            switch self {
            case .processes: "Processes"
            case .services: SystemAdminFeature.Section.services.title
            case .homebrew: SystemAdminFeature.Section.homebrew.title
            }
        }

        var section: SystemAdminFeature.Section? {
            switch self {
            case .processes: nil
            case .services: .services
            case .homebrew: .homebrew
            }
        }
    }

    let performance: PerformanceFeature?
    let admin: SystemAdminFeature?
    var icon: ((Int32) -> NSImage?)?
    @State private var part = Part.processes

    public init(performance: PerformanceFeature?, admin: SystemAdminFeature?) {
        self.performance = performance
        self.admin = admin
    }

    /// With the icon of each process and the part to open on given, for screenshots.
    init(
        performance: PerformanceFeature?, admin: SystemAdminFeature?, icon: ((Int32) -> NSImage?)?, part: Part
    ) {
        self.init(performance: performance, admin: admin)
        self.icon = icon
        self._part = State(initialValue: part)
    }

    public var body: some View {
        if let performance, let admin {
            VStack(spacing: Deck.Metric.gap) {
                if part == .processes {
                    HStack(spacing: 6) {
                        picker(admin)
                        Spacer(minLength: 0)
                    }
                    table(performance)
                } else {
                    SystemAdminView(admin: admin, picker: AnyView(picker(admin)))
                }
            }
        } else if let performance {
            table(performance)
        } else if let admin {
            SystemAdminView(admin: admin)
        }
    }

    private func table(_ performance: PerformanceFeature) -> some View {
        ProcessTable(snapshot: performance.snapshot, icon: icon ?? ProcessTable.appIcon)
    }

    private func picker(_ admin: SystemAdminFeature) -> some View {
        DeckSegmented(Part.allCases, selection: part, title: \.title) {
            part = $0
            if let section = $0.section { admin.section = section }
        }
    }
}
