// SPDX-License-Identifier: MIT
import KeyboardShortcuts
import SwiftUI

extension WindowManager {
    /// The sections of the Windows page in Settings, shown while it's on.
    public var settingsView: some View { WindowsSettings(windows: self) }
}

private struct WindowsSettings: View {
    @Bindable var windows: WindowManager

    private struct ShortcutGroup: Identifiable {
        let id: String
        let actions: [WindowAction]
    }

    private static let groups = [
        ShortcutGroup(id: "Halves", actions: [.leftHalf, .rightHalf, .topHalf, .bottomHalf]),
        ShortcutGroup(id: "Quarters", actions: [.topLeft, .topRight, .bottomLeft, .bottomRight]),
        ShortcutGroup(id: "Thirds", actions: [.firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds]),
        ShortcutGroup(id: "Whole Screen", actions: [.maximize, .almostMaximize, .nextDisplay]),
    ]

    var body: some View {
        Group {
            if !windows.isTrusted {
                Section {
                    LabeledContent("Accessibility") {
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(.privacySettings("Privacy_Accessibility"))
                        }
                    }
                }
            }
            ForEach(Self.groups) { group in
                Section(group.id) {
                    ForEach(group.actions, id: \.self) { action in
                        KeyboardShortcuts.Recorder(action.title, name: .window(action))
                    }
                }
            }
            Section {
                Toggle("Snap windows dragged to a screen edge", isOn: $windows.snapsOnDrag)
                Picker("Gap between windows", selection: $windows.gap) {
                    ForEach([0, 4, 8, 12, 16, 24], id: \.self) { points in
                        Text(points == 0 ? "None" : "\(points) pt").tag(Double(points))
                    }
                }
            }
            Section("Layouts") {
                ForEach(windows.layouts) { layout in
                    LayoutRow(windows: windows, layout: layout)
                }
                Button("Save Current Layout") {
                    windows.saveLayout(named: "Layout \(windows.layouts.count + 1)")
                }
            }
        }
        .onAppear(perform: windows.refreshAccess)
    }
}

/// A saved layout: its name to edit, its shortcut, and what can be done with it.
private struct LayoutRow: View {
    let windows: WindowManager
    let layout: WindowLayout
    @State private var name = ""

    var body: some View {
        HStack {
            TextField("Name", text: $name)
                .labelsHidden()
                .onSubmit { windows.rename(layout, to: name) }
            KeyboardShortcuts.Recorder(for: .layout(layout.id))
            Button("Apply") { windows.apply(layout) }
            Menu {
                Button("Replace with Current Windows") { windows.updateLayout(layout) }
                Button("Delete", role: .destructive) { windows.delete(layout) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("More")
        }
        .onAppear { name = layout.name }
    }
}
