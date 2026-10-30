// SPDX-License-Identifier: MIT
// Reading order and the QR code request are adapted from capcap's OCRService and QRCodeDetector (MIT),
// Copyright (c) 2026 realskyrin; see THIRD_PARTY_NOTICES.md.
import CoreGraphics
import Vision

/// A piece of text Vision found, with its box in Vision's coordinates: 0–1 across the image, from
/// the bottom left.
struct TextFragment: Equatable, Sendable {
    let text: String
    let box: CGRect
}

/// Text and QR codes in a capture, read on this Mac with Vision. Both run synchronously: call them
/// off the main thread.
enum TextRecognition {
    static let languages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]

    /// The text in `image`, a line per line on screen, top to bottom.
    static func text(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = languages
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return ""
        }
        let fragments = (request.results ?? []).compactMap { observation -> TextFragment? in
            guard let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces),
                !text.isEmpty
            else { return nil }
            return TextFragment(text: text, box: observation.boundingBox)
        }
        return readingOrder(fragments).joined(separator: "\n")
    }

    /// Fragments in reading order, joined into lines. Fragments share a line when they overlap by at
    /// least half the shorter one's height, so a title with wide gaps stays one line instead of
    /// turning into a column. A gap wider than three characters becomes a tab.
    static func readingOrder(_ fragments: [TextFragment]) -> [String] {
        let sorted = fragments.sorted {
            $0.box.midY != $1.box.midY ? $0.box.midY > $1.box.midY : $0.box.minX < $1.box.minX
        }
        var rows: [[TextFragment]] = []
        for fragment in sorted {
            let box = fragment.box
            let matching = rows.indices.filter { index in
                let reference = rows[index][0].box
                let height = min(box.height, reference.height)
                let overlap = min(box.maxY, reference.maxY) - max(box.minY, reference.minY)
                return height > 0 && overlap >= height * 0.5 && abs(box.midY - reference.midY) <= height * 0.5
            }
            let nearest = matching.min { abs(rows[$0][0].box.midY - box.midY) < abs(rows[$1][0].box.midY - box.midY) }
            if let nearest {
                rows[nearest].append(fragment)
            } else {
                rows.append([fragment])
            }
        }
        return rows.map { row in
            let ordered = row.sorted { $0.box.minX < $1.box.minX }
            var text = ordered[0].text
            for (previous, fragment) in zip(ordered, ordered.dropFirst()) {
                let characterWidth = max(
                    previous.box.width / CGFloat(max(previous.text.count, 1)),
                    fragment.box.width / CGFloat(max(fragment.text.count, 1)))
                text += fragment.box.minX - previous.box.maxX > characterWidth * 3 ? "\t" : " "
                text += fragment.text
            }
            return text
        }
    }

    /// What the QR codes in `image` say, top to bottom, then left to right.
    static func codes(in image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return []
        }
        let found = (request.results ?? []).compactMap { observation -> TextFragment? in
            guard let payload = observation.payloadStringValue, !payload.isEmpty else { return nil }
            return TextFragment(text: payload, box: observation.boundingBox)
        }
        let ordered = found.sorted {
            abs($0.box.midY - $1.box.midY) > 0.01 ? $0.box.midY > $1.box.midY : $0.box.minX < $1.box.minX
        }
        return ordered.map(\.text)
    }
}
