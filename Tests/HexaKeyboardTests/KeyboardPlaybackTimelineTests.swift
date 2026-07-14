import XCTest
@testable import HexaKeyboardCore

final class KeyboardPlaybackTimelineTests: XCTestCase {
    func testSnappingChangesOnlyTheVisualCoordinate() throws {
        let score = scoreOf(note(audioPitch: 60.37))
        let layout = HexaKeyboardLayoutEngine.build(
            configuration: HexaKeyboardConfiguration(period: 53)
        )

        let mapped = try XCTUnwrap(score.snapToKeyboard(layout).notes.first)

        XCTAssertEqual(mapped.audioPitch, 60.37, accuracy: 0.000_001)
        let keyPitch = try XCTUnwrap(layout.cell(at: mapped.coordinate)).audioPitch.midiPitch
        let minimumDistance = try XCTUnwrap(
            layout.cells.map { abs($0.audioPitch.midiPitch - 60.37) }.min()
        )
        XCTAssertEqual(abs(keyPitch - 60.37), minimumDistance, accuracy: 0.000_001)
    }

    func testUpcomingFanGrowsTowardNoteStartAndActiveNoteKeepsItsTrack() throws {
        let timeline = scoreOf(
            note(audioPitch: 60, start: 2, end: 3, track: 7)
        ).snapToKeyboard(HexaKeyboardLayoutEngine.build())

        let early = try XCTUnwrap(
            timeline.visualFrame(at: 0.3, activeScoreIndices: []).keys.values.first
        )
        let late = try XCTUnwrap(
            timeline.visualFrame(at: 1.7, activeScoreIndices: []).keys.values.first
        )
        let active = try XCTUnwrap(
            timeline.visualFrame(at: 2.2, activeScoreIndices: [0]).keys.values.first
        )

        XCTAssertGreaterThan(
            try XCTUnwrap(late.upcoming).progress,
            try XCTUnwrap(early.upcoming).progress
        )
        XCTAssertTrue(active.isActive)
        XCTAssertEqual(active.activeTracks, [7])
    }

    func testCompletedNoteCreatesAShortBurstThenDisappears() throws {
        let timeline = scoreOf(
            note(audioPitch: 60, start: 0, end: 1)
        ).snapToKeyboard(HexaKeyboardLayoutEngine.build())

        let burst = try XCTUnwrap(
            timeline.visualFrame(at: 1.1, activeScoreIndices: []).keys.values.first
        )
        let finished = timeline.visualFrame(at: 1.5, activeScoreIndices: [])

        XCTAssertFalse(burst.completedNotes.isEmpty)
        XCTAssertTrue(finished.keys.isEmpty)
    }

    func testConsecutiveHitsOnOneKeyAreMarkedForFlashing() throws {
        let score = scoreOf(
            note(audioPitch: 60, start: 0, end: 0.1),
            note(audioPitch: 60, start: 0.22, end: 0.4)
        )
        let timeline = score.snapToKeyboard(HexaKeyboardLayoutEngine.build())

        XCTAssertFalse(timeline.notes[0].repeatedHit)
        XCTAssertTrue(timeline.notes[1].repeatedHit)
        let visual = try XCTUnwrap(
            timeline.visualFrame(at: 0.24, activeScoreIndices: [1]).keys.values.first
        )
        XCTAssertGreaterThan(visual.flash, 0)
    }

    func testPreviewKeepsOnlyTheNearestSixteenNoteMarkers() {
        let notes = (0..<(MAX_PLAYBACK_PREVIEW_NOTES + 8)).map { index in
            KeyboardPlaybackNote(
                scoreIndex: index,
                coordinate: AxialCoordinate(q: index, r: 0),
                start: 0.1 + Double(index) * 0.01,
                end: 1,
                audioPitch: 60 + Double(index),
                velocity: 100,
                track: 0,
                repeatedHit: false
            )
        }
        let timeline = KeyboardPlaybackTimeline(
            notes: notes,
            notesByEnd: notes.sorted { $0.end < $1.end },
            duration: 1
        )

        let previewIndices = timeline.visualFrame(at: 0, activeScoreIndices: [])
            .keys
            .values
            .compactMap { $0.upcoming?.note.scoreIndex }
            .sorted()

        XCTAssertEqual(previewIndices.count, MAX_PLAYBACK_PREVIEW_NOTES)
        XCTAssertEqual(previewIndices, Array(0..<MAX_PLAYBACK_PREVIEW_NOTES))
    }

    private func scoreOf(_ notes: PlaybackNote...) -> PlaybackScore {
        PlaybackScore(
            title: "test",
            format: "test",
            notes: notes,
            duration: notes.map(\.end).max() ?? 0
        )
    }

    private func note(
        audioPitch: Double,
        start: Double = 0,
        end: Double = 1,
        track: Int = 0
    ) -> PlaybackNote {
        PlaybackNote(
            startTick: Int64(start * 480),
            endTick: Int64(end * 480),
            start: start,
            end: end,
            audioPitch: audioPitch,
            midiPitch: Int(audioPitch),
            cents: (audioPitch - Double(Int(audioPitch))) * 100,
            velocity: 100,
            channel: 0,
            track: track,
            program: 0,
            bankMsb: 0,
            bankLsb: 0
        )
    }
}
