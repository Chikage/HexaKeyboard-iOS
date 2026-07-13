import XCTest
@testable import HexaKeyboardCore

final class PitchTests: XCTestCase {
    func testTwentySixEDOCoordinatesKeepOctaveInformation() {
        let pitch = PitchMapper.pitch(
            for: AxialCoordinate(q: 2, r: 2),
            edo: 26,
            stepQ: 9,
            stepR: 4
        )

        XCTAssertEqual(pitch.step, 26)
        XCTAssertEqual(pitch.midiPitch, 72)
        XCTAssertEqual(pitch.midiKey, 72)
        XCTAssertEqual(pitch.cents, 0)
        XCTAssertEqual(pitch.frequency, c4FrequencyHz * 2, accuracy: 1e-12)
        XCTAssertTrue(pitch.isPlayable)
    }

    func testMicrotonalPitchUsesNearestMIDIKeyAndCents() {
        let pitch = PitchMapper.pitch(forStep: 1, edo: 19)

        XCTAssertEqual(pitch.midiKey, 61)
        XCTAssertEqual(pitch.cents, -36.84210526315752, accuracy: 1e-12)
        XCTAssertEqual(PitchMapper.pitchWheelValue(cents: pitch.cents), 5174)
    }

    func testPositiveModuloNormalizesNegativePitchSteps() {
        XCTAssertEqual(positiveModulo(-1, modulus: 26), 25)
        XCTAssertEqual(positiveModulo(-27, modulus: 26), 25)
        XCTAssertEqual(positiveModulo(-26, modulus: 26), 0)
        XCTAssertEqual(positiveModulo(27, modulus: 26), 1)

        let layout = HexaKeyboardLayoutEngine.build()
        let key = layout.cell(at: AxialCoordinate(q: -1, r: 0))
        XCTAssertEqual(key?.step, -9)
        XCTAssertEqual(key?.pitchClass, 17)
    }

    func testInvalidEDOAndOutOfRangePitchAreNotPlayable() {
        XCTAssertFalse(PitchMapper.pitch(forStep: 0, edo: 0).isPlayable)
        XCTAssertFalse(PitchMapper.pitch(forStep: 1_000, edo: 2).isPlayable)
        XCTAssertEqual(PitchMapper.pitchWheelValue(cents: .infinity), 8192)
    }
}
