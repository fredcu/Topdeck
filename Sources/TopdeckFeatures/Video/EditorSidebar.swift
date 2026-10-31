// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckCore
import TopdeckSurface

/// The settings beside the picture, one section for each tool: Zoom and Background first, as the board has them,
/// then Crop, Speed and Audio. The tool that is out comes to the top, with its name lit.
struct EditorSidebar: View {
    @Bindable var model: EditorModel

    private var order: [EditorModel.Tool] {
        let sections: [EditorModel.Tool] =
            [.zoom, .background, .crop, .speed] + (model.audioLabels.isEmpty ? [] : [.audio])
        return sections.contains(model.tool) ? [model.tool] + sections.filter { $0 != model.tool } : sections
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(order.enumerated()), id: \.element) { index, tool in
                    if index > 0 { DeckSeparator() }
                    section(tool)
                }
            }
            .padding(.trailing, 2)
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder private func section(_ tool: EditorModel.Tool) -> some View {
        switch tool {
        case .zoom: ZoomSection(model: model)
        case .background: BackgroundSection(model: model)
        case .crop: CropSection(model: model)
        case .speed: SpeedSection(model: model)
        case .audio: AudioSection(model: model)
        case .trim: EmptyView()
        }
    }
}

/// A section's heading, in the accent while its tool is the one out.
private struct SectionHeading<Trailing: View>: View {
    let title: String
    let tool: EditorModel.Tool
    let current: EditorModel.Tool
    @ViewBuilder let trailing: Trailing
    @Environment(\.deckAccent) private var accent

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(
                current == tool ? accent : Deck.secondary)
            Spacer(minLength: 0)
            trailing
        }
        .frame(height: 22)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A name and its value, with a slider under them: "Scale 1.8×".
private struct ValueSlider: View {
    let title: String
    let value: String
    let level: Double
    let set: (Double) -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title).deckText(.detail, color: Deck.secondary)
                Spacer(minLength: 0)
                Text(value).deckText(.figure)
            }
            DeckSlider(level, label: title, value: value, set: set)
        }
    }
}

/// A small switch row: a name and a toggle.
private struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool
    var enabled = true

    var body: some View {
        HStack {
            Text(title).deckText(.detail, color: Deck.secondary)
            Spacer(minLength: 0)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(Deck.go)
                .disabled(!enabled)
        }
    }
}

// MARK: Zoom

private struct ZoomSection: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: "Zoom", tool: .zoom, current: model.tool) {
                HStack(spacing: 4) {
                    if model.selectedZoom != nil {
                        Button {
                            model.deleteSelection()
                        } label: {
                            DeckIconView(.trash, size: 12)
                        }
                        .buttonStyle(.deckIcon())
                        .help("Delete the zoom")
                        .accessibilityLabel("Delete zoom")
                    }
                    Button {
                        model.tool = .zoom
                        model.addZoom()
                    } label: {
                        DeckIconView(.plus, size: 12)
                    }
                    .buttonStyle(.deckIcon())
                    .help("Add a zoom at the playhead")
                    .accessibilityLabel("Add zoom at the playhead")
                }
            }
            if let zoom = model.selectedZoom {
                ValueSlider(
                    title: "Scale", value: String(format: "%.1f×", zoom.scale),
                    level: (zoom.scale - ZoomSegment.scaleRange.lowerBound)
                        / (ZoomSegment.scaleRange.upperBound - ZoomSegment.scaleRange.lowerBound)
                ) { level in
                    let scale =
                        ZoomSegment.scaleRange.lowerBound + level
                        * (ZoomSegment.scaleRange.upperBound - ZoomSegment.scaleRange.lowerBound)
                    model.updateZoom(zoom.id) { $0.scale = (scale * 10).rounded() / 10 }
                }
                if model.canFollowCursor {
                    SwitchRow(
                        title: "Follow cursor",
                        isOn: Binding(
                            get: { zoom.follows },
                            set: { on in model.updateZoom(zoom.id, key: "follow") { $0.follows = on } }))
                }
                if !(model.canFollowCursor && zoom.follows) {
                    TargetPicker(model: model, zoom: zoom)
                }
            }
        }
    }
}

/// Where a zoom looks when it doesn't follow the cursor: a small picture of the video to click or drag on.
private struct TargetPicker: View {
    @Bindable var model: EditorModel
    let zoom: ZoomSegment
    @Environment(\.deckAccent) private var accent

    var body: some View {
        let aspect = model.sourceSize.height > 0 ? model.sourceSize.width / model.sourceSize.height : 16.0 / 9
        GeometryReader { box in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Deck.cardRaised)
                if let still = model.stillFrame {
                    Image(decorative: still, scale: 1).resizable().scaledToFill().clipShape(
                        RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                // What the camera sees at this scale, around the target.
                let view = ZoomCamera(scale: zoom.scale, center: zoom.target).view
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(accent, lineWidth: 1.5)
                    .frame(width: view.width * box.size.width, height: view.height * box.size.height)
                    .offset(x: view.minX * box.size.width, y: view.minY * box.size.height)
                Circle().fill(accent).frame(width: 8, height: 8)
                    .offset(x: zoom.target.x * box.size.width - 4, y: zoom.target.y * box.size.height - 4)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let target = CGPoint(
                        x: min(max(value.location.x / box.size.width, 0), 1),
                        y: min(max(value.location.y / box.size.height, 0), 1))
                    model.updateZoom(zoom.id, key: "target") { $0.target = target }
                })
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: 132)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Zoom target")
        .accessibilityValue("\(Int(zoom.target.x * 100)) percent across, \(Int(zoom.target.y * 100)) percent down")
    }
}

// MARK: Background

private struct BackgroundSection: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: "Background", tool: .background, current: model.tool) { EmptyView() }
            HStack(spacing: 6) {
                swatch(.none)
                ForEach(Array(BackgroundFill.presets.enumerated()), id: \.offset) { _, fill in swatch(fill) }
            }
            ValueSlider(
                title: "Padding", value: "\(Int(model.edit.padding.rounded()))",
                level: model.edit.padding / VideoEdit.paddingRange.upperBound
            ) { level in
                model.apply("padding") { $0.padding = (level * VideoEdit.paddingRange.upperBound).rounded() }
            }
            .opacity(model.edit.background.isNone ? 0.4 : 1)
            ValueSlider(
                title: "Corners", value: "\(Int(model.edit.corners.rounded()))",
                level: model.edit.corners / VideoEdit.cornersRange.upperBound
            ) { level in
                model.apply("corners") { $0.corners = (level * VideoEdit.cornersRange.upperBound).rounded() }
            }
            .opacity(model.edit.background.isNone ? 0.4 : 1)
        }
    }

    /// One choice, 30 square, ringed when picked.
    private func swatch(_ fill: BackgroundFill) -> some View {
        let picked = model.edit.background == fill
        return Button {
            model.tool = .background
            model.apply { $0.background = fill }
        } label: {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Self.paint(fill))
                .overlay {
                    if fill.isNone {
                        Path { path in
                            path.move(to: CGPoint(x: 6, y: 24))
                            path.addLine(to: CGPoint(x: 24, y: 6))
                        }
                        .stroke(Deck.tertiary, lineWidth: 1.5)
                    }
                }
                .frame(width: 30, height: 30)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Deck.hairline, lineWidth: 1)
                )
                .padding(2.5)
                .overlay {
                    if picked {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Deck.text, lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.name(fill))
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    static func paint(_ fill: BackgroundFill) -> AnyShapeStyle {
        func color(_ hex: UInt32) -> Color {
            Color(
                .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255)
        }
        switch fill {
        case .none: return AnyShapeStyle(Deck.cardRaised)
        case .solid(let hex): return AnyShapeStyle(color(hex))
        case .gradient(let from, let to):
            return AnyShapeStyle(
                LinearGradient(colors: [color(from), color(to)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    static func name(_ fill: BackgroundFill) -> String {
        switch fill {
        case .none: "No background"
        case .solid: "Solid background"
        case .gradient: "Gradient background"
        }
    }
}

// MARK: Crop

private struct CropSection: View {
    @Bindable var model: EditorModel

    /// Width over height of each preset.
    private static let shapes: [(title: String, aspect: Double)] = [
        ("16:9", 16.0 / 9), ("4:3", 4.0 / 3), ("1:1", 1), ("9:16", 9.0 / 16),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: "Crop", tool: .crop, current: model.tool) {
                if !model.edit.crop.isFull {
                    Button {
                        model.apply { $0.crop = .full }
                    } label: {
                        DeckIconView(.undo, size: 12)
                    }
                    .buttonStyle(.deckIcon())
                    .help("Show the whole picture")
                    .accessibilityLabel("Reset crop")
                }
            }
            HStack(spacing: 5) {
                ForEach(Self.shapes, id: \.title) { shape in
                    Button(shape.title) {
                        model.tool = .crop
                        model.apply { $0.crop = CropDrag.centered(aspect: shape.aspect, in: model.sourceSize) }
                    }
                    .buttonStyle(.deckPill(on: false))
                }
            }
        }
    }
}

// MARK: Speed

private struct SpeedSection: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: "Speed", tool: .speed, current: model.tool) {
                HStack(spacing: 4) {
                    if model.selectedSpeed != nil {
                        Button {
                            model.deleteSelection()
                        } label: {
                            DeckIconView(.trash, size: 12)
                        }
                        .buttonStyle(.deckIcon())
                        .help("Delete the speed change")
                        .accessibilityLabel("Delete speed change")
                    }
                    Button {
                        model.tool = .speed
                        model.addSpeed()
                    } label: {
                        DeckIconView(.plus, size: 12)
                    }
                    .buttonStyle(.deckIcon())
                    .help("Add a speed change at the playhead")
                    .accessibilityLabel("Add speed change at the playhead")
                }
            }
            if let speed = model.selectedSpeed {
                DeckFlow(spacing: 5) {
                    ForEach(SpeedSegment.presets, id: \.self) { rate in
                        Button(Self.title(rate)) { model.updateSpeed(speed.id) { $0.rate = rate } }
                            .buttonStyle(.deckPill(on: speed.rate == rate))
                    }
                }
            }
        }
    }

    static func title(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%g×", rate)
    }
}

// MARK: Audio

private struct AudioSection: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: "Audio", tool: .audio, current: model.tool) { EmptyView() }
            ForEach(Array(model.audioLabels.enumerated()), id: \.offset) { index, label in
                let setting = model.edit.audioSetting(index)
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Text(label).deckText(.detail, color: Deck.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(setting.muted ? "Off" : "\(Int((setting.volume * 100).rounded()))%").deckText(.figure)
                        Button {
                            model.tool = .audio
                            model.apply {
                                $0.setAudio(AudioTrackSetting(volume: setting.volume, muted: !setting.muted), at: index)
                            }
                        } label: {
                            DeckIconView(.volume, size: 13)
                        }
                        .buttonStyle(.deckIcon(on: setting.muted))
                        .help(setting.muted ? "Turn \(label) on" : "Mute \(label)")
                        .accessibilityLabel(setting.muted ? "Unmute \(label)" : "Mute \(label)")
                    }
                    DeckSlider(
                        setting.volume / AudioTrackSetting.volumeRange.upperBound, label: "\(label) volume",
                        value: "\(Int((setting.volume * 100).rounded())) percent", enabled: !setting.muted
                    ) { level in
                        model.apply("volume-\(index)") {
                            $0.setAudio(
                                AudioTrackSetting(
                                    volume: (level * AudioTrackSetting.volumeRange.upperBound * 20).rounded() / 20,
                                    muted: false),
                                at: index)
                        }
                    }
                }
            }
        }
    }
}
