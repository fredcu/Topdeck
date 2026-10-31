// SPDX-License-Identifier: MIT
import CoreGraphics
import Foundation
import Testing

@testable import TopdeckFeatures

struct VideoEditModelTests {
    @Test func anEditNobodyChangedIsNotKept() throws {
        #expect(VideoEdit().isUnchanged)
        var edit = VideoEdit()
        edit.corners = 13
        #expect(!edit.isUnchanged)
    }

    @Test func theEditSurvivesJSONAndAKeyMissingFromAnOldFileTakesItsDefault() throws {
        var edit = VideoEdit()
        edit.trimStart = 1.5
        edit.trimEnd = 8
        edit.zooms = [ZoomSegment(start: 2, duration: 3, scale: 2.5, follows: true, target: CGPoint(x: 0.2, y: 0.7))]
        edit.speeds = [SpeedSegment(start: 4, duration: 2, rate: 4)]
        edit.crop = CropRegion(x: 0.1, y: 0.2, width: 0.5, height: 0.6)
        edit.background = .gradient(from: 0x112233, to: 0x445566)
        edit.audio = [AudioTrackSetting(volume: 0.5, muted: false), AudioTrackSetting(volume: 1, muted: true)]
        edit.export.format = .gif
        let data = try JSONEncoder().encode(edit)
        #expect(try JSONDecoder().decode(VideoEdit.self, from: data) == edit)
        let sparse = try JSONDecoder().decode(VideoEdit.self, from: Data(#"{"trimStart": 2}"#.utf8))
        #expect(
            sparse.trimStart == 2 && sparse.padding == 48 && sparse.background.isNone
                && sparse.export == ExportSettings())
    }

    @Test func theSidecarSitsBesideTheVideoAndGoesWhenThereIsNothingInIt() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Sidecar-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appending(path: "Screen Recording 2026-10-30 at 14.03.22.mp4")
        #expect(
            EditSidecar.url(for: video).lastPathComponent == "Screen Recording 2026-10-30 at 14.03.22.topdeck-edit.json"
        )
        #expect(EditSidecar.load(for: video, duration: 10) == nil)
        var edit = VideoEdit()
        edit.trimStart = 3
        try EditSidecar.save(edit, for: video, duration: 10)
        #expect(EditSidecar.load(for: video, duration: 10) == edit)
        #expect(EditSidecar.load(for: video, duration: 25) == nil, "another video under the same name is not edited")
        let size = try FileManager.default.attributesOfItem(atPath: EditSidecar.url(for: video).path)[.size] as? Int
        #expect((size ?? .max) < 1_000, "small")
        try EditSidecar.save(VideoEdit(), for: video, duration: 10)
        #expect(!FileManager.default.fileExists(atPath: EditSidecar.url(for: video).path))
        try Data("not json".utf8).write(to: EditSidecar.url(for: video))
        #expect(EditSidecar.load(for: video, duration: 10) == nil, "a damaged file is no edit")
    }

    @Test func theTrimKeepsAtLeastHalfASecondInsideTheVideo() {
        var edit = VideoEdit()
        #expect(edit.trim(duration: 10) == 0...10)
        edit.trimStart = 4
        edit.trimEnd = 4.1
        #expect(edit.trim(duration: 10) == 4...4.5)
        edit.trimStart = 9.9
        edit.trimEnd = nil
        #expect(edit.trim(duration: 10) == 9.5...10)
        edit.trimStart = -3
        edit.trimEnd = 99
        #expect(edit.trim(duration: 10) == 0...10)
        #expect(VideoEdit().trim(duration: 0.2) == 0...0.2, "a clip shorter than the least keeps all of itself")
    }

    @Test func zoomsAreAddedWhereThereIsRoomAndNeverOverlap() throws {
        var edit = VideoEdit()
        let firstSlot = edit.addZoom(at: 3, duration: 20, follows: false)
        let first = try #require(firstSlot)
        #expect(edit.zooms.first?.start == 3 && edit.zooms.first?.duration == 2)
        #expect(edit.addZoom(at: 4, duration: 20, follows: false) == nil, "inside the first")
        let beforeSlot = edit.addZoom(at: 2, duration: 20, follows: true)
        let before = try #require(beforeSlot)
        let early = try #require(edit.zooms.first { $0.id == before })
        #expect(early.start == 2 && early.end == 3 && early.follows, "it stops where the next one begins")
        #expect(edit.zooms.map(\.id) == [before, first], "kept in order")
        let lateSlot = edit.addZoom(at: 19.8, duration: 20, follows: false)
        let late = try #require(lateSlot)
        let last = try #require(edit.zooms.first { $0.id == late })
        #expect(last.end == 20 && last.duration == 2, "too close to the end: it ends there instead")
        #expect(edit.addZoom(at: 5.2, duration: 20, follows: false) != nil)
    }

    @Test func aZoomWithNoRoomIsRefusedAndTheTrimBoundsIt() {
        var edit = VideoEdit()
        edit.trimStart = 2
        edit.trimEnd = 4
        #expect(edit.addZoom(at: 0, duration: 20, follows: false) != nil)
        #expect(edit.zooms.first?.start == 2, "it starts inside the trim")
        #expect(edit.zooms.first?.end == 4)
        var tight = VideoEdit()
        tight.zooms = [ZoomSegment(start: 0, duration: 2)]
        #expect(tight.addZoom(at: 2, duration: 2.2, follows: false) == nil, "less than the least segment is left")
        #expect(tight.addZoom(at: 1, duration: 2.2, follows: false) == nil, "and inside another there is none")
    }

    @Test func speedSegmentsFollowTheSameRules() throws {
        var edit = VideoEdit()
        let idSlot = edit.addSpeed(at: 1, duration: 10)
        let id = try #require(idSlot)
        #expect(edit.speeds[0].duration == 3 && edit.speeds[0].rate == 2 && edit.speeds[0].id == id)
        #expect(edit.addSpeed(at: 2, duration: 10) == nil)
        #expect(edit.addSpeed(at: 4, duration: 10) != nil)
    }

    @Test func valuesAreHeldToTheirRanges() {
        #expect(ZoomSegment(start: -1, duration: 0.1, scale: 9).start == 0)
        #expect(ZoomSegment(start: 0, duration: 0.1, scale: 9).duration == 0.5)
        #expect(ZoomSegment(start: 0, scale: 9).scale == 4 && ZoomSegment(start: 0, scale: 0.2).scale == 1)
        #expect(ZoomSegment(start: 0, target: CGPoint(x: 2, y: -2)).target == CGPoint(x: 1, y: 0))
        #expect(SpeedSegment(start: 0, rate: 99).rate == 8 && SpeedSegment(start: 0, rate: 0).rate == 0.25)
        let crop = CropRegion(x: 0.9, y: -1, width: 0.5, height: 0.01)
        #expect(crop.x == 0.5 && crop.y == 0 && crop.height == 0.1 && !crop.isFull && CropRegion.full.isFull)
        #expect(AudioTrackSetting(volume: 9, muted: false).volume == 2)
        #expect(AudioTrackSetting(volume: 1, muted: true).gain == 0 && AudioTrackSetting(volume: 0.5).gain == 0.5)
    }

    @Test func aTrackNotListedIsAsRecordedAndTheListStaysShort() {
        var edit = VideoEdit()
        #expect(edit.audioSetting(3) == AudioTrackSetting())
        edit.setAudio(AudioTrackSetting(volume: 1, muted: true), at: 1)
        #expect(edit.audio.count == 2 && edit.audioSetting(0) == AudioTrackSetting() && edit.audioSetting(1).muted)
        edit.setAudio(AudioTrackSetting(), at: 1)
        #expect(edit.audio.isEmpty, "back to as recorded: nothing to keep")
    }
}

struct TimelineMathTests {
    @Test func speedSegmentsChangeTheLengthOfWhatIsExported() {
        let map = TimelineMap(
            trim: 1...9,
            speeds: [SpeedSegment(start: 2, duration: 4, rate: 2), SpeedSegment(start: 7, duration: 1, rate: 0.5)])
        // 1–2 at 1x, 2–6 at 2x (2 s), 6–7 at 1x, 7–8 at 0.5x (2 s), 8–9 at 1x.
        #expect(map.outputDuration == 1 + 2 + 1 + 2 + 1)
        #expect(map.toOutput(1) == 0 && map.toOutput(2) == 1 && map.toOutput(6) == 3 && map.toOutput(9) == 7)
        #expect(map.toOutput(4) == 2, "the middle of the fast part")
        #expect(map.toSource(2) == 4 && map.toSource(0) == 1 && map.toSource(7) == 9)
        #expect(map.rate(atSource: 3) == 2 && map.rate(atSource: 6.5) == 1 && map.rate(atSource: 7.5) == 0.5)
        #expect(!map.isUniform && TimelineMap(trim: 0...5, speeds: []).isUniform)
    }

    @Test func theMapRoundTripsAndStaysInsideTheTrim() {
        let map = TimelineMap(trim: 2...8, speeds: [SpeedSegment(start: 3, duration: 2, rate: 4)])
        for source in stride(from: 2.0, through: 8.0, by: 0.25) {
            #expect(abs(map.toSource(map.toOutput(source)) - source) < 1e-9)
        }
        #expect(map.toOutput(0) == 0 && map.toOutput(99) == map.outputDuration, "held to the trim")
        #expect(map.toSource(-5) == 2 && map.toSource(99) == 8)
    }

    @Test func overlappingOrOutOfTrimSpeedsAreCutDown() {
        let map = TimelineMap(
            trim: 2...6,
            speeds: [
                SpeedSegment(start: 0, duration: 3, rate: 2), SpeedSegment(start: 2.5, duration: 2, rate: 4),
                SpeedSegment(start: 5.5, duration: 5, rate: 2), SpeedSegment(start: 9, duration: 1, rate: 8),
            ])
        // 2–3 at 2x (0.5 s); 3–4.5 at 4x (0.375 s); 4.5–5.5 at 1x; 5.5–6 at 2x (0.25 s).
        #expect(abs(map.outputDuration - (0.5 + 0.375 + 1 + 0.25)) < 1e-9)
        #expect(TimelineMap(trim: 0...3, speeds: [SpeedSegment(start: 1, rate: 1)]).isUniform, "1x changes nothing")
    }

    @Test func theScaleMapsTimeToPointsBothWays() {
        let scale = TimelineScale(duration: 96, width: 960)
        #expect(scale.x(48) == 480 && scale.time(480) == 48 && scale.secondsPerPoint == 0.1)
        #expect(scale.x(-3) == 0 && scale.x(200) == 960 && scale.time(2_000) == 96)
        #expect(scale.frameTimes(count: 4) == [12, 36, 60, 84])
        #expect(scale.tiles(of: 96) == 10 && scale.frameTimes(count: 0).isEmpty)
    }

    @Test func aSegmentStopsAtItsNeighboursAndTheTrim() {
        let others = [1.0...2.0, 6.0...8.0]
        let bounds = 0.0...10.0
        let segment = 3.0...4.0
        #expect(SegmentDrag.moved(current: segment, to: 4.2, among: others, within: bounds) == 4.2)
        #expect(SegmentDrag.moved(current: segment, to: 9, among: others, within: bounds) == 5, "against the next one")
        #expect(
            SegmentDrag.moved(current: segment, to: -4, among: others, within: bounds) == 2, "against the one behind")
        #expect(SegmentDrag.moved(current: 3.0...4.0, to: 5, among: [2.0...2.9, 4.5...5], within: bounds) == 3.5)
        #expect(SegmentDrag.moved(current: 0.5...1.5, to: -3, among: [], within: 0...10) == 0)
        // No room to move at all.
        #expect(SegmentDrag.moved(current: 2.0...4.0, to: 3, among: [1.0...2.0, 4.0...5.0], within: bounds) == 2)
    }

    @Test func anEdgeStretchesButNotPastItsNeighboursOrBelowTheLeast() {
        let others = [1.0...2.0, 6.0...8.0]
        let bounds = 0.0...10.0
        let segment = 3.0...4.0
        let longer = SegmentDrag.resized(
            current: segment, edge: .end, to: 9, among: others, within: bounds, least: 0.5)
        #expect(longer == 3...6)
        let earlier = SegmentDrag.resized(
            current: segment, edge: .start, to: 0, among: others, within: bounds, least: 0.5)
        #expect(earlier == 2...4)
        let shorter = SegmentDrag.resized(
            current: segment, edge: .end, to: 3.1, among: others, within: bounds, least: 0.5)
        #expect(shorter == 3...3.5)
        let capped = SegmentDrag.resized(
            current: segment, edge: .end, to: 9, among: [], within: bounds, least: 0.5, most: 2)
        #expect(capped == 3...5)
    }

    @Test func trimHandlesKeepTheirDistance() {
        let trim = 2.0...8.0
        #expect(SegmentDrag.trimmed(trim, edge: .start, to: 9, duration: 10, least: 0.5) == 7.5...8)
        #expect(SegmentDrag.trimmed(trim, edge: .start, to: -1, duration: 10, least: 0.5) == 0...8)
        #expect(SegmentDrag.trimmed(trim, edge: .end, to: 1, duration: 10, least: 0.5) == 2...2.5)
        #expect(SegmentDrag.trimmed(trim, edge: .end, to: 99, duration: 10, least: 0.5) == 2...10)
    }

    @Test func timesReadLikeTheBoard() {
        #expect(TimeText.clock(42) == "0:42" && TimeText.clock(96.9) == "1:36" && TimeText.clock(3725) == "1:02:05")
        #expect(TimeText.clock(-3) == "0:00")
    }
}

struct ZoomPlanTests {
    private let zoom = ZoomSegment(start: 2, duration: 4, scale: 2, follows: false, target: CGPoint(x: 0.75, y: 0.25))

    @Test func theCameraIsStillOutsideASegmentAndGoesInAndOutWithinIt() {
        let plan = ZoomPlan(segments: [zoom], cursor: nil)
        #expect(plan.camera(at: 1) == .still && plan.camera(at: 6) == .still && plan.camera(at: 99) == .still)
        #expect(plan.camera(at: 2).scale == 1, "it starts from nothing")
        let middle = plan.camera(at: 4)
        #expect(middle.scale == 2 && middle.center == CGPoint(x: 0.75, y: 0.25))
        let going = plan.camera(at: 2.2).scale
        #expect(going > 1 && going < 2, "easing in")
        let coming = plan.camera(at: 5.8).scale
        #expect(coming > 1 && coming < 2, "and out")
        var last = 1.0
        for step in 0...20 {  // never overshoots, and rises monotonically over the transition
            let scale = plan.camera(at: 2 + Double(step) * 0.02).scale
            #expect(scale >= last && scale <= 2)
            last = scale
        }
    }

    @Test func aShortSegmentStillReachesItsScale() {
        let plan = ZoomPlan(segments: [ZoomSegment(start: 0, duration: 0.5, scale: 3)], cursor: nil)
        #expect(abs(plan.camera(at: 0.25).scale - 3) < 1e-9)
    }

    @Test func theViewIsKeptInsideThePicture() {
        let camera = ZoomCamera(scale: 2, center: CGPoint(x: 0.95, y: 0.02))
        #expect(camera.view == CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        #expect(ZoomCamera(scale: 1, center: CGPoint(x: 0.9, y: 0.9)).view == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(
            ZoomCamera(scale: 4, center: CGPoint(x: 0.5, y: 0.5)).view
                == CGRect(x: 0.375, y: 0.375, width: 0.25, height: 0.25))
    }

    @Test func followingTheCursorUsesItsRecordedPathAndFallsBackToTheTarget() throws {
        var follower = zoom
        follower.follows = true
        // The pointer sweeps left to right along the middle in ten seconds.
        let track = CursorTrack(samples: (0...100).map { .init(time: Double($0) / 10, x: Double($0) / 100, y: 0.5) })
        let plan = ZoomPlan(segments: [follower], cursor: track)
        let early = try #require(Optional(plan.camera(at: 3)))
        let late = try #require(Optional(plan.camera(at: 5)))
        #expect(late.center.x > early.center.x && abs(early.center.y - 0.5) < 1e-9)
        #expect(abs(early.center.x - 0.3) < 0.05, "near where the pointer was")
        let without = ZoomPlan(segments: [follower], cursor: nil)
        #expect(without.camera(at: 4).center == CGPoint(x: 0.75, y: 0.25), "no recorded pointer: the target")
        let barely = ZoomPlan(segments: [follower], cursor: CursorTrack(samples: [.init(time: 0, x: 0, y: 0)]))
        #expect(barely.camera(at: 4).center == CGPoint(x: 0.75, y: 0.25), "one sample is not a path")
    }

    @Test func theLaterOfTwoOverlappingSegmentsWins() {
        let early = ZoomSegment(start: 0, duration: 4, scale: 2)
        let late = ZoomSegment(start: 1, duration: 2, scale: 4)
        #expect(ZoomPlan(segments: [late, early], cursor: nil).camera(at: 2).scale == 4)
    }
}

struct FrameLayoutTests {
    private let source = CGSize(width: 1000, height: 500)

    @Test func withNothingChangedTheFrameIsTheSource() {
        let layout = FrameLayout(source: source, edit: VideoEdit())
        #expect(layout.crop == CGRect(x: 0, y: 0, width: 1000, height: 500) && layout.canvas == source)
        #expect(layout.content == CGRect(x: 0, y: 0, width: 1000, height: 500) && layout.cornerRadius == 0)
    }

    @Test func aCropKeepsWholeEvenPixels() {
        var edit = VideoEdit()
        edit.crop = CropRegion(x: 0.25, y: 0, width: 0.5, height: 1)
        let layout = FrameLayout(source: source, edit: edit)
        #expect(
            layout.crop == CGRect(x: 250, y: 0, width: 500, height: 500)
                && layout.canvas == CGSize(width: 500, height: 500))
        edit.crop = CropRegion(x: 0.1234, y: 0.3333, width: 0.4567, height: 0.4)
        let odd = FrameLayout(source: CGSize(width: 1001, height: 601), edit: edit)
        #expect(
            odd.canvas.width.truncatingRemainder(dividingBy: 2) == 0
                && odd.canvas.height.truncatingRemainder(dividingBy: 2) == 0)
        #expect(odd.crop.maxX <= 1001 && odd.crop.maxY <= 601 && odd.crop.minX >= 0)
    }

    @Test func aBackgroundInsetsTheVideoInUnitsOfAThousandWideFrame() {
        var edit = VideoEdit()
        edit.background = .gradient(from: 0x2B4C7E, to: 0xC86A7A)
        let layout = FrameLayout(source: source, edit: edit)
        #expect(layout.canvas == CGSize(width: 1096, height: 596), "48 on each side of a frame 1000 wide")
        #expect(layout.content == CGRect(x: 48, y: 48, width: 1000, height: 500) && layout.cornerRadius == 12)
        // The same edit at twice the pixels is the same picture, twice as big.
        let big = FrameLayout(source: CGSize(width: 2000, height: 1000), edit: edit)
        #expect(big.canvas == CGSize(width: 2192, height: 1192) && big.cornerRadius == 24)
        edit.padding = 0
        #expect(FrameLayout(source: source, edit: edit).canvas == source, "no room, no background")
        edit.padding = 48
        edit.background = .none
        #expect(FrameLayout(source: source, edit: edit).cornerRadius == 0, "no background, no rounding")
    }

    @Test func aBoxShrinksTheCanvasButNeverEnlargesIt() {
        var edit = VideoEdit()
        edit.background = .solid(0x232936)
        let small = FrameLayout(source: source, edit: edit, box: CGSize(width: 548, height: 298))
        #expect(small.canvas == CGSize(width: 548, height: 298))
        #expect(small.content.minX == 24 && small.cornerRadius == 6)
        #expect(
            FrameLayout(source: source, edit: edit, box: CGSize(width: 4000, height: 4000)).canvas
                == CGSize(width: 1096, height: 596))
        let tall = FrameLayout(
            source: CGSize(width: 1000, height: 2000), edit: VideoEdit(), box: CGSize(width: 1280, height: 720))
        #expect(tall.canvas == CGSize(width: 640, height: 1280), "a tall picture uses the box turned")
    }

    @Test func theCornersNeverPassHalfTheVideo() {
        var edit = VideoEdit()
        edit.background = .solid(1)
        edit.corners = 60
        edit.crop = CropRegion(x: 0, y: 0, width: 1, height: 0.1)
        let layout = FrameLayout(source: source, edit: edit)
        #expect(layout.cornerRadius <= layout.content.height / 2)
    }

    @Test func aGIFIsNeverBiggerThan720pUnlessAsked() {
        var settings = ExportSettings()
        settings.format = .gif
        #expect(FrameLayout.box(for: settings) == CGSize(width: 1280, height: 720))
        settings.size = .p1080
        #expect(FrameLayout.box(for: settings) == CGSize(width: 1920, height: 1080))
        settings.format = .mp4
        settings.size = .original
        #expect(FrameLayout.box(for: settings) == nil)
    }
}

struct ExportPlanTests {
    private func plan(
        _ edit: VideoEdit, rate: Double = 60, audio: Int = 2, size: CGSize = CGSize(width: 3456, height: 2234)
    ) -> ExportPlan {
        ExportPlan(source: size, duration: 20, sourceFramesPerSecond: rate, audioTracks: audio, edit: edit)
    }

    @Test func mutedTracksAreLeftOutAndTheRestKeepTheirGain() {
        var edit = VideoEdit()
        edit.setAudio(AudioTrackSetting(volume: 1, muted: true), at: 0)
        edit.setAudio(AudioTrackSetting(volume: 0.5), at: 1)
        let kept = plan(edit).audio
        #expect(kept.map(\.track) == [1] && kept.map(\.gain) == [0.5])
        #expect(plan(VideoEdit()).audio.map(\.track) == [0, 1])
        #expect(plan(VideoEdit(), audio: 0).audio.isEmpty)
        edit.export.format = .gif
        #expect(plan(edit).audio.isEmpty, "a GIF has no sound")
    }

    @Test func theFrameRateFollowsTheSourceWithinSaneBounds() {
        #expect(plan(VideoEdit(), rate: 60).framesPerSecond == 60)
        #expect(plan(VideoEdit(), rate: 24).framesPerSecond == 24)
        #expect(plan(VideoEdit(), rate: 0).framesPerSecond == 30)
        #expect(plan(VideoEdit(), rate: 240).framesPerSecond == 60 && plan(VideoEdit(), rate: 2).framesPerSecond == 15)
    }

    @Test func theBitrateFollowsTheQualityAndThePixels() {
        var edit = VideoEdit()
        let high = plan(edit).bitrate
        edit.export.quality = .low
        let low = plan(edit).bitrate
        #expect(low < high && high <= 60_000_000 && low >= 800_000)
        edit.export.size = .p480
        #expect(plan(edit).bitrate < low, "a smaller picture needs fewer bits")
    }

    @Test func theLengthIsWhatTheMapSaysAndAGIFHoldsToItsMemory() {
        var edit = VideoEdit()
        edit.trimStart = 5
        edit.trimEnd = 15
        edit.speeds = [SpeedSegment(start: 6, duration: 4, rate: 2)]
        edit.export.format = .gif
        edit.export.quality = .high
        let gif = plan(edit, size: CGSize(width: 1280, height: 720))
        #expect(gif.map.outputDuration == 8)
        #expect(gif.framesPerSecond <= 20 && gif.framesPerSecond >= 5)
        #expect(gif.frameCount == Int((8 * gif.framesPerSecond).rounded(.up)))
        let huge = plan(edit, size: CGSize(width: 7680, height: 4320))  // capped to 720p, so just as many frames
        #expect(huge.layout.canvas.width <= 1280)
        var long = edit
        long.trimStart = 0
        long.trimEnd = nil
        let longer = ExportPlan(
            source: CGSize(width: 1920, height: 1080), duration: 600, sourceFramesPerSecond: 30, audioTracks: 0,
            edit: {
                var e = long
                e.export.size = .p1080
                return e
            }())
        #expect(longer.framesPerSecond == 5, "ten minutes of 1080p gets the fewest")
    }

    @Test func anExportIsNamedForItsSourceAndNeverTakesAUsedName() {
        let source = URL(filePath: "/Users/me/Captures/Screen Recording 2026-10-30 at 14.03.22.mp4")
        var taken: Set<String> = []
        let first = ExportNaming.destination(for: source, format: .mp4) { taken.contains($0.lastPathComponent) }
        #expect(first.lastPathComponent == "Screen Recording 2026-10-30 at 14.03.22 edited.mp4")
        #expect(first.deletingLastPathComponent().path == "/Users/me/Captures", "beside the source")
        taken.insert(first.lastPathComponent)
        let second = ExportNaming.destination(for: source, format: .mp4) { taken.contains($0.lastPathComponent) }
        #expect(second.lastPathComponent.hasSuffix("edited 2.mp4"))
        taken.insert(second.lastPathComponent + ".partial")
        taken.insert(second.lastPathComponent)
        #expect(
            ExportNaming.destination(for: source, format: .mp4) { taken.contains($0.lastPathComponent) }
                .lastPathComponent.hasSuffix("edited 3.mp4"))
        #expect(ExportNaming.destination(for: source, format: .gif).pathExtension == "gif")
        let folder = URL(filePath: "/tmp/elsewhere")
        #expect(
            ExportNaming.destination(for: source, format: .mp4, in: folder) { _ in false }.deletingLastPathComponent()
                .path == folder.path)
        let named = URL(filePath: "/x/clip edited.mp4")
        #expect(
            ExportNaming.destination(for: named, format: .mp4).lastPathComponent == "clip edited edited.mp4",
            "still not the source")
    }
}

// MARK: Pixels

/// A picture as bytes: the way to look at what the renderer drew.
private struct Pixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(
            CGContext(
                data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = data
    }

    /// (red, green, blue) at a point counted from the top left.
    func at(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let index = (y * width + x) * 4
        return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
    }

    func isNear(_ x: Int, _ y: Int, _ color: (r: Int, g: Int, b: Int), within slack: Int = 12) -> Bool {
        let pixel = at(x, y)
        return abs(pixel.r - color.r) <= slack && abs(pixel.g - color.g) <= slack && abs(pixel.b - color.b) <= slack
    }
}

/// A picture 200 by 100: its left half red, its right half blue.
private func halves() throws -> CGImage {
    let context = try #require(
        CGContext(
            data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
    return try #require(context.makeImage())
}

private let red = (r: 255, g: 0, b: 0)
private let blue = (r: 0, g: 0, b: 255)

struct FrameRendererTests {
    private func render(_ edit: VideoEdit, at time: TimeInterval = 0) throws -> Pixels {
        let layout = FrameLayout(source: CGSize(width: 200, height: 100), edit: edit)
        let renderer = FrameRenderer(layout: layout, edit: edit, zoom: ZoomPlan(segments: edit.zooms, cursor: nil))
        let image = try #require(renderer.cgImage(from: try halves(), atSource: time))
        let pixels = try Pixels(image)
        #expect(pixels.width == Int(layout.canvas.width) && pixels.height == Int(layout.canvas.height))
        return pixels
    }

    @Test func anUntouchedFrameIsTheSource() throws {
        let pixels = try render(VideoEdit())
        #expect(pixels.width == 200 && pixels.height == 100)
        #expect(
            pixels.isNear(10, 50, red) && pixels.isNear(190, 50, blue) && pixels.isNear(99, 5, red)
                && pixels.isNear(101, 95, blue))
    }

    @Test func aCropKeepsOnlyItsPart() throws {
        var edit = VideoEdit()
        edit.crop = CropRegion(x: 0.5, y: 0, width: 0.5, height: 1)
        let pixels = try render(edit)
        #expect(pixels.width == 100 && pixels.height == 100)
        #expect(pixels.isNear(1, 1, blue) && pixels.isNear(50, 50, blue) && pixels.isNear(98, 98, blue))
        edit.crop = CropRegion(x: 0.25, y: 0, width: 0.5, height: 1)
        let middle = try render(edit)
        #expect(middle.isNear(10, 50, red) && middle.isNear(90, 50, blue), "the seam is in the middle")
    }

    @Test func aZoomFillsTheFrameWithWhatTheCameraSees() throws {
        var edit = VideoEdit()
        edit.zooms = [ZoomSegment(start: 0, duration: 4, scale: 2, follows: false, target: CGPoint(x: 0.75, y: 0.5))]
        let before = try render(edit, at: 0)
        #expect(before.isNear(10, 50, red), "the camera starts out with the whole picture")
        let zoomed = try render(edit, at: 2)
        #expect(zoomed.width == 200 && zoomed.height == 100, "the frame keeps its size")
        #expect(zoomed.isNear(5, 50, blue) && zoomed.isNear(195, 5, blue), "only the right half is in view")
        edit.zooms[0].target = CGPoint(x: 0.25, y: 0.5)
        #expect(try render(edit, at: 2).isNear(195, 50, red), "and on the left half, red")
    }

    @Test func aBackgroundFramesTheVideoWithRoundedCorners() throws {
        var edit = VideoEdit()
        edit.background = .solid(0xFFFFFF)
        edit.padding = 100  // 20 pixels on a frame 200 wide
        edit.corners = 60  // 12 pixels
        let pixels = try render(edit)
        #expect(pixels.width == 240 && pixels.height == 140)
        #expect(pixels.isNear(2, 2, (255, 255, 255)) && pixels.isNear(237, 137, (255, 255, 255)), "the margin")
        #expect(pixels.isNear(40, 70, red) && pixels.isNear(200, 70, blue), "the video inside it")
        #expect(pixels.isNear(21, 21, (255, 255, 255)), "the corner is cut: the background shows")
        #expect(pixels.isNear(32, 32, red), "and the video is back a radius in")
        #expect(pixels.isNear(120, 21, red) || pixels.isNear(120, 21, blue), "straight edges are not rounded")
    }

    @Test func aGradientRunsFromTheTopLeftToTheBottomRight() throws {
        var edit = VideoEdit()
        edit.background = .gradient(from: 0x000000, to: 0xFFFFFF)
        edit.padding = 200
        edit.corners = 0
        let pixels = try render(edit)
        #expect(pixels.at(1, 1).r < 40 && pixels.at(pixels.width - 2, pixels.height - 2).r > 215)
        #expect(
            pixels.at(pixels.width - 2, 1).r > 60 && pixels.at(pixels.width - 2, 1).r < 200,
            "the other corners in between")
    }
}
