// SPDX-License-Identifier: MIT
import AVFoundation
import AppKit
import SwiftUI
import TopdeckSurface

/// The picture as it will be exported, fitted into the room it has. While the Crop tool is out it shows the whole
/// picture with the crop rectangle on it, to drag.
struct EditorPreview: View {
    @Bindable var model: EditorModel

    var body: some View {
        GeometryReader { room in
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Deck.card)
                switch model.phase {
                case .loading: Color.clear
                case .failed(let message): DeckEmptyLine(message)
                case .ready:
                    if let layout = model.previewLayout {
                        let size = Self.fitted(layout.canvas, in: room.size)
                        picture(layout)
                            .frame(width: size.width, height: size.height)
                    }
                }
            }
        }
    }

    /// `canvas` scaled to the largest size that fits `room`.
    static func fitted(_ canvas: CGSize, in room: CGSize) -> CGSize {
        guard canvas.width > 0, canvas.height > 0 else { return .zero }
        let scale = min(room.width / canvas.width, room.height / canvas.height)
        return CGSize(width: (canvas.width * scale).rounded(.down), height: (canvas.height * scale).rounded(.down))
    }

    private func picture(_ layout: FrameLayout) -> some View {
        ZStack {
            // What the edit draws of the first frame, under the player, which covers it once it has a picture.
            if let still = model.previewStill {
                Image(decorative: still, scale: 1).resizable().interpolation(.medium)
            }
            PlayerLayerView(player: model.player)
            if model.tool == .crop { CropOverlay(model: model) }
        }
        .clipShape(RoundedRectangle(cornerRadius: model.tool == .crop ? 0 : 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if model.tool != .crop { model.togglePlay() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video preview")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: model.isPlaying ? "Pause" : "Play") { model.togglePlay() }
    }
}

/// An `AVPlayerLayer` for the editor's player.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerHostView { PlayerHostView(player: player) }

    func updateNSView(_ view: PlayerHostView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerHostView: NSView {
        let playerLayer = AVPlayerLayer()

        init(player: AVPlayer) {
            super.init(frame: .zero)
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspect
            layer = playerLayer
            wantsLayer = true
        }

        required init?(coder: NSCoder) { nil }
    }
}

/// The crop rectangle over the whole picture: dimmed outside, an outline in the accent, a handle at each corner,
/// and the inside to move it by.
private struct CropOverlay: View {
    @Bindable var model: EditorModel
    @Environment(\.deckAccent) private var accent
    @State private var start: CropRegion?

    private static let handle: CGFloat = 14

    var body: some View {
        GeometryReader { box in
            let crop = model.edit.crop
            let rect = CGRect(
                x: crop.x * box.size.width, y: crop.y * box.size.height, width: crop.width * box.size.width,
                height: crop.height * box.size.height)
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: box.size))
                    path.addRect(rect)
                }
                .fill(Deck.deck.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                Rectangle()
                    .strokeBorder(accent, lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .contentShape(Rectangle())
                    .gesture(drag(.move, in: box.size))
                    .offset(x: rect.minX, y: rect.minY)
                    .accessibilityLabel("Crop area")
                corner(.topLeft, at: CGPoint(x: rect.minX, y: rect.minY), in: box.size)
                corner(.topRight, at: CGPoint(x: rect.maxX, y: rect.minY), in: box.size)
                corner(.bottomLeft, at: CGPoint(x: rect.minX, y: rect.maxY), in: box.size)
                corner(.bottomRight, at: CGPoint(x: rect.maxX, y: rect.maxY), in: box.size)
            }
        }
    }

    private func corner(_ handle: CropDrag.Handle, at point: CGPoint, in size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(accent)
            .frame(width: Self.handle, height: Self.handle)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Deck.deck.opacity(0.5), lineWidth: 1)
            )
            .contentShape(Rectangle().inset(by: -6))
            .gesture(drag(handle, in: size))
            .offset(x: point.x - Self.handle / 2, y: point.y - Self.handle / 2)
            .accessibilityLabel("Crop corner")
    }

    private func drag(_ handle: CropDrag.Handle, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let origin = start ?? model.edit.crop
                start = origin
                let delta = CGSize(
                    width: value.translation.width / size.width, height: value.translation.height / size.height)
                model.apply("crop") { $0.crop = CropDrag.dragged(origin, handle: handle, by: delta) }
            }
            .onEnded { _ in start = nil }
    }
}
