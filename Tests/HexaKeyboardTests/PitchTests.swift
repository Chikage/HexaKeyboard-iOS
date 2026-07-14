import XCTest
@testable import HexaKeyboardCore

final class PitchTests: XCTestCase {
    func testFiftyThreeEDOCoordinatesKeepOctaveInformation() {
        let pitch = PitchMapper.pitch(
            for: AxialCoordinate(q: 5, r: 2),
            edo: 53,
            stepQ: 9,
            stepR: 4
        )

        XCTAssertEqual(pitch.step, 53)
        XCTAssertEqual(pitch.midiPitch, 72)
        XCTAssertEqual(pitch.midiKey, 72)
        XCTAssertEqual(pitch.cents, 0)
        XCTAssertEqual(pitch.frequency, c4FrequencyHz * 2, accuracy: 1e-12)
        XCTAssertTrue(pitch.isPlayable)
    }

    func testMicrotonalPitchUsesNearestMIDIKeyAndCents() {
        let pitch = PitchMapper.pitch(forStep: 1, edo: 53)

        XCTAssertEqual(pitch.midiKey, 60)
        XCTAssertEqual(pitch.cents, 22.641509433962256, accuracy: 1e-12)
        XCTAssertEqual(PitchMapper.pitchWheelValue(cents: pitch.cents), 10_047)
    }

    func testPositiveModuloNormalizesNegativePitchSteps() {
        XCTAssertEqual(positiveModulo(-1, modulus: 53), 52)
        XCTAssertEqual(positiveModulo(-54, modulus: 53), 52)
        XCTAssertEqual(positiveModulo(-53, modulus: 53), 0)
        XCTAssertEqual(positiveModulo(54, modulus: 53), 1)

        let layout = HexaKeyboardLayoutEngine.build()
        let key = layout.cell(at: AxialCoordinate(q: -1, r: 0))
        XCTAssertEqual(key?.step, -9)
        XCTAssertEqual(key?.pitchClass, 44)
    }

    func testInvalidEDOAndOutOfRangePitchAreNotPlayable() {
        XCTAssertFalse(PitchMapper.pitch(forStep: 0, edo: 0).isPlayable)
        XCTAssertFalse(PitchMapper.pitch(forStep: 1_000, edo: 2).isPlayable)
        XCTAssertEqual(PitchMapper.pitchWheelValue(cents: .infinity), 8192)
    }
}
