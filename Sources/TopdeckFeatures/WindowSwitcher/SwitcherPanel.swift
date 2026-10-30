// SPDX-License-Identifier: MIT
// Adapted from OmniMac's WindowSwitcher (https://github.com/BySergiMM/OmniMac), Copyright (c) 2026
// Sergi (BySergiMM), MIT License.
import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI

@MainActor
@Observable
final class SwitcherModel {
    var all: [SwitcherEntry] = []
    var query = ""
    var selection = 0
    var columns = 1
    var thumbnails: [CGWindowID: NSImage] = [:]
    var icons: [pid_t: NSImage] = [:]
    var windowIDs: [Int: CGWindowID] = [:]
    var showsThumbnails = false
    var itemSize: CGSize { showsThumbnails ? CGSize(width: 210, height: 150) : CGSize(width: 140, height: 112) }

    var shown: [SwitcherEntry] { SwitcherList.filter(all, query: query) }
    var selected: SwitcherEntry? { shown.indices.contains(selection) ? shown[selection] : nil }

    static let spacing: CGFloat = 8
    static let padding: CGFloat = 16
    static let headerHeight: CGFloat = 30
}

/// The panel that shows the windows. It takes the keyboard without activating Topdeck, so the app
/// in front stays in front until a window is picked.
@MainActor
final class SwitcherPanelController {
    var onClick: (() -> Void)?
    var onResign: (() -> Void)?

    private let model = SwitcherModel()
    private var panel: SwitcherPanel?
    private var capture: Task<Void, Never>?

    var isVisible: Bool { panel?.isVisible ?? false }
    var selected: SwitcherEntry? { model.selected }

    func show(entries: [SwitcherEntry], windowIDs: [Int: CGWindowID], captures: Bool, initial: Int) {
        model.all = entries
        model.query = ""
        model.windowIDs = windowIDs
        model.thumbnails = [:]
        model.showsThumbnails = captures
        model.icons = Dictionary(
            entries.map(\.pid).map { ($0, NSRunningApplication(processIdentifier: $0)?.icon) }.compactMap {
                pid, icon in icon.map { (pid, $0) }
            }, uniquingKeysWith: { first, _ in first })
        model.selection = max(0, min(initial, entries.count - 1))
        let panel = self.panel ?? makePanel()
        self.panel = panel
        relayout()
        panel.orderFrontRegardless()
        panel.makeKey()
        if captures { captureThumbnails(Set(windowIDs.values)) }
    }

    func hide() {
        capture?.cancel()
        capture = nil
        panel?.orderOut(nil)
        model.all = []
        model.thumbnails = [:]
        model.icons = [:]
    }

    func move(_ delta: Int) {
        model.selection = SwitcherSelection.step(model.selection, by: delta, count: model.shown.count)
    }

    func moveRow(_ rows: Int) {
        model.selection = SwitcherSelection.row(
            model.selection, by: rows, columns: model.columns, count: model.shown.count)
    }

    func type(_ text: String) {
        model.query += text
        filtered()
    }

    func deleteBackward() {
        guard !model.query.isEmpty else { return }
        model.query.removeLast()
        filtered()
    }

    private func filtered() {
        model.selection = 0
        relayout()
    }

    /// Windows are captured one after another, only now that the switcher is showing, and appear as
    /// they arrive. The app's icon stands in until then.
    private func captureThumbnails(_ ids: Set<CGWindowID>) {
        capture?.cancel()
        capture = Task { [model] in
            guard
                let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            else { return }
            for window in content.windows where ids.contains(window.windowID) {
                if Task.isCancelled { return }
                let configuration = SCStreamConfiguration()
                let scale = min(1, 400 / max(1, window.frame.width, window.frame.height))
                configuration.width = Int(window.frame.width * scale) * 2
                configuration.height = Int(window.frame.height * scale) * 2
                configuration.showsCursor = false
                configuration.ignoreShadowsSingleWindow = true
                let filter = SCContentFilter(desktopIndependentWindow: window)
                guard
                    let image = try? await SCScreenshotManager.captureImage(
                        contentFilter: filter, configuration: configuration)
                else { continue }
                model.thumbnails[window.windowID] = NSImage(
                    cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
            }
        }
    }

    private func relayout() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = model.itemSize
        let count = max(1, model.shown.count)
        let usable = screen.visibleFrame.width * 0.85 - SwitcherModel.padding * 2 + SwitcherModel.spacing
        let columns = min(count, max(1, Int(usable / (size.width + SwitcherModel.spacing))))
        let rows = min(4, (count + columns - 1) / columns)
        model.columns = columns
        let width = max(
            360,
            CGFloat(columns) * (size.width + SwitcherModel.spacing) - SwitcherModel.spacing + SwitcherModel.padding * 2)
        let height =
            SwitcherModel.headerHeight + CGFloat(rows) * (size.height + SwitcherModel.spacing) + SwitcherModel.padding
        panel.setFrame(
            CGRect(x: screen.frame.midX - width / 2, y: screen.frame.midY - height / 2, width: width, height: height),
            display: true)
    }

    private func makePanel() -> SwitcherPanel {
        let panel = SwitcherPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.level = .popUpMenu  // after isFloatingPanel, which resets it
        panel.onResign = { [weak self] in self?.onResign?() }
        panel.contentView = NSHostingView(
            rootView: SwitcherView(model: model) { [weak self] index in
                guard let self else { return }
                model.selection = index
                onClick?()
            })
        return panel
    }
}

private final class SwitcherPanel: NSPanel {
    var onResign: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}

// MARK: Views

private struct SwitcherView: View {
    let model: SwitcherModel
    let onClick: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(model.query.isEmpty ? .tertiary : .secondary)
                Text(model.query).font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: SwitcherModel.headerHeight)
            .padding(.top, 8)
            if model.shown.isEmpty {
                Text("No matches").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.fixed(model.itemSize.width), spacing: SwitcherModel.spacing),
                                count: max(1, model.columns)),
                            spacing: SwitcherModel.spacing
                        ) {
                            ForEach(Array(model.shown.enumerated()), id: \.element.id) { index, entry in
                                SwitcherItem(
                                    entry: entry, icon: model.icons[entry.pid],
                                    thumbnail: model.windowIDs[entry.id].flatMap { model.thumbnails[$0] },
                                    showsThumbnail: model.showsThumbnails, isSelected: index == model.selection,
                                    size: model.itemSize
                                )
                                .id(index)
                                .onTapGesture { onClick(index) }
                            }
                        }
                        .padding(.horizontal, SwitcherModel.padding)
                        .padding(.bottom, SwitcherModel.padding)
                    }
                    .onChange(of: model.selection) { _, index in proxy.scrollTo(index) }
                }
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }
}

private struct SwitcherItem: View {
    let entry: SwitcherEntry
    let icon: NSImage?
    let thumbnail: NSImage?
    let showsThumbnail: Bool
    let isSelected: Bool
    let size: CGSize

    var body: some View {
        VStack(spacing: 6) {
            if showsThumbnail {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let thumbnail {
                            Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.06))
                                iconView.frame(width: 46, height: 46)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    if thumbnail != nil { iconView.frame(width: 26, height: 26).padding(4) }
                }
            } else {
                iconView.frame(width: 56, height: 56)
            }
            Text(entry.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(showsThumbnail ? 1 : 2)
                .multilineTextAlignment(.center)
        }
        .overlay(alignment: .topTrailing) {
            if entry.isMinimized {
                Image(systemName: "arrow.down.forward.square.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .orange)
                    .accessibilityLabel("Minimized")
            }
        }
        .padding(8)
        .frame(width: size.width, height: size.height)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(
                isSelected ? Color.primary.opacity(0.18) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var iconView: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "macwindow").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
    }
}
