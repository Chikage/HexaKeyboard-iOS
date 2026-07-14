import XCTest
@testable import HexaKeyboardCore

final class TouchSelectionStateTests: XCTestCase {
    private let first = AxialCoordinate(q: 0, r: 0)
    private let second = AxialCoordinate(q: 1, r: 0)
    private let third = AxialCoordinate(q: 0, r: 1)

    func testOverlappingPointersKeepTwoCoordinatesSelected() {
        let state = TouchSelectionState()
            .pressing(pointerID: 10, coordinate: first, eventTimeMilliseconds: 100)
            .pressing(pointerID: 20, coordinate: second, eventTimeMilliseconds: 400)

        XCTAssertEqual(state.selectedCoordinates, [first, second])
        XCTAssertEqual(state.anchorCoordinate, second)
    }

    func testSlightlyAsynchronousPressJoinsRecentlyReleasedChord() {
        let state = TouchSelectionState()
            .pressing(pointerID: 10, coordinate: first, eventTimeMilliseconds: 100)
            .releasing(
                pointerID: 10,
                eventTimeMilliseconds: 180,
                retainForChord: true
            )
            .pressing(pointerID: 20, coordinate: second, eventTimeMilliseconds: 300)

        XCTAssertEqual(state.selectedCoordinates, [first, second])
        XCTAssertEqual(state.coordinatesByPointer, [20: second])
    }

    func testPressOutsideGraceWindowStartsNewChord() {
        let state = TouchSelectionState()
            .pressing(pointerID: 10, coordinate: first, eventTimeMilliseconds: 100)
            .releasing(
                pointerID: 10,
                eventTimeMilliseconds: 180,
                retainForChord: true
            )
            .pressing(pointerID: 20, coordinate: second, eventTimeMilliseconds: 400)

        XCTAssertEqual(state.selectedCoordinates, [second])
        XCTAssertEqual(state.anchorCoordinate, second)
    }

    func testSlidingPointerReplacesOldCoordinateWithoutLeavingTrail() {
        let state = TouchSelectionState()
            .pressing(pointerID: 10, coordinate: first, eventTimeMilliseconds: 100)
            .pressing(pointerID: 20, coordinate: second, eventTimeMilliseconds: 110)
            .releasing(pointerID: 10, eventTimeMilliseconds: 150, retainForChord: false)
            .pressing(pointerID: 10, coordinate: third, eventTimeMilliseconds: 150)

        XCTAssertEqual(state.selectedCoordinates, [second, third])
        XCTAssertEqual(state.anchorCoordinate, third)
    }

    func testCompletedChordRemainsSelectedUntilNextSeparateChordStarts() {
        let completed = TouchSelectionState()
            .pressing(pointerID: 10, coordinate: first, eventTimeMilliseconds: 100)
            .pressing(pointerID: 20, coordinate: second, eventTimeMilliseconds: 110)
            .releasing(pointerID: 10, eventTimeMilliseconds: 180, retainForChord: true)
            .releasing(pointerID: 20, eventTimeMilliseconds: 190, retainForChord: true)

        XCTAssertEqual(completed.selectedCoordinates, [first, second])
        XCTAssertEqual(
            completed
                .pressing(pointerID: 30, coordinate: third, eventTimeMilliseconds: 400)
                .selectedCoordinates,
            [third]
        )
    }

    func testReleasingOnePointerKeepsRemainingChordSelectionsLatched() {
        let state = TouchSelectionState()
            .pressing(pointerID: 10, coordinate: first, eventTimeMilliseconds: 100)
            .pressing(pointerID: 20, coordinate: second, eventTimeMilliseconds: 110)
            .releasing(pointerID: 20, eventTimeMilliseconds: 180, retainForChord: true)

        XCTAssertEqual(state.selectedCoordinates, [first, second])
        XCTAssertEqual(state.anchorCoordinate, first)
    }

    func testReleasingOneOfTwoPointersOnSameKeyKeepsKeySelected() {
        let state = TouchSelectionState()
            .pressing(pointerID: 10, coordinate: first, eventTimeMilliseconds: 100)
            .pressing(pointerID: 20, coordinate: first, eventTimeMilliseconds: 110)
            .releasing(pointerID: 10, eventTimeMilliseconds: 150, retainForChord: false)

        XCTAssertEqual(state.selectedCoordinates, [first])
        XCTAssertEqual(state.coordinatesByPointer, [20: first])
    }
}
