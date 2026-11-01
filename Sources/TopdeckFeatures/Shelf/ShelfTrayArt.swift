// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import TopdeckSurface

/// Three file cards in kind colours, fanned, dropping into an open tray: the empty shelf's illustration and
/// the Add Files button's icon. Drawn in a 132 by 96 space and scaled to the frame it is given.
/// `detail` is the large version, with the lines, play triangle and text bars on the cards; without it the
/// art is cropped square, keeps every shape and colour, and drops those details (all but the picture block)
/// and thickens the tray's edge and rim, which at icon size would only blur. `hot` is a file being dragged
/// over: the cards sit lower and the tray lights in the accent.
struct ShelfTrayArt: View {
    let detail: Bool
    var hot = false
    @Environment(\.deckAccent) private var accent

    private static let space = CGSize(width: 132, height: 96)
    private static let square = CGRect(x: 16, y: -3, width: 100, height: 100)

    var body: some View {
        let crop = detail ? CGRect(origin: .zero, size: Self.space) : Self.square
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) { illustration }
                .frame(width: Self.space.width, height: Self.space.height, alignment: .topLeading)
                .offset(x: -crop.minX, y: -crop.minY)
                .frame(width: crop.width, height: crop.height, alignment: .topLeading)
                .scaleEffect(proxy.size.width / crop.width, anchor: .topLeading)
        }
        .aspectRatio(crop.size, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var illustration: some View {
        let drop: CGFloat = hot ? 6 : 0
        return ZStack(alignment: .topLeading) {
            sideCard(Deck.Kind.sheet, rotation: -12, at: CGPoint(x: hot ? 28 : 32, y: 16 + drop)) { lines }
            sideCard(Deck.Kind.video, rotation: 12, at: CGPoint(x: hot ? 64 : 62, y: 16 + drop)) { play }
            front.offset(x: 47, y: 6 + drop)
            tray
        }
    }

    // MARK: Cards

    /// A side card in the colour of a kind of file, lighter at its top left than at its bottom right.
    private func sideCard<Mark: View>(
        _ color: Color, rotation: Double, at origin: CGPoint, @ViewBuilder mark: () -> Mark
    ) -> some View {
        card(
            width: 36, height: 46, from: color.mixed(with: .white, by: 0.14), to: color.mixed(with: .black, by: 0.25),
            content: mark
        )
        .rotationEffect(.degrees(rotation), anchor: UnitPoint(x: 0.5, y: 24 / 46))
        .offset(x: origin.x, y: origin.y)
    }

    private var front: some View {
        let image = Deck.Kind.image
        return card(
            width: 38, height: 48, from: image.mixed(with: Deck.Kind.rose, by: 0.85),
            to: image.mixed(with: Deck.Kind.rose, by: 0.2).mixed(with: .black, by: 0.2)
        ) {
            RoundedRectangle(cornerRadius: detail ? 3 : 4, style: .continuous)
                .fill(.white.opacity(detail ? 0.35 : 0.4))
                .frame(width: 26, height: 20)
                .offset(x: 6, y: 7)
            if detail {
                bar(width: 18, y: 32, opacity: 0.55)
                bar(width: 12, y: 38, opacity: 0.4)
            }
        }
    }

    private func card<Content: View>(
        width: CGFloat, height: CGFloat, from: Color, to: Color, @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack(alignment: .topLeading) { content() }
            .frame(width: width, height: height, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(colors: [from, to], startPoint: .topLeading, endPoint: .bottomTrailing)))
    }

    private func bar(width: CGFloat, y: CGFloat, opacity: Double) -> some View {
        Capsule().fill(.white.opacity(opacity)).frame(width: width, height: 3).offset(x: 6, y: y)
    }

    @ViewBuilder private var lines: some View {
        if detail {
            Path { path in
                for (y, width) in [(12.0, 12.0), (18, 16), (24, 10)] {
                    path.move(to: CGPoint(x: 7, y: y))
                    path.addLine(to: CGPoint(x: 7 + width, y: y))
                }
            }
            .stroke(.white.opacity(0.5), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
    }

    @ViewBuilder private var play: some View {
        if detail {
            Path { path in
                path.move(to: CGPoint(x: 14, y: 17))
                path.addLine(to: CGPoint(x: 14, y: 29))
                path.addLine(to: CGPoint(x: 24, y: 23))
                path.closeSubpath()
            }
            .fill(.white.opacity(0.6))
        }
    }

    // MARK: Tray

    /// The tray, over the cards' lower part: a trapezoid with rounded bottom corners and a rim along its top.
    private var tray: some View {
        let edge = hot ? accent : Deck.secondary.opacity(detail ? 0.22 : 0.45)
        let rim = hot ? accent : Deck.secondary.opacity(detail ? 0.35 : 0.7)
        return ZStack(alignment: .topLeading) {
            Self.trayShape.fill(Deck.cardRaised)
            if hot { Self.trayShape.fill(accent.tint(0.14)) }
            Self.trayShape.stroke(edge, lineWidth: detail ? 1.5 : 3)
            Path { path in
                path.move(to: CGPoint(x: 18, y: 60))
                path.addLine(to: CGPoint(x: 114, y: 60))
            }
            .stroke(rim, style: StrokeStyle(lineWidth: detail ? 2 : 4, lineCap: .round))
        }
    }

    private static var trayShape: Path {
        Path { path in
            path.move(to: CGPoint(x: 18, y: 60))
            path.addLine(to: CGPoint(x: 114, y: 60))
            path.addLine(to: CGPoint(x: 106, y: 90))
            path.addQuadCurve(to: CGPoint(x: 100.2, y: 94.5), control: CGPoint(x: 104.8, y: 94.5))
            path.addLine(to: CGPoint(x: 31.8, y: 94.5))
            path.addQuadCurve(to: CGPoint(x: 26, y: 90), control: CGPoint(x: 27.2, y: 94.5))
            path.closeSubpath()
        }
    }
}

extension Color {
    /// This colour with `amount` (0 to 1) of `other` mixed in, in sRGB.
    fileprivate func mixed(with other: Color, by amount: Double) -> Color {
        let space = NSColorSpace.sRGB
        guard let from = NSColor(self).usingColorSpace(space), let to = NSColor(other).usingColorSpace(space),
            let mix = from.blended(withFraction: amount, of: to)
        else { return self }
        return Color(nsColor: mix)
    }
}
