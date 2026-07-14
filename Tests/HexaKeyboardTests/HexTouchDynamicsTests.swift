import XCTest
@testable import HexaKeyboardCore

final class HexTouchDynamicsTests: XCTestCase {
    private lazy var layout = HexaKeyboardLayoutEngine.build()

    func testNearestCellCaptureRemovesKeySeamDeadZone() throws {
        let origin = try XCTUnwrap(layout.cell(at: .origin))
        let neighbor = try XCTUnwrap(
            layout.cells
                .filter { $0.coordinate != origin.coordinate }
                .min { squaredDistance($0.center, origin.center) < squaredDistance($1.center, origin.center) }
        )
        let seam = HexPoint(
            x: (origin.center.x + neighbor.center.x) / 2,
            y: (origin.center.y + neighbor.center.y) / 2
        )

        let key = HexTouchHitTester.key(at: seam, in: layout, sensitivity: 1.2)
        XCTAssertTrue(key == origin || key == neighbor)
    }

    func testSensitivityExtendsCapturePastOuterKeyEdge() throws {
        let edge = try XCTUnwrap(layout.cells.max {
            squaredDistance($0.center, layout.keyBounds.center)
                < squaredDistance($1.center, layout.keyBounds.center)
        })
        let dx = edge.center.x - layout.keyBounds.center.x
        let dy = edge.center.y - layout.keyBounds.center.y
        let length = hypot(dx, dy)
        let point = HexPoint(
            x: edge.center.x + dx / length * Double(layout.configuration.radius) * 1.12,
            y: edge.center.y + dy / length * Double(layout.configuration.radius) * 1.12
        )

        XCTAssertEqual(
            HexTouchHitTester.key(at: point, in: layout, sensitivity: 1.2)?.coordinate,
            edge.coordinate
        )
        XCTAssertNil(HexTouchHitTester.key(at: point, in: layout, sensitivity: 1.0))
    }

    func testPreviousKeyIsRetainedUntilPointerClearlyCrossesBoundary() throws {
        let origin = try XCTUnwrap(layout.cell(at: .origin))
        let neighbor = try XCTUnwrap(
            layout.cells
                .filter { $0.coordinate != origin.coordinate }
                .min { squaredDistance($0.center, origin.center) < squaredDistance($1.center, origin.center) }
        )
        let nearBoundary = interpolate(origin.center, neighbor.center, amount: 0.53)
        let clearlyAcross = interpolate(origin.center, neighbor.center, amount: 0.64)

        XCTAssertEqual(
            HexTouchHitTester.key(
                at: nearBoundary,
                in: layout,
                previousCoordinate: origin.coordinate
            )?.coordinate,
            origin.coordinate
        )
        XCTAssertEqual(
            HexTouchHitTester.key(
                at: clearlyAcross,
                in: layout,
                previousCoordinate: origin.coordinate
            )?.coordinate,
            neighbor.coordinate
        )
    }

    func testDefaultPressureUsesPseudoSignalInsteadOfMaximum() throws {
        let origin = try XCTUnwrap(layout.cell(at: .origin))
        let force = PseudoPressureTracker().sample(
            rawPressure: 1,
            uptimeMilliseconds: 100,
            point: origin.center,
            keyCenter: origin.center,
            keyRadius: Double(layout.configuration.radius)
        )

        XCTAssertFalse(force.usesHardwarePressure)
        XCTAssertTrue((90..<127).contains(force.velocity))
        XCTAssertTrue((90..<127).contains(force.expression))
    }

    func testRealPressureProducesWiderResponse() throws {
        let origin = try XCTUnwrap(layout.cell(at: .origin))
        let soft = PseudoPressureTracker().sample(
            rawPressure: 0.12,
            uptimeMilliseconds: 100,
            point: origin.center,
            keyCenter: origin.center,
            keyRadius: 24
        )
        let hard = PseudoPressureTracker().sample(
            rawPressure: 0.82,
            uptimeMilliseconds: 100,
            point: origin.center,
            keyCenter: origin.center,
            keyRadius: 24
        )

        XCTAssertTrue(soft.usesHardwarePressure)
        XCTAssertTrue(hard.usesHardwarePressure)
        XCTAssertGreaterThan(hard.velocity, soft.velocity)
        XCTAssertGreaterThan(hard.expression, soft.expression)
    }

    func testFallbackForceRespondsToPlacementAndHoldTime() throws {
        let origin = try XCTUnwrap(layout.cell(at: .origin))
        let centerTracker = PseudoPressureTracker()
        let edgeTracker = PseudoPressureTracker()
        let centerAtDown = centerTracker.sample(
            rawPressure: 1,
            uptimeMilliseconds: 100,
            point: origin.center,
            keyCenter: origin.center,
            keyRadius: 24
        )
        let edgeAtDown = edgeTracker.sample(
            rawPressure: 1,
            uptimeMilliseconds: 100,
            point: HexPoint(x: origin.center.x + 24, y: origin.center.y),
            keyCenter: origin.center,
            keyRadius: 24
        )
        let centerAfterHold = centerTracker.sample(
            rawPressure: 1,
            uptimeMilliseconds: 500,
            point: origin.center,
            keyCenter: origin.center,
            keyRadius: 24
        )

        XCTAssertGreaterThan(centerAtDown.velocity, edgeAtDown.velocity)
        XCTAssertGreaterThan(centerAfterHold.expression, centerAtDown.expression)
    }

    private func squaredDistance(_ first: HexPoint, _ second: HexPoint) -> Double {
        let dx = first.x - second.x
        let dy = first.y - second.y
        return dx * dx + dy * dy
    }

    private func interpolate(
        _ first: HexPoint,
        _ second: HexPoint,
        amount: Double
    ) -> HexPoint {
        HexPoint(
            x: first.x + (second.x - first.x) * amount,
            y: first.y + (second.y - first.y) * amount
        )
    }
}
