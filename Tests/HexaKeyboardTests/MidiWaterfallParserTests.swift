import XCTest
@testable import HexaKeyboardCore

final class MidiWaterfallParserTests: XCTestCase {
    func testParsesStandardMIDINote() throws {
        let parsed = try MidiWaterfallParser.detectAndParse(
            bytes: smfTrack([
                0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20,
                0x00, 0x90, 0x3C, 0x40,
                0x83, 0x60, 0x80, 0x3C, 0x00,
                0x00, 0xFF, 0x2F, 0x00,
            ]),
            fileName: "plain.mid"
        )

        XCTAssertEqual(parsed.format, "MIDX")
        XCTAssertEqual(parsed.notes.count, 1)
        XCTAssertEqual(parsed.notes[0].midiPitch, 60)
        XCTAssertEqual(parsed.notes[0].start, 0, accuracy: 0.000_001)
        XCTAssertEqual(parsed.notes[0].end, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(
            60_000_000.0 / parsed.tempos[0].usPerQuarter,
            120,
            accuracy: 0.000_001
        )
    }

    func testParsesMIDXInlinePitchOffset() throws {
        let parsed = try MidiWaterfallParser.detectAndParse(
            bytes: smfTrack([
                0x00, 0xFF, 0x7F, 0x07, 0x7D, 0x58, 0x54, 0x03, 0x3D, 0x20, 0x00,
                0x00, 0x90, 0x3C, 0x7F,
                0x83, 0x60, 0x80, 0x3C, 0x00,
                0x00, 0xFF, 0x2F, 0x00,
            ]),
            fileName: "offset.midx"
        )

        XCTAssertEqual(parsed.notes.count, 1)
        XCTAssertEqual(parsed.notes[0].midiPitch, 60)
        XCTAssertEqual(parsed.notes[0].audioPitch, 61.0 + 16.0 / 100.0, accuracy: 0.000_001)
        XCTAssertEqual(parsed.notes[0].cents, 16, accuracy: 0.000_001)
    }

    func testParsesMIDI2ClipAttributePitch() throws {
        let parsed = try MidiWaterfallParser.detectAndParse(
            bytes: [
                0x53, 0x4D, 0x46, 0x32, 0x43, 0x4C, 0x49, 0x50,
                0x00, 0x30, 0x01, 0xE0,
                0x00, 0x40, 0x01, 0xE0,
                0x47, 0x90, 0x3C, 0x03, 0x7F, 0xFF, 0x78, 0x00,
                0x00, 0x40, 0x01, 0xE0,
                0x47, 0x80, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00,
            ],
            fileName: "clip.midi2"
        )

        XCTAssertEqual(parsed.format, "MIDI 2.0 Clip")
        XCTAssertEqual(parsed.ticksPerQuarter, 480)
        XCTAssertEqual(parsed.notes.count, 1)
        XCTAssertGreaterThan(parsed.notes[0].velocity, 0)
        XCTAssertEqual(parsed.notes[0].track, 7)
        XCTAssertEqual(parsed.rawEvents.first(where: { $0.velocity > 0 })?.track, 7)
        XCTAssertEqual(parsed.notes[0].audioPitch, 60, accuracy: 0.000_001)
        XCTAssertEqual(parsed.notes[0].start, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(parsed.notes[0].end, 1, accuracy: 0.000_001)
    }

    func testMIDI2SustainUsesGroupScopedTrackAndReleaseTick() throws {
        let parsed = try MidiWaterfallParser.detectAndParse(
            bytes: [
                0x53, 0x4D, 0x46, 0x32, 0x43, 0x4C, 0x49, 0x50,
                0x00, 0x30, 0x01, 0xE0,
                0x43, 0x90, 0x3C, 0x00, 0x7F, 0xFF, 0x00, 0x00,
                0x43, 0xB0, 0x40, 0x00, 0xFF, 0xFF, 0xFF, 0xFF,
                0x00, 0x40, 0x00, 0xF0,
                0x43, 0x80, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x40, 0x00, 0xF0,
                0x43, 0xB0, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00,
            ],
            fileName: "sustain-group.midi2"
        )

        let note = try XCTUnwrap(parsed.notes.first)
        XCTAssertEqual(parsed.notes.count, 1)
        XCTAssertEqual(note.track, 3)
        XCTAssertEqual(note.endTick, 480)
        XCTAssertEqual(note.end, 0.5, accuracy: 0.000_001)
    }

    func testKeepsTheCompleteMIDIPitchRange() throws {
        let parsed = try MidiWaterfallParser.detectAndParse(
            bytes: smfTrack([
                0x00, 0x90, 0x00, 0x40,
                0x01, 0x80, 0x00, 0x00,
                0x00, 0x90, 0x7F, 0x40,
                0x01, 0x80, 0x7F, 0x00,
                0x00, 0xFF, 0x2F, 0x00,
            ]),
            fileName: "full-range.mid"
        )

        XCTAssertEqual(parsed.notes.map(\.midiPitch), [0, 127])
        XCTAssertEqual(parsed.notes.map(\.audioPitch), [0, 127])
    }

    func testPreservesTrackChannelProgramBankAndCentOffset() throws {
        let metadataTrack: [UInt8] = [
            0x00, 0xB5, 0x00, 0x03,
            0x00, 0xB5, 0x20, 0x0C,
            0x00, 0xC5, 0x28,
            0x00, 0xFF, 0x7F, 0x07, 0x7D, 0x58, 0x54, 0x03, 0x3D, 0x20, 0x00,
            0x00, 0x95, 0x3C, 0x64,
            0x83, 0x60, 0x85, 0x3C, 0x00,
            0x00, 0xFF, 0x2F, 0x00,
        ]
        let parsed = try MidiWaterfallParser.detectAndParse(
            bytes: smf(
                [0x00, 0xFF, 0x2F, 0x00],
                metadataTrack
            ),
            fileName: "metadata.midix"
        )

        let event = try XCTUnwrap(parsed.rawEvents.first(where: { $0.velocity > 0 }))
        XCTAssertEqual(event.track, 1)
        XCTAssertEqual(event.channel, 5)
        XCTAssertEqual(event.program, 40)
        XCTAssertEqual(event.bankMsb, 3)
        XCTAssertEqual(event.bankLsb, 12)
        XCTAssertEqual(event.cents, 16, accuracy: 0.000_001)

        let note = try XCTUnwrap(parsed.notes.first)
        XCTAssertEqual(parsed.notes.count, 1)
        XCTAssertEqual(note.track, 1)
        XCTAssertEqual(note.channel, 5)
        XCTAssertEqual(note.program, 40)
        XCTAssertEqual(note.bankMsb, 3)
        XCTAssertEqual(note.bankLsb, 12)
        XCTAssertEqual(note.midiPitch, 60)
        XCTAssertEqual(note.audioPitch, 61.16, accuracy: 0.000_001)
        XCTAssertEqual(note.cents, 16, accuracy: 0.000_001)
    }

    func testAppliesTheCurrentChannelPitchBendAtNoteOn() throws {
        let parsed = try MidiWaterfallParser.detectAndParse(
            bytes: smfTrack([
                0x00, 0xE1, 0x7F, 0x7F,
                0x00, 0xE2, 0x00, 0x00,
                0x00, 0x90, 0x3C, 0x40,
                0x00, 0x91, 0x3C, 0x40,
                0x00, 0x92, 0x3C, 0x40,
                0x83, 0x60, 0x80, 0x3C, 0x00,
                0x00, 0x81, 0x3C, 0x00,
                0x00, 0x82, 0x3C, 0x00,
                0x00, 0xFF, 0x2F, 0x00,
            ]),
            fileName: "pitch-bend.mid"
        )

        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: parsed.notes.map { ($0.channel, $0.audioPitch) }),
            [0: 60, 1: 62, 2: 58]
        )
        XCTAssertEqual(
            Dictionary(
                uniqueKeysWithValues: parsed.rawEvents
                    .filter { $0.velocity > 0 }
                    .map { ($0.channel, $0.cents) }
            ),
            [0: 0, 1: 200, 2: -200]
        )
    }

    func testAppliesRPNPitchBendRangeAndAddsMIDXInlineCents() throws {
        let parsed = try MidiWaterfallParser.detectAndParse(
            bytes: smfTrack([
                0x00, 0xB2, 0x65, 0x00,
                0x00, 0xB2, 0x64, 0x00,
                0x00, 0xB2, 0x06, 0x03,
                0x00, 0xB2, 0x26, 0x32,
                0x00, 0xE2, 0x7F, 0x7F,
                0x00, 0xFF, 0x7F, 0x07, 0x7D, 0x58, 0x54, 0x03, 0x3D, 0x20, 0x00,
                0x00, 0x92, 0x3C, 0x64,
                0x83, 0x60, 0x82, 0x3C, 0x00,
                0x00, 0xFF, 0x2F, 0x00,
            ]),
            fileName: "rpn-bend.midx"
        )

        let noteOn = try XCTUnwrap(parsed.rawEvents.first(where: { $0.velocity > 0 }))
        let note = try XCTUnwrap(parsed.notes.first)
        XCTAssertEqual(noteOn.cents, 366, accuracy: 0.000_001)
        XCTAssertEqual(note.audioPitch, 64.66, accuracy: 0.000_001)
        XCTAssertEqual(note.cents, -34, accuracy: 0.000_001)
    }

    func testSustainDefersNoteOffUntilPedalRelease() throws {
        let parsed = try MidiWaterfallParser.detectAndParse(
            bytes: smfTrack([
                0x00, 0x90, 0x3C, 0x40,
                0x00, 0xB0, 0x40, 0x7F,
                0x81, 0x70, 0x80, 0x3C, 0x00,
                0x81, 0x70, 0xB0, 0x40, 0x00,
                0x00, 0xFF, 0x2F, 0x00,
            ]),
            fileName: "sustain.mid"
        )

        let note = try XCTUnwrap(parsed.notes.first)
        XCTAssertEqual(note.endTick, 480)
        XCTAssertEqual(note.end, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(parsed.rawEvents.map(\.tick), [0, 480])
    }

    func testSustainFallsBackToTrackEndWhenPedalNeverReleases() throws {
        let parsed = try MidiWaterfallParser.detectAndParse(
            bytes: smfTrack([
                0x00, 0x90, 0x3C, 0x40,
                0x00, 0xB0, 0x40, 0x7F,
                0x81, 0x70, 0x80, 0x3C, 0x00,
                0x81, 0x70, 0xFF, 0x2F, 0x00,
            ]),
            fileName: "sustain-track-end.mid"
        )

        XCTAssertEqual(parsed.notes.first?.endTick, 480)
        XCTAssertEqual(parsed.rawEvents.map(\.tick), [0, 480])
    }

    private func smfTrack(_ trackData: [UInt8]) -> [UInt8] {
        smf(trackData)
    }

    private func smf(_ tracks: [UInt8]...) -> [UInt8] {
        let format = tracks.count > 1 ? 1 : 0
        let header: [UInt8] = [
            0x4D, 0x54, 0x68, 0x64,
            0x00, 0x00, 0x00, 0x06,
            0x00, UInt8(format),
            UInt8(tracks.count >> 8 & 0xFF),
            UInt8(tracks.count & 0xFF),
            0x01, 0xE0,
        ]
        return tracks.reduce(header) { bytes, track in
            bytes + [0x4D, 0x54, 0x72, 0x6B] + u32(track.count) + track
        }
    }

    private func u32(_ value: Int) -> [UInt8] {
        [
            UInt8(value >> 24 & 0xFF),
            UInt8(value >> 16 & 0xFF),
            UInt8(value >> 8 & 0xFF),
            UInt8(value & 0xFF),
        ]
    }
}
