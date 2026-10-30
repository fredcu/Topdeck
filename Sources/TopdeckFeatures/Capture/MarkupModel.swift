// SPDX-License-Identifier: MIT
import CoreGraphics
import Foundation
import Observation

/// The capture editor's state: the marks, the tool in hand, and undo. The editor's views feed it
/// pointer events in the capture's points, from its top left.
@MainActor
@Observable
final class MarkupModel {
    var tool = MarkTool.arrow {
        didSet { selection = nil }
    }
    var color = RGB.markColors[0] {
        didSet { restyleSelection() }
    }
    /// Stroke width in points.
    var width: CGFloat = 4 {
        didSet { restyleSelection() }
    }
    private(set) var marks: [Mark] = []
    /// The mark the select tool picked, by index.
    private(set) var selection: Int?
    /// The mark being drawn, shown before it's added.
    private(set) var draft: Mark?

    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    /// Called after anything drawn changes, so the canvas can redraw.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var history: [[Mark]] = []
    @ObservationIgnored private var future: [[Mark]] = []
    @ObservationIgnored private var path: [CGPoint] = []
    /// While moving the selection: where the drag last was, and the marks before it started.
    @ObservationIgnored private var moving: (last: CGPoint, before: [Mark])?

    /// The next number the counter tool places.
    var nextNumber: Int {
        let numbers = marks.compactMap { mark -> Int? in
            if case .counter(let number, _) = mark.shape { return number }
            return nil
        }
        return (numbers.max() ?? 0) + 1
    }

    func press(at point: CGPoint) {
        switch tool {
        case .select:
            selection = marks.indices.last { marks[$0].contains(point) }
            moving = selection.map { _ in (point, marks) }
        case .counter:
            commit(marks + [Mark(shape: .counter(nextNumber, at: point), color: color, width: width)])
        case .text:
            break  // the editor asks for the text, then calls `addText`
        default:
            path = [point]
        }
        onChange?()
    }

    func drag(to point: CGPoint) {
        if let selection, let moving {
            let delta = CGVector(dx: point.x - moving.last.x, dy: point.y - moving.last.y)
            marks[selection] = marks[selection].moved(by: delta)
            self.moving = (point, moving.before)
        } else if !path.isEmpty {
            path.append(point)
            draft = Mark.dragged(tool, along: path, color: color, width: width)
        }
        onChange?()
    }

    func release(at point: CGPoint) {
        if let moving {
            self.moving = nil
            if marks != moving.before { record(moving.before) }
        } else if !path.isEmpty {
            path.append(point)
            if let mark = Mark.dragged(tool, along: path, color: color, width: width) { commit(marks + [mark]) }
            path = []
            draft = nil
        }
        onChange?()
    }

    func addText(_ text: String, at point: CGPoint) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        commit(marks + [Mark(shape: .text(text, at: point), color: color, width: width)])
        onChange?()
    }

    func deleteSelection() {
        guard let selection else { return }
        var remaining = marks
        remaining.remove(at: selection)
        commit(remaining)
        onChange?()
    }

    func undo() {
        guard let previous = history.popLast() else { return }
        future.append(marks)
        marks = previous
        selection = nil
        onChange?()
    }

    func redo() {
        guard let next = future.popLast() else { return }
        history.append(marks)
        marks = next
        selection = nil
        onChange?()
    }

    private func commit(_ new: [Mark]) {
        record(marks)
        marks = new
        selection = nil
    }

    /// Remembers `before` for undo, once `marks` already holds the change.
    private func record(_ before: [Mark]) {
        history.append(before)
        future = []
    }

    /// A colour or width picked while a mark is selected applies to that mark.
    private func restyleSelection() {
        guard let selection, marks[selection].color != color || marks[selection].width != width else { return }
        let before = marks
        marks[selection].color = color
        marks[selection].width = width
        record(before)
        onChange?()
    }
}
