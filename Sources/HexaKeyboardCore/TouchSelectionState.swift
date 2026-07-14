import Foundation

public struct TouchSelectionState: Equatable, Sendable {
    public static let defaultJoinGraceMilliseconds: Int64 = 160

    public var coordinatesByPointer: [Int: AxialCoordinate]
    public var latchedCoordinates: Set<AxialCoordinate>
    public var anchorCoordinate: AxialCoordinate?
    public var joinDeadlineMilliseconds: Int64?

    public var selectedCoordinates: Set<AxialCoordinate> {
        if !latchedCoordinates.isEmpty {
            return latchedCoordinates
        }
        return anchorCoordinate.map { [$0] } ?? []
    }

    public init(
        coordinatesByPointer: [Int: AxialCoordinate] = [:],
        latchedCoordinates: Set<AxialCoordinate> = [],
        anchorCoordinate: AxialCoordinate? = nil,
        joinDeadlineMilliseconds: Int64? = nil
    ) {
        self.coordinatesByPointer = coordinatesByPointer
        self.latchedCoordinates = latchedCoordinates
        self.anchorCoordinate = anchorCoordinate
        self.joinDeadlineMilliseconds = joinDeadlineMilliseconds
    }

    public func pressing(
        pointerID: Int,
        coordinate: AxialCoordinate,
        eventTimeMilliseconds: Int64
    ) -> TouchSelectionState {
        let canJoinCurrentChord = !coordinatesByPointer.isEmpty
            || joinDeadlineMilliseconds.map { eventTimeMilliseconds <= $0 } == true
        let previousCoordinate = coordinatesByPointer[pointerID]
        let heldByAnotherPointer = previousCoordinate.map { previous in
            coordinatesByPointer.contains { pointer, coordinate in
                pointer != pointerID && coordinate == previous
            }
        } ?? false
        var selection = canJoinCurrentChord ? latchedCoordinates : []
        if let previousCoordinate, !heldByAnotherPointer {
            selection.remove(previousCoordinate)
        }
        selection.insert(coordinate)

        var pointers = coordinatesByPointer
        pointers[pointerID] = coordinate
        return TouchSelectionState(
            coordinatesByPointer: pointers,
            latchedCoordinates: selection,
            anchorCoordinate: coordinate,
            joinDeadlineMilliseconds: nil
        )
    }

    public func releasing(
        pointerID: Int,
        eventTimeMilliseconds: Int64,
        retainForChord: Bool,
        joinGraceMilliseconds: Int64 = TouchSelectionState.defaultJoinGraceMilliseconds
    ) -> TouchSelectionState {
        guard let releasedCoordinate = coordinatesByPointer[pointerID] else {
            return self
        }

        var remaining = coordinatesByPointer
        remaining.removeValue(forKey: pointerID)
        let stillHeld = remaining.values.contains(releasedCoordinate)
        var selection = latchedCoordinates
        if !retainForChord, !stillHeld {
            selection.remove(releasedCoordinate)
        }

        let nextAnchor: AxialCoordinate?
        if let anchorCoordinate, remaining.values.contains(anchorCoordinate) {
            nextAnchor = anchorCoordinate
        } else if let remainingCoordinate = remaining.first?.value {
            nextAnchor = remainingCoordinate
        } else if let anchorCoordinate, selection.contains(anchorCoordinate) {
            nextAnchor = anchorCoordinate
        } else if let selectedCoordinate = selection.first {
            nextAnchor = selectedCoordinate
        } else if retainForChord {
            nextAnchor = releasedCoordinate
        } else {
            nextAnchor = nil
        }

        return TouchSelectionState(
            coordinatesByPointer: remaining,
            latchedCoordinates: selection,
            anchorCoordinate: nextAnchor,
            joinDeadlineMilliseconds: remaining.isEmpty
                ? eventTimeMilliseconds + max(0, joinGraceMilliseconds)
                : nil
        )
    }

    public func releasingAll() -> TouchSelectionState {
        var next = self
        next.coordinatesByPointer.removeAll()
        next.joinDeadlineMilliseconds = nil
        return next
    }

    public func retainingCoordinates(
        _ validCoordinates: Set<AxialCoordinate>,
        fallbackCoordinate: AxialCoordinate?
    ) -> TouchSelectionState {
        let retainedPointers = coordinatesByPointer.filter { validCoordinates.contains($0.value) }
        let retainedSelection = latchedCoordinates.intersection(validCoordinates)
        let retainedAnchor = anchorCoordinate.flatMap { validCoordinates.contains($0) ? $0 : nil }
            ?? retainedPointers.first?.value
            ?? retainedSelection.first
            ?? fallbackCoordinate.flatMap { validCoordinates.contains($0) ? $0 : nil }
        let selection = retainedSelection.isEmpty
            ? retainedAnchor.map { Set<AxialCoordinate>([$0]) } ?? []
            : retainedSelection

        return TouchSelectionState(
            coordinatesByPointer: retainedPointers,
            latchedCoordinates: selection,
            anchorCoordinate: retainedAnchor,
            joinDeadlineMilliseconds: nil
        )
    }
}
