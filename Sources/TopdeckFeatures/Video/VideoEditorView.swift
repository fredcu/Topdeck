// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import TopdeckSurface

/// The video editor, as the `Editor3` board draws it: the file's name with the format and Export in the title
/// bar, the picture beside its settings, and the timeline under both.
struct VideoEditorView: View {
    @Bindable var model: EditorModel
    var reveal: (URL) -> Void = { _ in }
    var chooseFile: () -> URL? = { nil }
    @State private var showsExport = false

    var body: some View {
        VStack(spacing: 0) {
            titleBar
                .padding(.leading, 84)
                .padding(.trailing, 14)
                .frame(height: 48)
            DeckSeparator()
            HStack(spacing: 14) {
                EditorPreview(model: model)
                EditorSidebar(model: model).frame(width: 204)
            }
            .padding(14)
            EditorTimeline(model: model)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
        .background(Deck.body)
        .environment(\.colorScheme, .dark)
        .environment(\.deckAccent, Deck.Accent.tools)
        // Over the picture's top, clear of the timeline and the title bar.
        .overlay(alignment: .top) { ExportBanner(model: model, reveal: reveal).padding(.top, 62) }
    }

    private var titleBar: some View {
        HStack(spacing: 6) {
            Text(model.url.lastPathComponent)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Deck.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            ForEach([ExportFormat.gif, .mp4], id: \.self) { format in
                Button(format.title) { model.setFormat(format) }
                    .buttonStyle(.deckPill(on: model.edit.export.format == format))
                    .frame(height: 28)
                    .accessibilityAddTraits(model.edit.export.format == format ? .isSelected : [])
            }
            Button("Export") { showsExport.toggle() }
                .buttonStyle(.deck(.primary))
                .disabled(model.phase != .ready || model.isExporting)
                .deckPopover(isPresented: $showsExport) {
                    ExportOptions(model: model) { chosen in
                        showsExport = false
                        model.export(to: chosen)
                    } chooseFile: {
                        chooseFile()
                    }
                    .environment(\.deckAccent, Deck.Accent.tools)
                }
        }
    }
}

/// Size and quality, and where to save: beside the source unless Save As says otherwise.
private struct ExportOptions: View {
    @Bindable var model: EditorModel
    let start: (URL?) -> Void
    let chooseFile: () -> URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Size").font(.system(size: 12, weight: .semibold)).foregroundStyle(Deck.secondary)
            HStack(spacing: 5) {
                ForEach(ExportSize.allCases, id: \.self) { size in
                    DeckChip(size.title, selected: model.edit.export.size == size) {
                        model.apply { $0.export.size = size }
                    }
                }
            }
            Text("Quality").font(.system(size: 12, weight: .semibold)).foregroundStyle(Deck.secondary)
            HStack(spacing: 5) {
                ForEach(ExportQuality.allCases, id: \.self) { quality in
                    DeckChip(quality.title, selected: model.edit.export.quality == quality) {
                        model.apply { $0.export.quality = quality }
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Save As…") {
                    if let url = chooseFile() { start(url) }
                }
                .buttonStyle(.deck())
                Spacer(minLength: 0)
                Button("Export") { start(nil) }.buttonStyle(.deck(.primary))
            }
        }
        .padding(Deck.Metric.cardPadding)
        .frame(width: 280)
    }
}

/// Progress of an export, with Cancel; then where it went, with Reveal.
private struct ExportBanner: View {
    @Bindable var model: EditorModel
    let reveal: (URL) -> Void

    var body: some View {
        Group {
            switch model.exportState {
            case .idle:
                EmptyView()
            case .running(let progress):
                banner {
                    ProgressView(value: progress).progressViewStyle(.linear).tint(Deck.Accent.tools).frame(width: 160)
                        .accessibilityLabel("Exporting")
                        .accessibilityValue("\(Int(progress * 100)) percent")
                    Button("Cancel") { model.cancelExport() }.buttonStyle(.deck(compact: true))
                }
            case .done(let url):
                banner {
                    DeckIconView(.check, size: 13).foregroundStyle(Deck.go)
                    Text(url.lastPathComponent).deckText(.body).lineLimit(1).truncationMode(.middle).frame(
                        maxWidth: 260)
                    Button("Reveal") { reveal(url) }.buttonStyle(.deck(.primary, compact: true))
                    Button {
                        model.dismissExport()
                    } label: {
                        DeckIconView(.close, size: 12)
                    }
                    .buttonStyle(.deckIcon())
                    .accessibilityLabel("Dismiss")
                }
            case .failed(let message):
                banner {
                    Text(message).deckText(.body, color: Deck.stop)
                    Button {
                        model.dismissExport()
                    } label: {
                        DeckIconView(.close, size: 12)
                    }
                    .buttonStyle(.deckIcon())
                    .accessibilityLabel("Dismiss")
                }
            }
        }
    }

    private func banner<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: Deck.Radius.card, style: .continuous).fill(Deck.cardRaised))
            .overlay(
                RoundedRectangle(cornerRadius: Deck.Radius.card, style: .continuous).strokeBorder(
                    Deck.hairline, lineWidth: 1)
            )
            .shadow(color: Deck.deck.opacity(0.5), radius: 12, y: 4)
    }
}
