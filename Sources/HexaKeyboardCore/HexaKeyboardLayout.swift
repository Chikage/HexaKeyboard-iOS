import Foundation

public struct HexaKeyboardConfiguration: Equatable, Sendable {
    public var columns: Int
    public var rows: Int
    public var period: Int
    public var stepQ: Int
    public var stepR: Int
    public var radius: Int
    public var rotationDegrees: Int
    public var frameAcuteAngleDegrees: Double

    public init(
        columns: Int = 35,
        rows: Int = 8,
        period: Int = 26,
        stepQ: Int = 9,
        stepR: Int = 4,
        radius: Int = 24,
        rotationDegrees: Int = 12,
        frameAcuteAngleDegrees: Double = 72
    ) {
        self.columns = columns
        self.rows = rows
        self.period = period
        self.stepQ = stepQ
        self.stepR = stepR
        self.radius = radius
        self.rotationDegrees = rotationDegrees
        self.frameAcuteAngleDegrees = frameAcuteAngleDegrees
    }

    public static let `default` = HexaKeyboardConfiguration()

    /// Matches the input constraints applied by `readState` in the reference app.
    public func normalized() -> HexaKeyboardConfiguration {
        HexaKeyboardConfiguration(
            columns: columns.clamped(to: 4...64),
            rows: rows.clamped(to: 3...32),
            period: period.clamped(to: 2...200),
            stepQ: stepQ.clamped(to: -200...200),
            stepR: stepR.clamped(to: -200...200),
            radius: radius.clamped(to: 14...34),
            rotationDegrees: rotationDegrees.clamped(to: -60...60),
            frameAcuteAngleDegrees: frameAcuteAngleDegrees
        )
    }
}

public struct HexKey: Equatable, Sendable {
    public let coordinate: AxialCoordinate
    public let step: Int
    public let pitchClass: Int
    public let audioPitch: EDOPitch
    public let center: HexPoint

    public var q: Int { coordinate.q }
    public var r: Int { coordinate.r }
    public var s: Int { coordinate.s }

    public init(
        coordinate: AxialCoordinate,
        step: Int,
        pitchClass: Int,
        audioPitch: EDOPitch,
        center: HexPoint
    ) {
        self.coordinate = coordinate
        self.step = step
        self.pitchClass = pitchClass
        self.audioPitch = audioPitch
        self.center = center
    }
}

public struct HexWindowSlot: Equatable, Sendable {
    public let column: Int
    public let row: Int
    public let key: HexKey

    public var coordinate: AxialCoordinate { key.coordinate }
    public var center: HexPoint { key.center }
    public var q: Int { key.q }
    public var r: Int { key.r }
    public var s: Int { key.s }
    public var step: Int { key.step }
    public var pitchClass: Int { key.pitchClass }
    public var audioPitch: EDOPitch { key.audioPitch }

    public init(column: Int, row: Int, key: HexKey) {
        self.column = column
        self.row = row
        self.key = key
    }
}

public struct RotationStats: Equatable, Sendable {
    public let generated: Int
    public let omitted: Int

    public init(generated: Int, omitted: Int) {
        self.generated = generated
        self.omitted = omitted
    }
}

public struct PeriodVector: Hashable, Sendable {
    public let dq: Int
    public let dr: Int
    public let distance: Int

    public var coordinate: AxialCoordinate { AxialCoordinate(q: dq, r: dr) }

    public init(dq: Int, dr: Int, distance: Int) {
        self.dq = dq
        self.dr = dr
        self.distance = distance
    }
}

public struct HexaKeyboardLayout: Equatable, Sendable {
    public let configuration: HexaKeyboardConfiguration
    public let cells: [HexKey]
    public let slots: [HexWindowSlot]
    public let stats: RotationStats
    public let periodVectors: [PeriodVector]
    public let slotCenterBounds: HexBounds
    public let windowBounds: HexBounds
    public let windowOutline: HexParallelogram
    public let keyBounds: HexBounds

    public var defaultSelection: HexKey? {
        cells.first(where: { $0.coordinate == .origin })
            ?? cells[safe: cells.count / 2]
    }

    public func cell(at coordinate: AxialCoordinate) -> HexKey? {
        cells.first(where: { $0.coordinate == coordinate })
    }

    public init(
        configuration: HexaKeyboardConfiguration,
        cells: [HexKey],
        slots: [HexWindowSlot],
        stats: RotationStats,
        periodVectors: [PeriodVector],
        slotCenterBounds: HexBounds,
        windowBounds: HexBounds,
        windowOutline: HexParallelogram,
        keyBounds: HexBounds
    ) {
        self.configuration = configuration
        self.cells = cells
        self.slots = slots
        self.stats = stats
        self.periodVectors = periodVectors
        self.slotCenterBounds = slotCenterBounds
        self.windowBounds = windowBounds
        self.windowOutline = windowOutline
        self.keyBounds = keyBounds
    }
}

public enum HexaKeyboardLayoutEngine {
    public static func build(
        configuration requestedConfiguration: HexaKeyboardConfiguration = .default
    ) -> HexaKeyboardLayout {
        let configuration = requestedConfiguration.normalized()
        let slots = buildWindowSlots(configuration: configuration)
        let slotCenterBounds = HexBounds(points: slots.map(\.center))
        let selection = selectCells(
            slots: slots,
            centerBounds: slotCenterBounds,
            configuration: configuration
        )
        let radius = Double(configuration.radius)
        let windowBounds = HexBounds(points: slots.map(\.center), radius: radius)
        let outline = HexGeometry.parallelogram(
            around: windowBounds,
            acuteAngleDegrees: configuration.frameAcuteAngleDegrees
        )

        return HexaKeyboardLayout(
            configuration: configuration,
            cells: selection.cells,
            slots: slots,
            stats: selection.stats,
            periodVectors: periodVectors(for: configuration),
            slotCenterBounds: slotCenterBounds,
            windowBounds: windowBounds,
            windowOutline: outline,
            keyBounds: HexBounds(points: selection.cells.map(\.center), radius: radius)
        )
    }

    public static func periodVectors(
        for requestedConfiguration: HexaKeyboardConfiguration
    ) -> [PeriodVector] {
        let configuration = requestedConfiguration.normalized()
        let limit = Swift.min(
            24,
            Swift.max(8, Int(ceil(sqrt(Double(configuration.period)))) + 4)
        )
        var vectors: [PeriodVector] = []

        for dq in -limit...limit {
            for dr in -limit...limit {
                if dq == 0, dr == 0 { continue }
                let step = dq * configuration.stepQ + dr * configuration.stepR
                if positiveModulo(step, modulus: configuration.period) != 0 { continue }
                let coordinate = AxialCoordinate(q: dq, r: dr)
                vectors.append(
                    PeriodVector(dq: dq, dr: dr, distance: HexGeometry.distance(coordinate))
                )
            }
        }

        vectors.sort(by: periodVectorPrecedes)

        var chosen: [PeriodVector] = []
        for vector in vectors {
            if chosen.isEmpty {
                chosen.append(vector)
                continue
            }

            let independent = chosen.allSatisfy {
                $0.dq * vector.dr - $0.dr * vector.dq != 0
            }
            let opposite = chosen.contains {
                $0.dq == -vector.dq && $0.dr == -vector.dr
            }
            if independent, !opposite {
                chosen.append(vector)
            }
            if chosen.count == 2 { break }
        }

        return chosen.isEmpty ? Array(vectors.prefix(2)) : chosen
    }

    private struct Candidate {
        let key: HexKey
        let score: Double
        let centerDistance: Double
    }

    private static func buildWindowSlots(
        configuration: HexaKeyboardConfiguration
    ) -> [HexWindowSlot] {
        let originColumn = (configuration.columns - 1) / 2
        let originRow = (configuration.rows - 1) / 2
        let origin = HexGeometry.oddQToAxial(column: originColumn, row: originRow)
        var slots: [HexWindowSlot] = []
        slots.reserveCapacity(configuration.columns * configuration.rows)

        for column in 0..<configuration.columns {
            for row in 0..<configuration.rows {
                let axial = HexGeometry.oddQToAxial(column: column, row: row)
                let coordinate = AxialCoordinate(
                    q: axial.q - origin.q,
                    r: axial.r - origin.r
                )
                slots.append(
                    HexWindowSlot(
                        column: column,
                        row: row,
                        key: makeKey(
                            coordinate: coordinate,
                            rotate: false,
                            configuration: configuration
                        )
                    )
                )
            }
        }

        return slots
    }

    private static func selectCells(
        slots: [HexWindowSlot],
        centerBounds: HexBounds,
        configuration: HexaKeyboardConfiguration
    ) -> (cells: [HexKey], stats: RotationStats) {
        if configuration.rotationDegrees == 0 {
            return (slots.map(\.key), RotationStats(generated: 0, omitted: 0))
        }

        let baseSet = Set(slots.map(\.coordinate))
        let center = centerBounds.center
        let radius = Double(configuration.radius)
        let range = Int(ceil(hypot(centerBounds.width, centerBounds.height) / radius * 1.35)) + 6
        var candidates: [Candidate] = []
        candidates.reserveCapacity((range * 2 + 1) * (range * 2 + 1))

        for q in -range...range {
            for r in -range...range {
                let key = makeKey(
                    coordinate: AxialCoordinate(q: q, r: r),
                    rotate: true,
                    configuration: configuration
                )
                candidates.append(
                    Candidate(
                        key: key,
                        score: HexGeometry.parallelogramScore(
                            for: key.center,
                            in: centerBounds,
                            acuteAngleDegrees: configuration.frameAcuteAngleDegrees
                        ),
                        centerDistance: HexGeometry.squaredDistance(key.center, center)
                    )
                )
            }
        }

        candidates.sort(by: candidatePrecedes)
        var cells = candidates
            .prefix(configuration.columns * configuration.rows)
            .map(\.key)
        cells.sort(by: visualCellPrecedes)

        let used = Set(cells.map(\.coordinate))
        return (
            cells,
            RotationStats(
                generated: cells.lazy.filter { !baseSet.contains($0.coordinate) }.count,
                omitted: slots.lazy.filter { !used.contains($0.coordinate) }.count
            )
        )
    }

    private static func makeKey(
        coordinate: AxialCoordinate,
        rotate: Bool,
        configuration: HexaKeyboardConfiguration
    ) -> HexKey {
        let step = PitchMapper.step(
            for: coordinate,
            stepQ: configuration.stepQ,
            stepR: configuration.stepR
        )
        let point = HexGeometry.point(for: coordinate, radius: Double(configuration.radius))
        let center = rotate
            ? HexGeometry.rotate(point, degrees: Double(configuration.rotationDegrees))
            : point
        return HexKey(
            coordinate: coordinate,
            step: step,
            pitchClass: positiveModulo(step, modulus: configuration.period),
            audioPitch: PitchMapper.pitch(forStep: step, edo: configuration.period),
            center: center
        )
    }

    private static func candidatePrecedes(_ first: Candidate, _ second: Candidate) -> Bool {
        if first.score != second.score { return first.score < second.score }
        if first.centerDistance != second.centerDistance {
            return first.centerDistance < second.centerDistance
        }
        if first.key.q != second.key.q { return first.key.q < second.key.q }
        return first.key.r < second.key.r
    }

    private static func visualCellPrecedes(_ first: HexKey, _ second: HexKey) -> Bool {
        if first.center.y != second.center.y { return first.center.y < second.center.y }
        return first.center.x < second.center.x
    }

    private static func periodVectorPrecedes(_ first: PeriodVector, _ second: PeriodVector) -> Bool {
        if first.distance != second.distance { return first.distance < second.distance }
        let firstManhattan = abs(first.dq) + abs(first.dr)
        let secondManhattan = abs(second.dq) + abs(second.dr)
        if firstManhattan != secondManhattan { return firstManhattan < secondManhattan }
        if first.dq != second.dq { return first.dq < second.dq }
        return first.dr < second.dr
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
