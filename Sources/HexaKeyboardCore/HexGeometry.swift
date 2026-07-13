import Foundation

public struct AxialCoordinate: Hashable, Sendable {
    public let q: Int
    public let r: Int

    public var s: Int { -q - r }

    public init(q: Int, r: Int) {
        self.q = q
        self.r = r
    }

    public static let origin = AxialCoordinate(q: 0, r: 0)
}

public struct HexPoint: Hashable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct HexBounds: Hashable, Sendable {
    public let minX: Double
    public let maxX: Double
    public let minY: Double
    public let maxY: Double

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var center: HexPoint {
        HexPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
    }

    public init(minX: Double, maxX: Double, minY: Double, maxY: Double) {
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
    }

    public init(points: some Sequence<HexPoint>, radius: Double = 0) {
        var minX = Double.infinity
        var maxX = -Double.infinity
        var minY = Double.infinity
        var maxY = -Double.infinity

        for point in points {
            minX = Swift.min(minX, point.x - radius)
            maxX = Swift.max(maxX, point.x + radius)
            minY = Swift.min(minY, point.y - radius)
            maxY = Swift.max(maxY, point.y + radius)
        }

        self.init(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }

    public static func merging(_ bounds: HexBounds...) -> HexBounds {
        precondition(!bounds.isEmpty, "At least one set of bounds is required")
        return bounds.dropFirst().reduce(bounds[0]) { result, next in
            HexBounds(
                minX: Swift.min(result.minX, next.minX),
                maxX: Swift.max(result.maxX, next.maxX),
                minY: Swift.min(result.minY, next.minY),
                maxY: Swift.max(result.maxY, next.maxY)
            )
        }
    }
}

public struct HexParallelogram: Hashable, Sendable {
    /// Points are ordered top-left, top-right, bottom-right, bottom-left.
    public let points: [HexPoint]
    public let bounds: HexBounds
    public let horizontalShift: Double

    public var topLeft: HexPoint { points[0] }
    public var topRight: HexPoint { points[1] }
    public var bottomRight: HexPoint { points[2] }
    public var bottomLeft: HexPoint { points[3] }

    public init(points: [HexPoint], bounds: HexBounds, horizontalShift: Double) {
        precondition(points.count == 4, "A parallelogram must have four corners")
        self.points = points
        self.bounds = bounds
        self.horizontalShift = horizontalShift
    }
}

public enum HexGeometry {
    public static func oddQToAxial(column: Int, row: Int) -> AxialCoordinate {
        AxialCoordinate(
            q: column,
            r: row - (column - (column & 1)) / 2
        )
    }

    public static func distance(_ coordinate: AxialCoordinate) -> Int {
        (abs(coordinate.q) + abs(coordinate.r) + abs(coordinate.q + coordinate.r)) / 2
    }

    public static func distance(from start: AxialCoordinate, to end: AxialCoordinate) -> Int {
        distance(AxialCoordinate(q: end.q - start.q, r: end.r - start.r))
    }

    public static func point(for coordinate: AxialCoordinate, radius: Double) -> HexPoint {
        HexPoint(
            x: radius * 1.5 * Double(coordinate.q),
            y: radius * sqrt(3) * (Double(coordinate.r) + Double(coordinate.q) / 2)
        )
    }

    public static func rotate(_ point: HexPoint, degrees: Double) -> HexPoint {
        let angle = Double.pi / 180 * degrees
        let cosine = cos(angle)
        let sine = sin(angle)
        return HexPoint(
            x: point.x * cosine - point.y * sine,
            y: point.x * sine + point.y * cosine
        )
    }

    public static func squaredDistance(_ first: HexPoint, _ second: HexPoint) -> Double {
        pow(first.x - second.x, 2) + pow(first.y - second.y, 2)
    }

    public static func parallelogram(
        around bounds: HexBounds,
        acuteAngleDegrees: Double = 72
    ) -> HexParallelogram {
        let shift = bounds.height / tan(Double.pi / 180 * acuteAngleDegrees)
        let halfShift = shift / 2
        let points = [
            HexPoint(x: bounds.minX - halfShift, y: bounds.minY),
            HexPoint(x: bounds.maxX - halfShift, y: bounds.minY),
            HexPoint(x: bounds.maxX + halfShift, y: bounds.maxY),
            HexPoint(x: bounds.minX + halfShift, y: bounds.maxY),
        ]

        return HexParallelogram(
            points: points,
            bounds: HexBounds(points: points),
            horizontalShift: shift
        )
    }

    public static func parallelogramScore(
        for point: HexPoint,
        in bounds: HexBounds,
        acuteAngleDegrees: Double = 72
    ) -> Double {
        let geometry = parallelogram(around: bounds, acuteAngleDegrees: acuteAngleDegrees)
        let width = Swift.max(1, bounds.width)
        let height = Swift.max(1, bounds.height)
        let v = (point.y - geometry.topLeft.y) / height
        let u = (point.x - geometry.topLeft.x - v * geometry.horizontalShift) / width

        return Swift.max(
            abs(u - 0.5) / 0.5,
            abs(v - 0.5) / 0.5
        )
    }
}
