// SPDX-License-Identifier: MIT
import CoreGraphics

/// Now's measurements for the body it is given: the default deck, or the smallest, as on the boards.
/// Pure, so the two sizes are tested without drawing them.
struct NowMetrics: Equatable {
    /// The width below which the narrower columns and the smaller player are used.
    static let narrow: CGFloat = 660
    /// The height below which the rows tighten and the month loses its title.
    static let short: CGFloat = 290

    /// The hairline and the gaps around it above the days.
    static let forecastLead: CGFloat = 15
    /// The most days the forecast shows.
    static let forecastDays = 5

    let left: CGFloat
    let middle: CGFloat
    /// A day in the grid.
    let dayHeight: CGFloat
    /// A row of the list under the grid.
    let eventHeight: CGFloat
    /// A row of the left column.
    let itemHeight: CGFloat
    /// A day in the five-day forecast.
    let forecastRow: CGFloat
    let showsMonthTitle: Bool
    /// The cover beside the title.
    let artwork: CGFloat
    /// The smallest deck shows one lyric block and no next line.
    let showsNextLyric: Bool
    /// The weather's temperature at its largest, or one size down.
    let largeTemperature: Bool
    /// Events under "Today" after the first.
    let laterEvents: Int
    /// How many rows of the list under the grid show at once; nil scrolls them all.
    let eventRows: Int?

    init(size: CGSize) {
        let narrow = size.width < Self.narrow
        let short = size.height < Self.short
        left = narrow ? 150 : 176
        middle = narrow ? 192 : 214
        dayHeight = short ? 21 : 26
        eventHeight = short ? 30 : 36
        itemHeight = short ? 26 : 30
        forecastRow = short ? 22 : 25
        showsMonthTitle = !short
        artwork = short ? 36 : 52
        showsNextLyric = !short
        largeTemperature = !short
        laterEvents = short ? 2 : 4
        eventRows = short ? 2 : nil
    }

    /// How many days fit in `height` under the hours: five at most, and none when not even two fit.
    func forecastDays(fitting height: CGFloat) -> Int {
        let rows = Int(max(0, height - Self.forecastLead) / forecastRow)
        return rows < 2 ? 0 : min(rows, Self.forecastDays)
    }
}
