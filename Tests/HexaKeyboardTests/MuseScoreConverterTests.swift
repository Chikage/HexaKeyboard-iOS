import Compression
import Foundation
import XCTest
@testable import HexaKeyboardCore

final class MuseScoreConverterTests: XCTestCase {
    func testConvertsMSCXBytesToReadableMIDX() throws {
        let parsed = try parse(minimalMSCX)

        XCTAssertEqual(parsed.format, "MIDX")
        XCTAssertEqual(parsed.notes.count, 1)
        XCTAssertEqual(parsed.notes[0].midiPitch, 60)
        XCTAssertEqual(parsed.notes[0].audioPitch, 60.125, accuracy: 0.001)
    }

    func testConvertsMSCZBytesToReadableMIDX() throws {
        let parsed = try MidiWaterfallParser.detectAndParse(
            bytes: MuseScoreConverter.convert(msczBytes(), fileName: "minimal.mscz"),
            fileName: "minimal.midx"
        )

        XCTAssertEqual(parsed.notes.count, 1)
        XCTAssertGreaterThan(parsed.duration, 0)
    }

    func testConvertsToStandardMIDIWithoutMIDXOffsetExtension() throws {
        let midi = try MuseScoreConverter.convertToMIDI(Data(minimalMSCX.utf8), fileName: "minimal.mscx")
        let parsed = try MidiWaterfallParser.detectAndParse(bytes: midi, fileName: "minimal.mid")

        XCTAssertEqual(parsed.notes.count, 1)
        XCTAssertEqual(parsed.notes[0].audioPitch, 60, accuracy: 0.001)
        XCTAssertFalse(midi.contains(midxOffsetMarker))
    }

    func testKeepsMuseScoreChannelBankAndProgram() throws {
        let part = """
        <Part>
          <Staff id="1"/>
          <Instrument>
            <trackName>Strings</trackName>
            <Channel name="normal">
              <controller ctrl="0" value="3"/>
              <controller ctrl="32" value="12"/>
              <program value="40"/>
              <midiChannel>5</midiChannel>
            </Channel>
          </Instrument>
        </Part>
        """
        let parsed = try parse(score(
            voice: chord(67),
            part: part,
            version: "3.6"
        ))

        let noteOn = try XCTUnwrap(parsed.rawEvents.first(where: { $0.velocity > 0 }))
        XCTAssertEqual(parsed.rawEvents.filter { $0.velocity > 0 }.count, 1)
        XCTAssertEqual(noteOn.channel, 5)
        XCTAssertEqual(noteOn.program, 40)
        XCTAssertEqual(noteOn.bankMsb, 3)
        XCTAssertEqual(noteOn.bankLsb, 12)
    }

    func testReadsMSCZRootfilePathWithBackslashes() throws {
        let bytes = msczBytes(rootPath: "/Scores/score.mscx", entryPath: "Scores\\score.mscx")
        let parsed = try MidiWaterfallParser.detectAndParse(
            bytes: MuseScoreConverter.convert(bytes, fileName: "nested.mscz"),
            fileName: "nested.midx"
        )

        XCTAssertEqual(parsed.notes.count, 1)
    }

    func testHonorsMuseScoreTupletIDsAndAbsoluteTickOverrides() throws {
        let voice = """
        <Tuplet id="1"><normalNotes>2</normalNotes><actualNotes>3</actualNotes><baseNote>quarter</baseNote></Tuplet>
        <Chord><Tuplet>1</Tuplet><durationType>quarter</durationType><Note><pitch>60</pitch></Note></Chord>
        <Chord><Tuplet>1</Tuplet><durationType>quarter</durationType><Note><pitch>62</pitch></Note></Chord>
        <tick>700</tick>
        \(chord(64))
        """
        let parsed = try parse(score(voice: voice, version: "3.6"))

        XCTAssertEqual(parsed.notes.map(\.startTick), [0, 320, 700])
    }

    func testAcceptsBOMAndLeadingWhitespaceBeforeMSCX() throws {
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("\n  \(minimalMSCX)".utf8)
        let parsed = try MidiWaterfallParser.detectAndParse(
            bytes: MuseScoreConverter.convert(bytes, fileName: "minimal.mscx"),
            fileName: "minimal.midx"
        )

        XCTAssertEqual(parsed.notes.count, 1)
    }

    func testRejectsDOCTYPEBeforeSystemParserHandlesIt() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE museScore [
          <!ENTITY external SYSTEM "file:///etc/passwd">
        ]>
        <museScore version="4.0"/>
        """

        XCTAssertThrowsError(try MuseScoreConverter.convert(Data(xml.utf8), fileName: "bad.mscx")) {
            XCTAssertTrue($0.localizedDescription.contains("DOCTYPE"))
        }
    }

    func testRendersMuseScoreGraceNotesBeforeMainChord() throws {
        let parsed = try parse(score(voice: """
        <Chord><durationType>eighth</durationType><acciaccatura/><Note><pitch>62</pitch></Note></Chord>
        \(chord(64))
        """, version: "3.6"))

        XCTAssertEqual(parsed.notes.map(\.midiPitch), [62, 64])
        XCTAssertEqual(parsed.notes[0].startTick, 0)
        XCTAssertTrue((1...119).contains(parsed.notes[1].startTick))
    }

    func testExpandsCommonOrnamentsIntoPlaybackEvents() throws {
        let parsed = try parse(score(voice: """
        <Chord>
          <durationType>quarter</durationType>
          <Articulation><subtype>ornamentTurn</subtype></Articulation>
          <Note><pitch>60</pitch></Note>
        </Chord>
        """, version: "3.6"))

        XCTAssertEqual(parsed.notes.map(\.midiPitch), [61, 60, 59, 60])
        XCTAssertEqual(parsed.notes.map(\.startTick), [0, 60, 120, 180])
    }

    func testExpandsMuseScoreTrillSpannersIntoPlaybackEvents() throws {
        let parsed = try parse(score(voice: """
        <Spanner type="Trill">
          <Trill><subtype>trill</subtype></Trill>
          <next><location><fractions>1/2</fractions></location></next>
        </Spanner>
        <Chord><durationType>half</durationType><Note><pitch>60</pitch></Note></Chord>
        """))

        XCTAssertGreaterThan(parsed.notes.count, 1)
        XCTAssertEqual(Array(parsed.notes.prefix(4)).map(\.midiPitch), [60, 61, 60, 61])
        XCTAssertEqual(Array(parsed.notes.prefix(4)).map(\.startTick), [0, 60, 120, 180])
    }

    func testAlternatesMuseScoreTwoChordTremoloPairs() throws {
        let parsed = try parse(score(voice: """
        <Chord>
          <durationType>half</durationType><duration>1/4</duration>
          <Note><pitch>60</pitch></Note><Tremolo><subtype>c16</subtype></Tremolo>
        </Chord>
        <Chord><durationType>half</durationType><duration>1/4</duration><Note><pitch>67</pitch></Note></Chord>
        """))

        XCTAssertEqual(parsed.notes.count, 8)
        XCTAssertEqual(parsed.notes.map(\.midiPitch), [60, 67, 60, 67, 60, 67, 60, 67])
        XCTAssertEqual(Array(parsed.notes.prefix(4)).map(\.startTick), [0, 120, 240, 360])
    }

    func testExpandsMuseScoreGlissandoSpanners() throws {
        let parsed = try parse(score(voice: """
        <Chord><durationType>half</durationType><Note><pitch>60</pitch>
          <Spanner type="Glissando"><Glissando><subtype>1</subtype></Glissando>
            <next><location><fractions>1/2</fractions></location></next>
          </Spanner>
        </Note></Chord>
        <Chord><durationType>half</durationType><Note><pitch>64</pitch>
          <Spanner type="Glissando"><prev><location><fractions>-1/2</fractions></location></prev></Spanner>
        </Note></Chord>
        """))

        XCTAssertGreaterThan(parsed.notes.count, 2)
        XCTAssertEqual(Array(parsed.notes.prefix(3)).map(\.midiPitch), [60, 61, 62])
        XCTAssertTrue(parsed.notes.contains { $0.midiPitch == 64 && $0.startTick >= 900 })
    }

    func testExpandsMuseScoreLegacyBendPoints() throws {
        let parsed = try parse(score(voice: """
        <Chord><durationType>whole</durationType><Note>
          <Bend><point time="0" pitch="0" vibrato="0"/><point time="60" pitch="100" vibrato="0"/></Bend>
          <pitch>62</pitch>
        </Note></Chord>
        """, version: "3.6"))

        XCTAssertGreaterThan(parsed.notes.count, 1)
        XCTAssertTrue(parsed.notes.contains { $0.audioPitch >= 64 })
    }

    func testHonorsMuseScoreOrnamentIntervalsAndUpperStart() throws {
        let parsed = try parse(score(voice: """
        <Chord><durationType>quarter</durationType>
          <Articulation>
            <subtype>ornamentTrill</subtype><intervalAbove>third,minor</intervalAbove><startOnUpperNote>1</startOnUpperNote>
          </Articulation>
          <Note><pitch>60</pitch></Note>
        </Chord>
        """))

        XCTAssertEqual(Array(parsed.notes.prefix(3)).map(\.midiPitch), [63, 60, 63])
    }

    func testAppliesMuseScoreSwingTextToEighthPairs() throws {
        let parsed = try parse(score(voice: """
        <StaffText><swing unit="eighth" ratio="70"/></StaffText>
        \(chord(60, duration: "eighth"))
        \(chord(62, duration: "eighth"))
        \(chord(64))
        """))

        XCTAssertEqual(parsed.notes.map(\.startTick), [0, 336, 480])
    }

    func testHonorsMuseScoreArpeggioDirectionAndStretch() throws {
        let parsed = try parse(score(voice: """
        <Chord><durationType>quarter</durationType>
          <Note><pitch>65</pitch></Note><Note><pitch>69</pitch></Note><Note><pitch>74</pitch></Note>
          <Arpeggio><subtype>2</subtype><timeStretch>3</timeStretch></Arpeggio>
        </Chord>
        """))

        XCTAssertEqual(parsed.notes.sorted { $0.startTick < $1.startTick }.map(\.midiPitch), [74, 69, 65])
        XCTAssertGreaterThan(parsed.notes.map(\.startTick).max() ?? 0, 30)
    }

    func testAppliesMuseScoreOttavaPlaybackShift() throws {
        let parsed = try parse(score(voice: """
        <Spanner type="Ottava"><Ottava><subtype>15mb</subtype></Ottava>
          <next><location><fractions>1/4</fractions></location></next>
        </Spanner>
        \(chord(95))
        """))

        XCTAssertEqual(parsed.notes.map(\.midiPitch), [71])
    }

    func testExtendsMuseScoreLetRingSpanner() throws {
        let parsed = try parse(score(voice: """
        <Spanner type="LetRing"><LetRing/><next><location><fractions>1/2</fractions></location></next></Spanner>
        \(chord(60))
        """))

        let note = try XCTUnwrap(parsed.notes.first)
        XCTAssertGreaterThanOrEqual(note.endTick, 900)
    }

    func testAppliesMuseScorePalmMuteGate() throws {
        let parsed = try parse(score(voice: """
        <Spanner type="PalmMute"><PalmMute/><next><location><fractions>1/4</fractions></location></next></Spanner>
        \(chord(60))
        """))
        let note = try XCTUnwrap(parsed.notes.first)

        XCTAssertLessThan(note.endTick - note.startTick, 300)
    }

    func testOverlapsMuseScoreSlurLegato() throws {
        let parsed = try parse(score(voice: """
        <Spanner type="Slur"><Slur/><next><location><fractions>1/2</fractions></location></next></Spanner>
        \(chord(60))\(chord(62))
        """))

        XCTAssertEqual(parsed.notes.count, 2)
        XCTAssertGreaterThan(parsed.notes[0].endTick, parsed.notes[1].startTick)
    }

    func testExpandsMuseScoreVibratoSpanner() throws {
        let parsed = try parse(score(voice: """
        <Spanner type="Vibrato"><Vibrato><subtype>guitarVibratoWide</subtype></Vibrato>
          <next><location><fractions>1/4</fractions></location></next>
        </Spanner>
        \(chord(60))
        """))

        XCTAssertGreaterThan(parsed.notes.count, 4)
        XCTAssertTrue(parsed.notes.contains { $0.audioPitch > 60.05 || $0.audioPitch < 59.95 })
    }

    func testApproximatesMuseScoreGuitarBendSpanner() throws {
        let parsed = try parse(score(voice: """
        <Chord><durationType>quarter</durationType><Note><pitch>60</pitch>
          <Spanner type="GuitarBend"><GuitarBend>
            <guitarBendType>bend</guitarBendType><bendStartTimeFactor>0</bendStartTimeFactor><bendEndTimeFactor>1</bendEndTimeFactor>
          </GuitarBend><next><location><fractions>1/4</fractions></location></next></Spanner>
        </Note></Chord>
        <Chord><durationType>quarter</durationType><Note><pitch>64</pitch>
          <Spanner type="GuitarBend"><prev><location><fractions>-1/4</fractions></location></prev></Spanner>
        </Note></Chord>
        """, program: 27, version: "5.0"))

        XCTAssertTrue(parsed.notes.contains { $0.startTick < 480 && $0.audioPitch >= 63 })
    }

    func testApproximatesMuseScoreChordLinePlayback() throws {
        let parsed = try parse(score(voice: """
        <Chord><durationType>quarter</durationType><Note><pitch>60</pitch></Note><ChordLine><subtype>4</subtype></ChordLine></Chord>
        """, version: "5.0"))

        XCTAssertEqual(parsed.notes.map(\.midiPitch), [58, 60])
    }

    func testAppliesChordArticulationGateAndVelocity() throws {
        let parsed = try parse(score(voice: """
        <Chord><durationType>quarter</durationType>
          <Articulation><subtype>articAccentStaccatoAbove</subtype></Articulation><Note><pitch>60</pitch></Note>
        </Chord>
        """, version: "3.6"))
        let note = try XCTUnwrap(parsed.notes.first)

        XCTAssertGreaterThan(note.velocity, 80)
        XCTAssertLessThan(note.endTick - note.startTick, 300)
    }

    func testExtendsNotesCoveredByPedalSpanner() throws {
        let parsed = try parse(score(voice: """
        <Spanner type="Pedal"><Pedal/><next><location><fractions>1/2</fractions></location></next></Spanner>
        \(chord(60))
        """, version: "3.6"))

        let note = try XCTUnwrap(parsed.notes.first)
        XCTAssertGreaterThanOrEqual(note.endTick, 900)
    }

    func testAppliesHairpinVelocityRampToFollowingNotes() throws {
        let measures = """
        <Measure><voice>
          <HairPin id="1"><subtype>0</subtype><veloChange>24</veloChange></HairPin>
          \(chord(60))\(chord(62))
        </voice></Measure>
        <Measure><endSpanner id="1"/><voice><Rest><durationType>measure</durationType></Rest></voice></Measure>
        """
        let parsed = try parse(score(measures: measures, version: "3.6"))

        XCTAssertEqual(parsed.notes.count, 2)
        XCTAssertGreaterThan(parsed.notes[1].velocity, parsed.notes[0].velocity)
    }

    func testExtendsFermataChordPlayback() throws {
        let parsed = try parse(score(voice: """
        <Fermata><subtype>fermataAbove</subtype></Fermata>\(chord(60))
        """, version: "3.6"))

        let note = try XCTUnwrap(parsed.notes.first)
        XCTAssertGreaterThan(note.endTick, 600)
    }

    func testUnrollsSimpleStartAndEndRepeats() throws {
        let measures = """
        <Measure><startRepeat/><voice>
          <TimeSig><sigN>4</sigN><sigD>4</sigD></TimeSig>\(chord(60))
        </voice></Measure>
        <Measure><endRepeat>2</endRepeat><voice>\(chord(62))</voice></Measure>
        """
        let parsed = try parse(score(measures: measures, version: "3.6"))

        XCTAssertEqual(parsed.notes.map(\.midiPitch), [60, 62, 60, 62])
        XCTAssertEqual(parsed.notes.map(\.startTick), [0, 1920, 3840, 5760])
    }

    private func parse(_ xml: String) throws -> PlaybackScore {
        try MidiWaterfallParser.detectAndParse(
            bytes: MuseScoreConverter.convert(Data(xml.utf8), fileName: "test.mscx"),
            fileName: "test.midx"
        )
    }

    private func msczBytes(
        rootPath: String = "score.mscx",
        entryPath: String? = nil
    ) -> Data {
        let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container><rootfiles><rootfile full-path="\(rootPath)"/></rootfiles></container>
        """
        return makeZIP([
            ("META-INF/container.xml", Data(container.utf8)),
            (entryPath ?? rootPath, Data(minimalMSCX.utf8)),
        ])
    }

    private func makeZIP(_ entries: [(String, Data)]) -> Data {
        struct DirectoryEntry {
            let name: Data
            let compressed: Data
            let uncompressedSize: Int
            let method: UInt16
            let crc32: UInt32
            let offset: Int
        }
        var archive = Data()
        var directory: [DirectoryEntry] = []
        for (name, data) in entries {
            let nameData = Data(name.utf8)
            let deflated = deflate(data)
            let compressed = deflated.isEmpty && !data.isEmpty ? data : deflated
            let method: UInt16 = compressed.count == data.count && deflated.isEmpty ? 0 : 8
            let checksum = crc32(data)
            let offset = archive.count
            archive.appendLE32(0x0403_4B50)
            archive.appendLE16(20)
            archive.appendLE16(0)
            archive.appendLE16(method)
            archive.appendLE16(0)
            archive.appendLE16(0)
            archive.appendLE32(checksum)
            archive.appendLE32(UInt32(compressed.count))
            archive.appendLE32(UInt32(data.count))
            archive.appendLE16(UInt16(nameData.count))
            archive.appendLE16(0)
            archive.append(nameData)
            archive.append(compressed)
            directory.append(
                DirectoryEntry(
                    name: nameData,
                    compressed: compressed,
                    uncompressedSize: data.count,
                    method: method,
                    crc32: checksum,
                    offset: offset
                )
            )
        }
        let centralOffset = archive.count
        for entry in directory {
            archive.appendLE32(0x0201_4B50)
            archive.appendLE16(20)
            archive.appendLE16(20)
            archive.appendLE16(0)
            archive.appendLE16(entry.method)
            archive.appendLE16(0)
            archive.appendLE16(0)
            archive.appendLE32(entry.crc32)
            archive.appendLE32(UInt32(entry.compressed.count))
            archive.appendLE32(UInt32(entry.uncompressedSize))
            archive.appendLE16(UInt16(entry.name.count))
            archive.appendLE16(0)
            archive.appendLE16(0)
            archive.appendLE16(0)
            archive.appendLE16(0)
            archive.appendLE32(0)
            archive.appendLE32(UInt32(entry.offset))
            archive.append(entry.name)
        }
        let centralSize = archive.count - centralOffset
        archive.appendLE32(0x0605_4B50)
        archive.appendLE16(0)
        archive.appendLE16(0)
        archive.appendLE16(UInt16(directory.count))
        archive.appendLE16(UInt16(directory.count))
        archive.appendLE32(UInt32(centralSize))
        archive.appendLE32(UInt32(centralOffset))
        archive.appendLE16(0)
        return archive
    }

    private func deflate(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        var output = Data(count: max(128, data.count + data.count / 8 + 128))
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!,
                    destination.count,
                    source.bindMemory(to: UInt8.self).baseAddress!,
                    source.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return Data() }
        output.removeSubrange(written..<output.count)
        return output
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 0 ? crc >> 1 : (crc >> 1) ^ 0xEDB8_8320
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private var minimalMSCX: String {
        score(voice: """
        <TimeSig><sigN>4</sigN><sigD>4</sigD></TimeSig>
        <Tempo><tempo>2</tempo></Tempo>
        <Chord><durationType>quarter</durationType><Note><pitch>60</pitch><tuning>12.5</tuning></Note></Chord>
        """)
    }

    private var midxOffsetMarker: Data {
        Data([0xFF, 0x7F, 0x07, 0x7D, 0x58, 0x54, 0x03])
    }

    private func chord(_ pitch: Int, duration: String = "quarter") -> String {
        "<Chord><durationType>\(duration)</durationType><Note><pitch>\(pitch)</pitch></Note></Chord>"
    }

    private func score(
        voice: String,
        part: String? = nil,
        program: Int = 0,
        version: String = "4.0"
    ) -> String {
        score(
            measures: "<Measure><voice>\(voice)</voice></Measure>",
            part: part,
            program: program,
            version: version
        )
    }

    private func score(
        measures: String,
        part: String? = nil,
        program: Int = 0,
        version: String = "4.0"
    ) -> String {
        let partXML = part ?? """
        <Part><Staff id="1"/><Instrument><Channel><program value="\(program)"/></Channel></Instrument></Part>
        """
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="\(version)"><Score><Division>480</Division>
          \(partXML)
          <Staff id="1">\(measures)</Staff>
        </Score></museScore>
        """
    }
}

private extension Data {
    func contains(_ needle: Data) -> Bool {
        guard !needle.isEmpty, needle.count <= count else { return false }
        return range(of: needle) != nil
    }

    mutating func appendLE16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
