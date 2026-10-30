// SPDX-License-Identifier: MIT
// Generated from the icon masks in docs/design/deck.css by a script kept outside the repository.
// Every icon is drawn on a 24-unit grid with a 2-unit round stroke, so side by side they look one size.
import AppKit
import SwiftUI

/// The deck's icons, from the design boards.
public enum DeckIcon: String, CaseIterable, Sendable {
    case play, pause, next, previous, pin, gear, search, plus, close, check, file, image, link, copy, trash, share,
        calendar, clock, hand, terminal, cpu, volume, microphone, display, disk, network, capture, qrCode,
        recognizeText, colorPicker, scrollingCapture, moon, bolt, chevronRight, chevronDown, note, arrowUpRight, grid,
        battery, thermometer, shield, stack, list, app, markupArrow, markupRectangle, markupOval, markupPen,
        markupMosaic, undo, markupNumber, cursor

    /// The icon's shapes, on a 24 by 24 grid.
    var shapes: String {
        switch self {
        case .play: #"<path d='M7 4v16l13-8z' fill='#000'/>"#
        case .pause: #"<path d='M8 5v14M16 5v14' stroke-width='3'/>"#
        case .next: #"<path d='M5 5v14l11-7z' fill='#000'/><path d='M19 5v14'/>"#
        case .previous: #"<path d='M19 5v14L8 12z' fill='#000'/><path d='M5 5v14'/>"#
        case .pin: #"<path d='M9 4h6l-1 6 4 4H6l4-4zM12 14v7'/>"#
        case .gear:
            #"<circle cx='12' cy='12' r='3'/><path d='M12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M18.4 5.6l-2.1 2.1M7.7 16.3l-2.1 2.1'/>"#
        case .search: #"<circle cx='11' cy='11' r='7'/><path d='M21 21l-4.5-4.5'/>"#
        case .plus: #"<path d='M12 5v14M5 12h14'/>"#
        case .close: #"<path d='M6 6l12 12M18 6L6 18'/>"#
        case .check: #"<path d='M5 12.5l4.5 4.5L19 7'/>"#
        case .file: #"<path d='M6 3h8l4 4v14H6zM14 3v4h4'/>"#
        case .image:
            #"<rect x='3' y='4' width='18' height='16' rx='2'/><circle cx='9' cy='10' r='1.5'/><path d='M21 16l-5-5-9 9'/>"#
        case .link:
            #"<path d='M10 14a4 4 0 0 0 6 0l3-3a4 4 0 0 0-6-6l-1 1M14 10a4 4 0 0 0-6 0l-3 3a4 4 0 0 0 6 6l1-1'/>"#
        case .copy: #"<rect x='9' y='9' width='11' height='11' rx='2'/><path d='M5 15V6a2 2 0 0 1 2-2h9'/>"#
        case .trash: #"<path d='M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13'/>"#
        case .share: #"<path d='M12 15V3M8 7l4-4 4 4M5 12v8h14v-8'/>"#
        case .calendar: #"<rect x='4' y='5' width='16' height='16' rx='2'/><path d='M4 10h16M8 3v4M16 3v4'/>"#
        case .clock: #"<circle cx='12' cy='12' r='9'/><path d='M12 7v5l3 2'/>"#
        case .hand:
            #"<path d='M8 12V6a1.5 1.5 0 0 1 3 0v5-7a1.5 1.5 0 0 1 3 0v7-5a1.5 1.5 0 0 1 3 0v9a6 6 0 0 1-6 6h-1a6 6 0 0 1-5-3l-2.500-4a1.500 1.500 0 0 1 2.500-1.500L8 14'/>"#
        case .terminal: #"<rect x='3' y='4' width='18' height='16' rx='2'/><path d='M7 9l3 3-3 3M13 15h4'/>"#
        case .cpu:
            #"<rect x='6' y='6' width='12' height='12' rx='2'/><path d='M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4'/>"#
        case .volume:
            #"<path d='M4 9v6h4l5 4V5L8 9z' fill='#000'/><path d='M16.500 8.500a5 5 0 0 1 0 7M19 6a9 9 0 0 1 0 12'/>"#
        case .microphone: #"<rect x='9' y='3' width='6' height='11' rx='3'/><path d='M5 11a7 7 0 0 0 14 0M12 18v3'/>"#
        case .display: #"<rect x='3' y='4' width='18' height='13' rx='2'/><path d='M8 21h8M12 17v4'/>"#
        case .disk:
            #"<ellipse cx='12' cy='6' rx='8' ry='3'/><path d='M4 6v12c0 1.700 3.600 3 8 3s8-1.300 8-3V6M4 12c0 1.700 3.600 3 8 3s8-1.300 8-3'/>"#
        case .network: #"<path d='M7 20V6M3 10l4-4 4 4M17 4v14M13 14l4 4 4-4'/>"#
        case .capture:
            #"<path d='M4 8V6a2 2 0 0 1 2-2h2M16 4h2a2 2 0 0 1 2 2v2M20 16v2a2 2 0 0 1-2 2h-2M8 20H6a2 2 0 0 1-2-2v-2'/><circle cx='12' cy='12' r='3'/>"#
        case .qrCode:
            #"<rect x='4' y='4' width='6' height='6'/><rect x='14' y='4' width='6' height='6'/><rect x='4' y='14' width='6' height='6'/><path d='M14 14h2v2M20 14v6h-6'/>"#
        case .recognizeText:
            #"<path d='M4 8V6a2 2 0 0 1 2-2h2M16 4h2a2 2 0 0 1 2 2v2M20 16v2a2 2 0 0 1-2 2h-2M8 20H6a2 2 0 0 1-2-2v-2M8 9h8M12 9v7'/>"#
        case .colorPicker: #"<path d='M14 6l4 4M4 20l1-4 9-9 3 3-9 9zM15 4l5 5'/>"#
        case .scrollingCapture: #"<path d='M6 4h12v16H6zM12 8v8M9.500 13.500L12 16l2.500-2.500'/>"#
        case .moon: #"<path d='M20 14A8 8 0 0 1 10 4a8 8 0 1 0 10 10z'/>"#
        case .bolt: #"<path d='M13 3L5 14h6l-1 7 8-11h-6z'/>"#
        case .chevronRight: #"<path d='M9 6l6 6-6 6'/>"#
        case .chevronDown: #"<path d='M6 9l6 6 6-6'/>"#
        case .note: #"<path d='M6 3h12v18H6zM9 8h6M9 12h6M9 16h3'/>"#
        case .arrowUpRight: #"<path d='M7 17L17 7M9 7h8v8'/>"#
        case .grid:
            #"<rect x='4' y='4' width='6' height='6' rx='1'/><rect x='14' y='4' width='6' height='6' rx='1'/><rect x='4' y='14' width='6' height='6' rx='1'/><rect x='14' y='14' width='6' height='6' rx='1'/>"#
        case .battery: #"<rect x='3' y='8' width='16' height='9' rx='2'/><path d='M22 11v3M6 11v3M9 11v3'/>"#
        case .thermometer: #"<path d='M14 14V5a2 2 0 0 0-4 0v9a4 4 0 1 0 4 0z'/>"#
        case .shield: #"<path d='M12 3l7 3v6c0 4.500-3 7.500-7 9-4-1.500-7-4.500-7-9V6z'/>"#
        case .stack: #"<path d='M12 4l9 5-9 5-9-5zM3 14l9 5 9-5'/>"#
        case .list: #"<path d='M9 6h11M9 12h11M9 18h11M4 6h.010M4 12h.010M4 18h.010'/>"#
        case .app: #"<rect x='4' y='4' width='16' height='16' rx='4'/>"#
        case .markupArrow: #"<path d='M6 18L18 6M8 6h10v10'/>"#
        case .markupRectangle: #"<rect x='4' y='6' width='16' height='12' rx='1'/>"#
        case .markupOval: #"<ellipse cx='12' cy='12' rx='9' ry='7'/>"#
        case .markupPen: #"<path d='M4 20c4-1 5-6 8-6s2 4 8-8'/>"#
        case .markupMosaic:
            #"<path d='M4 4h5v5H4zM15 4h5v5h-5zM9.500 9.500h5v5h-5zM4 15h5v5H4zM15 15h5v5h-5z' fill='#000'/>"#
        case .undo: #"<path d='M8 6L4 10l4 4M4 10h10a5 5 0 0 1 0 10h-3'/>"#
        case .markupNumber: #"<circle cx='12' cy='12' r='9'/><path d='M10 9l2-1v8'/>"#
        case .cursor: #"<path d='M6 3l13 9-6 1-3 6z'/>"#
        }
    }
}
