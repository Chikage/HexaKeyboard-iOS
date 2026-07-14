import Foundation
import XCTest
@testable import HexaKeyboardCore

final class ScoreContentParserTests: XCTestCase {
    private let parser = ScoreContentParser()

    func testSupportsEveryPlaybackFileExtension() throws {
        XCTAssertEqual(
            ScoreContentParser.supportedExtensions,
            ["mid", "midi", "midix", "midx", "midi2", "mscz", "mscx"]
        )
        XCTAssertEqual(try parser.classify(fileName: "song.mid", data: Data()), .standardMIDI)
        XCTAssertEqual(try parser.classify(fileName: "song.midi2", data: Data()), .midi2Clip)
        XCTAssertEqual(try parser.classify(fileName: "song.mscz", data: Data()), .museScore)
        XCTAssertTrue(parser.supports(fileName: "SONG.MIDIX"))
        XCTAssertFalse(parser.supports(fileName: "song.wav"))
    }

    func testRecognizesContentFromHeader() throws {
        XCTAssertEqual(
            try parser.classify(fileName: "unknown.bin", data: Data("MThd".utf8)),
            .standardMIDI
        )
        XCTAssertEqual(
            try parser.classify(fileName: "unknown.bin", data: Data("SMF2CLIP".utf8)),
            .midi2Clip
        )
        XCTAssertEqual(
            try parser.classify(
                fileName: "unknown.bin",
                data: Data([0x50, 0x4B, 0x03, 0x04])
            ),
            .museScore
        )
    }

    func testRejectsUnsupportedContent() {
        XCTAssertThrowsError(
            try parser.classify(fileName: "audio.wav", data: Data())
        ) { error in
            XCTAssertEqual(
                error as? ScoreContentParserError,
                .unsupportedFormat("audio.wav")
            )
        }
    }

    func testRejectsOversizedFilesBeforeParsing() {
        let data = Data(count: ScoreContentParser.maximumFileBytes + 1)
        XCTAssertThrowsError(try parser.parseScore(fileName: "large.mid", data: data)) { error in
            XCTAssertEqual(
                error as? ScoreContentParserError,
                .fileTooLarge(maximumBytes: ScoreContentParser.maximumFileBytes)
            )
        }
    }
}
