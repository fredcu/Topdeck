// SPDX-License-Identifier: MIT
import NotchCore
import SwiftUI

/// A tab on the move in the editor.
struct TabDrag: Equatable {
    var feature: FeatureID
    /// It was picked up in the row; otherwise it came from the tray of apps off the row.
    var fromRow: Bool
    /// Its index in the row if it were dropped now; nil while it's off the row.
    var slot: Int?
}

/// The open notch's tab row in edit mode, like iOS's jiggling Home Screen: the tabs wiggle and drag
/// into a new order, or down into the tray below, which holds the apps kept in the drawer (and those
/// turned off, dimmed); one clicks or drags back into the row. Every change applies at once, so the
/// row is always what the notch will show, and a tab flies between the row and the tray. Done ends
/// editing.
struct TabEditor: View {
    let preferences: NotchPreferences
    /// The width the tabs share, as outside edit mode, so they keep their size.
    let room: CGFloat
    let done: () -> Void

    /// A place in the row: a tab, or the gap a hidden tab would drop into.
    enum Place: Hashable {
        case tab(FeatureID)
        case gap
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var flight
    @State private var drag: TabDrag?
    /// Where the pointer is while dragging, which the lifted tab follows without animation.
    @State private var pointer = CGPoint.zero
    @State private var headerFrame = CGRect.zero
    @State private var rowFrame = CGRect.zero
    @State private var trayFrame = CGRect.zero

    fileprivate nonisolated static let space = "TabEditor"

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: NotchView.tabSpacing) {
                row
                Spacer(minLength: 0)
                doneButton
            }
            .reportsFrame { headerFrame = $0 }
            tray
        }
        .coordinateSpace(.named(Self.space))
        .overlay(alignment: .topLeading) { lifted }
    }

    // MARK: The row

    private var row: some View {
        let places = Self.places(preferences.rowTabs, during: drag)
        let width = NotchView.tabWidth(count: places.count, room: room)
        let removable = preferences.rowTabs.count > 1  // the row keeps at least one tab
        return HStack(spacing: NotchView.tabSpacing) {
            ForEach(places, id: \.self) { place in
                switch place {
                case .gap:
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .frame(width: width, height: 26)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                case .tab(let feature):
                    rowTab(feature, width: width, removable: removable)
                }
            }
        }
        .reportsFrame { rowFrame = $0 }
    }

    private func rowTab(_ feature: FeatureID, width: CGFloat, removable: Bool) -> some View {
        let lifted = drag?.feature == feature
        return TablerIcon(name: feature.icon)
            .frame(width: width, height: 26)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(alignment: .topLeading) {
                if removable, !lifted {
                    badge("minus", tint: Color(white: 0.32), label: "Keep \(feature.title) in the drawer") {
                        hide(feature)
                    }
                    .offset(x: -5, y: -5)
                }
            }
            .modifier(Wiggle(still: reduceMotion || drag != nil, pace: feature))
            .opacity(lifted ? 0 : 1)  // it keeps its place while the lifted one follows the pointer
            .matchedGeometryEffect(id: feature, in: flight)
            .contentShape(Rectangle())
            .gesture(dragging(feature, fromRow: true))
            .help(feature.title)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(feature.title)
            .accessibilityHint("Drag to move it, or down to keep it in the drawer.")
            .accessibilityAction(named: "Move Left") { move(feature, by: -1) }
            .accessibilityAction(named: "Move Right") { move(feature, by: 1) }
            .accessibilityAction(named: "Keep in the Drawer") { hide(feature) }
    }

    private var doneButton: some View {
        Button(action: done) {
            Text("Done")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 12)
                .frame(height: 22)
                .background(.white, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Done editing tabs")
    }

    // MARK: The tray

    private var tray: some View {
        let row = preferences.rowTabs
        let hidden = preferences.tabOrder.filter { !row.contains($0) }
        let hiding = drag?.fromRow == true && trayFrame.contains(pointer)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(hidden.isEmpty ? "Every app is in the row" : "In the drawer")
                Spacer(minLength: 0)
                Text(hiding ? "Drop to keep it in the drawer" : "Drag to reorder, or down into the drawer")
                    .foregroundStyle(.white.opacity(hiding ? 0.9 : 0.4))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
            ScrollView(.vertical) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 62, maximum: 62), spacing: 6)], alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(hidden, id: \.self, content: tile)
                }
                .padding(.top, 5)
            }
            .scrollIndicators(.never)
            .scrollDisabled(hidden.count < 6)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(hiding ? 0.1 : 0.04), in: shape)
        .overlay(
            shape.strokeBorder(
                .white.opacity(hiding ? 0.45 : 0.14), style: StrokeStyle(lineWidth: 1, dash: hiding ? [] : [4, 3]))
        )
        .reportsFrame { trayFrame = $0 }
        .animation(.easeOut(duration: 0.15), value: hiding)
    }

    /// An app off the row; one that's off shows dimmed, and adding it turns it on.
    private func tile(_ feature: FeatureID) -> some View {
        let off = !preferences.isEnabled(feature)
        return VStack(spacing: 4) {
            AppIcon(feature: feature)
                .overlay(alignment: .topTrailing) {
                    badge("plus", tint: .green, label: "Add \(feature.title) to the row") { show(feature) }
                        .offset(x: 5, y: -5)
                }
                .matchedGeometryEffect(id: feature, in: flight)
            Text(feature.title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
        }
        .frame(width: 60)
        .opacity(drag?.feature == feature ? 0.25 : off ? 0.45 : 1)
        .contentShape(Rectangle())
        .onTapGesture { show(feature) }
        .gesture(dragging(feature, fromRow: false))
        .help(off ? "Turn \(feature.title) on and add it to the row" : "Add \(feature.title) to the row")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(off ? "\(feature.title), off" : feature.title)
        .accessibilityHint("Adds it to the tab row.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { show(feature) }
    }

    /// A small round button on a tab's corner: minus to hide it, plus to show it.
    private func badge(_ symbol: String, tint: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(tint, in: Circle())
                .overlay(Circle().strokeBorder(.black.opacity(0.6), lineWidth: 1))
                .contentShape(Circle().inset(by: -3))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: Dragging

    /// The tab under the pointer, a little larger and lifted off the notch.
    @ViewBuilder private var lifted: some View {
        if let drag {
            TablerIcon(name: drag.feature.icon, size: 18)
                .frame(width: 42, height: 34)
                .background(.white.opacity(0.24), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(
                        .white.opacity(0.4), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.55), radius: 10, y: 5)
                .position(pointer)
                .allowsHitTesting(false)
                .transition(.scale(scale: 0.7).combined(with: .opacity))
        }
    }

    private func dragging(_ feature: FeatureID, fromRow: Bool) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                pointer = value.location
                // An app from the tray over the row opens a gap, so the row has one more place.
                let count = preferences.rowTabs.count + (fromRow ? 0 : 1)
                let overRow = headerFrame.insetBy(dx: 0, dy: -14).contains(value.location)
                let slot =
                    overRow
                    ? Self.slot(
                        at: value.location.x, from: rowFrame.minX, width: NotchView.tabWidth(count: count, room: room),
                        count: count) : nil
                let moved = TabDrag(feature: feature, fromRow: fromRow, slot: slot)
                guard moved != drag else { return }
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.72)) { drag = moved }
            }
            .onEnded { value in drop(at: value.location) }
    }

    private func drop(at location: CGPoint) {
        guard let drag else { return }
        withAnimation(motion) {
            if let slot = drag.slot {
                preferences.place(drag.feature, at: slot)
            } else if drag.fromRow, trayFrame.contains(location), preferences.rowTabs.count > 1 {
                preferences.moveToDrawer(drag.feature)
            }
            self.drag = nil
        }
    }

    /// Off the row, still on, into the drawer.
    private func hide(_ feature: FeatureID) {
        guard preferences.rowTabs.count > 1 else { return }
        withAnimation(motion) { preferences.moveToDrawer(feature) }
    }

    private func show(_ feature: FeatureID) {
        withAnimation(motion) { preferences.place(feature, at: preferences.rowTabs.count) }
    }

    private func move(_ feature: FeatureID, by offset: Int) {
        guard let index = preferences.rowTabs.firstIndex(of: feature) else { return }
        withAnimation(motion) { preferences.place(feature, at: index + offset) }
    }

    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.78) }

    /// The row as it would be if the drag ended now: the dragged tab in its slot, or a gap where a
    /// hidden tab would join; a tab dragged off the row leaves it.
    static func places(_ tabs: [FeatureID], during drag: TabDrag?) -> [Place] {
        var places = tabs.map(Place.tab)
        guard let drag else { return places }
        places.removeAll { $0 == .tab(drag.feature) }
        if let slot = drag.slot {
            places.insert(drag.fromRow ? .tab(drag.feature) : .gap, at: min(max(slot, 0), places.count))
        }
        return places
    }

    /// The place under the pointer, in a row of `count` places of `width` starting at `start`.
    static func slot(at x: CGFloat, from start: CGFloat, width: CGFloat, count: Int) -> Int {
        guard count > 0, width > 0 else { return 0 }
        let place = Int(((x - start) / (width + NotchView.tabSpacing)).rounded(.down))
        return min(max(place, 0), count - 1)
    }
}

extension View {
    /// Reports the view's frame in the editor's coordinates as it changes, for dropping tabs on it.
    fileprivate func reportsFrame(_ action: @escaping (CGRect) -> Void) -> some View {
        onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(TabEditor.space))
        } action: {
            action($0)
        }
    }
}

/// The rock of a tab waiting to be moved, each at its own pace so the row doesn't move in step.
private struct Wiggle: ViewModifier {
    /// While dragging, and with Reduce Motion, the tabs hold still.
    let still: Bool
    let pace: FeatureID

    func body(content: Content) -> some View {
        let beat = 0.12 + 0.011 * Double((FeatureID.allCases.firstIndex(of: pace) ?? 0) % 5)
        content.phaseAnimator([-1.0, 1.0]) { view, side in
            view.rotationEffect(.degrees(still ? 0 : side * 1.8))
        } animation: { _ in
            .easeInOut(duration: beat)
        }
    }
}
