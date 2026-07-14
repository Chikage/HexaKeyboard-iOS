import Foundation

public struct TouchForce: Equatable, Sendable {
    public let normalized: Double
    public let velocity: Int
    public let expression: Int
    public let usesHardwarePressure: Bool

    public init(
        normalized: Double,
        velocity: Int,
        expression: Int,
        usesHardwarePressure: Bool
    ) {
        self.normalized = normalized
        self.velocity = velocity
        self.expression = expression
        self.usesHardwarePressure = usesHardwarePressure
    }

    public static let fixed = TouchForce(
        normalized: 0.76,
        velocity: 104,
        expression: 127,
        usesHardwarePressure: false
    )
}

public enum HexTouchHitTester {
    public static func key(
        at point: HexPoint,
        in layout: HexaKeyboardLayout,
        previousCoordinate: AxialCoordinate? = nil,
        sensitivity: Double = 1.20
    ) -> HexKey? {
        guard !layout.cells.isEmpty else { return nil }

        let safeSensitivity = sensitivity.clamped(to: 1.0...1.5)
        let radius = Double(layout.configuration.radius)
        guard let nearest = layout.cells.min(by: {
            squaredDistance(point, $0.center) < squaredDistance(point, $1.center)
        }) else { return nil }
        let nearestDistance = distance(point, nearest.center)

        if let previousCoordinate, let previous = layout.cell(at: previousCoordinate) {
            let previousDistance = distance(point, previous.center)
            let retentionRadius = radius * (safeSensitivity + 0.12)
            if previousDistance <= retentionRadius {
                if nearest.coordinate == previous.coordinate {
                    return previous
                }
                let switchMargin = radius * 0.12
                if nearestDistance + switchMargin >= previousDistance {
                    return previous
                }
            }
        }

        return nearestDistance <= radius * safeSensitivity ? nearest : nil
    }

    private static func distance(_ first: HexPoint, _ second: HexPoint) -> Double {
        hypot(first.x - second.x, first.y - second.y)
    }

    private static func squaredDistance(_ first: HexPoint, _ second: HexPoint) -> Double {
        let dx = first.x - second.x
        let dy = first.y - second.y
        return dx * dx + dy * dy
    }
}

public final class PseudoPressureTracker: @unchecked Sendable {
    private var startTimeMilliseconds: Int64?
    private var lastTimeMilliseconds: Int64?
    private var lastPoint: HexPoint?
    private var filteredForce: Double?
    private var minimumPressure = Double.infinity
    private var maximumPressure = -Double.infinity
    private var hardwarePressureObserved = false

    public init() {}

    public func sample(
        rawPressure: Double,
        uptimeMilliseconds: Int64,
        point: HexPoint,
        keyCenter: HexPoint,
        keyRadius: Double,
        hardwarePressureHint: Bool = false
    ) -> TouchForce {
        let safeRadius = max(1, keyRadius)
        let startedAt: Int64
        if let startTimeMilliseconds {
            startedAt = startTimeMilliseconds
        } else {
            startTimeMilliseconds = uptimeMilliseconds
            startedAt = uptimeMilliseconds
        }
        let previousTime = lastTimeMilliseconds
        let previousPoint = lastPoint
        let elapsedMilliseconds = max(0, uptimeMilliseconds - startedAt)
        let deltaMilliseconds = previousTime.map { max(1, uptimeMilliseconds - $0) } ?? 0

        let centerDistance = hypot(point.x - keyCenter.x, point.y - keyCenter.y)
        let centerProximity = (1 - centerDistance / (safeRadius * 1.15)).clamped(to: 0...1)
        let holdProgress = (Double(elapsedMilliseconds) / 320).clamped(to: 0...1)
        let speedInRadiiPerSecond: Double
        if let previousPoint, deltaMilliseconds > 0 {
            speedInRadiiPerSecond = hypot(
                point.x - previousPoint.x,
                point.y - previousPoint.y
            ) / safeRadius / (Double(deltaMilliseconds) / 1_000)
        } else {
            speedInRadiiPerSecond = 0
        }
        let stability = (1 - speedInRadiiPerSecond / 9).clamped(to: 0...1)
        let pseudoForce = (
            0.34
                + 0.30 * centerProximity
                + 0.20 * sqrt(holdProgress)
                + 0.16 * stability
        ).clamped(to: 0...1)

        let pressure = (rawPressure.isFinite ? rawPressure : 1).clamped(to: 0...1.5)
        minimumPressure = min(minimumPressure, pressure)
        maximumPressure = max(maximumPressure, pressure)
        if hardwarePressureHint
            || (0.02...0.98).contains(pressure)
            || maximumPressure - minimumPressure >= 0.05 {
            hardwarePressureObserved = true
        }

        let hardwareForce = pow(((pressure - 0.03) / 0.82).clamped(to: 0...1), 0.72)
        let targetForce = hardwarePressureObserved
            ? 0.82 * hardwareForce + 0.18 * pseudoForce
            : pseudoForce
        let smoothing: Double
        if filteredForce == nil || deltaMilliseconds <= 0 {
            smoothing = 1
        } else {
            smoothing = (1 - exp(-Double(deltaMilliseconds) / 42)).clamped(to: 0.12...0.78)
        }
        let force = (filteredForce.map { $0 + (targetForce - $0) * smoothing } ?? targetForce)
            .clamped(to: 0...1)

        filteredForce = force
        lastTimeMilliseconds = uptimeMilliseconds
        lastPoint = point

        return TouchForce(
            normalized: force,
            velocity: Int((44 + 83 * pow(force, 0.72)).rounded()).clamped(to: 44...127),
            expression: Int((70 + 57 * pow(force, 0.85)).rounded()).clamped(to: 70...127),
            usesHardwarePressure: hardwarePressureObserved
        )
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
