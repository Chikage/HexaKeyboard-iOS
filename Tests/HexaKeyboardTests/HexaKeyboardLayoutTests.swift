import XCTest
@testable import HexaKeyboardCore

final class HexaKeyboardLayoutTests: XCTestCase {
    func testRequiredDefaultsBuildFixedSizeRotatedKeyboard() {
        let configuration = HexaKeyboardConfiguration.default
        let layout = HexaKeyboardLayoutEngine.build(configuration: configuration)

        XCTAssertEqual(configuration.columns, 35)
        XCTAssertEqual(configuration.rows, 8)
        XCTAssertEqual(configuration.period, 53)
        XCTAssertEqual(configuration.stepQ, 9)
        XCTAssertEqual(configuration.stepR, 4)
        XCTAssertEqual(configuration.radius, 24)
        XCTAssertEqual(configuration.rotationDegrees, 12)
        XCTAssertEqual(configuration.frameAcuteAngleDegrees, 72)
        XCTAssertEqual(layout.cells.count, 280)
        XCTAssertEqual(Set(layout.cells.map(\.coordinate)).count, 280)
        XCTAssertEqual(layout.stats, RotationStats(generated: 56, omitted: 56))
    }

    func testRadiusIsAlwaysNormalizedToTwentyFour() {
        XCTAssertEqual(HexaKeyboardConfiguration(radius: 14).normalized().radius, 24)
        XCTAssertEqual(HexaKeyboardConfiguration(radius: 34).normalized().radius, 24)
    }

    func testOriginUsesOddQCenteredWindowAndAnchorsC4() throws {
        let layout = HexaKeyboardLayoutEngine.build()
        let origin = try XCTUnwrap(layout.cell(at: .origin))

        XCTAssertEqual(origin.coordinate, AxialCoordinate(q: 0, r: 0))
        XCTAssertEqual(origin.s, 0)
        XCTAssertEqual(origin.step, 0)
        XCTAssertEqual(origin.pitchClass, 0)
        XCTAssertEqual(origin.center, HexPoint(x: 0, y: 0))
        XCTAssertEqual(origin.audioPitch.midiPitch, 60)
        XCTAssertEqual(origin.audioPitch.midiKey, 60)
        XCTAssertEqual(origin.audioPitch.cents, 0)
        XCTAssertEqual(origin.audioPitch.frequency, c4FrequencyHz)
        XCTAssertTrue(origin.audioPitch.isPlayable)

        XCTAssertEqual(layout.slots.first?.coordinate, AxialCoordinate(q: -17, r: 5))
        XCTAssertEqual(layout.slots.last?.coordinate, AxialCoordinate(q: 17, r: -5))
        XCTAssertEqual(layout.defaultSelection?.coordinate, .origin)
    }

    func testDefaultPeriodVectorsAreShortestIndependentSolutions() {
        let vectors = HexaKeyboardLayoutEngine.periodVectors(for: .default)

        XCTAssertEqual(
            vectors,
            [
                PeriodVector(dq: -5, dr: -2, distance: 7),
                PeriodVector(dq: -4, dr: 9, distance: 9),
            ]
        )
        for vector in vectors {
            XCTAssertEqual(
                positiveModulo(vector.dq * 9 + vector.dr * 4, modulus: 53),
                0
            )
        }
        XCTAssertNotEqual(
            vectors[0].dq * vectors[1].dr - vectors[0].dr * vectors[1].dq,
            0
        )
    }

    func testDefaultWindowParallelogramHasSeventyTwoDegreeTargetCorners() {
        let layout = HexaKeyboardLayoutEngine.build()
        let outline = layout.windowOutline

        XCTAssertEqual(outline.topLeft.x, -694.4480407125614, accuracy: 1e-9)
        XCTAssertEqual(outline.topLeft.y, -169.4922678357857, accuracy: 1e-9)
        XCTAssertEqual(outline.topRight.x, 577.5519592874386, accuracy: 1e-9)
        XCTAssertEqual(outline.topRight.y, -169.4922678357857, accuracy: 1e-9)
        XCTAssertEqual(outline.bottomRight.x, 694.4480407125614, accuracy: 1e-9)
        XCTAssertEqual(outline.bottomRight.y, 190.27687752661222, accuracy: 1e-9)
        XCTAssertEqual(outline.bottomLeft.x, -577.5519592874386, accuracy: 1e-9)
        XCTAssertEqual(outline.bottomLeft.y, 190.27687752661222, accuracy: 1e-9)
        XCTAssertEqual(interiorAngle(at: outline.topLeft, outline.topRight, outline.bottomLeft), 72, accuracy: 1e-12)
        XCTAssertEqual(interiorAngle(at: outline.bottomRight, outline.bottomLeft, outline.topRight), 72, accuracy: 1e-12)
    }

    func testRotatedSelectionPreservesReferenceCornerCells() {
        let layout = HexaKeyboardLayoutEngine.build()

        XCTAssertEqual(layout.cells.first?.coordinate, AxialCoordinate(q: 15, r: -14))
        XCTAssertEqual(layout.cells.first?.center.x ?? .nan, 584.3774278657452, accuracy: 1e-9)
        XCTAssertEqual(layout.cells.first?.center.y ?? .nan, -152.0230962749274, accuracy: 1e-9)
        XCTAssertEqual(layout.cells.last?.coordinate, AxialCoordinate(q: -7, r: 9))
        XCTAssertEqual(layout.cells.last?.center.x ?? .nan, -294.02819216679524, accuracy: 1e-9)
        XCTAssertEqual(layout.cells.last?.center.y ?? .nan, 171.24083102790098, accuracy: 1e-9)
    }

    private func interiorAngle(
        at vertex: HexPoint,
        _ firstEndpoint: HexPoint,
        _ secondEndpoint: HexPoint
    ) -> Double {
        let first = HexPoint(x: firstEndpoint.x - vertex.x, y: firstEndpoint.y - vertex.y)
        let second = HexPoint(x: secondEndpoint.x - vertex.x, y: secondEndpoint.y - vertex.y)
        let cross = first.x * second.y - first.y * second.x
        let dot = first.x * second.x + first.y * second.y
        return atan2(abs(cross), dot) * 180 / .pi
    }
}
