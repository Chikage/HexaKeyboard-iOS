import Foundation

public let c4MIDIPitch = 60
public let c4FrequencyHz = 261.6255653005986
public let midiKeyMinimum = 0
public let midiKeyMaximum = 127

public func positiveModulo(_ value: Int, modulus: Int) -> Int {
    precondition(modulus > 0, "Modulus must be positive")
    let remainder = value % modulus
    return remainder >= 0 ? remainder : remainder + modulus
}

public struct EDOPitch: Equatable, Sendable {
    public let step: Int
    public let midiPitch: Double
    public let midiKey: Int?
    public let cents: Double
    public let frequency: Double
    public let isPlayable: Bool

    public init(
        step: Int,
        midiPitch: Double,
        midiKey: Int?,
        cents: Double,
        frequency: Double,
        isPlayable: Bool
    ) {
        self.step = step
        self.midiPitch = midiPitch
        self.midiKey = midiKey
        self.cents = cents
        self.frequency = frequency
        self.isPlayable = isPlayable
    }
}

public enum PitchMapper {
    public static func step(
        for coordinate: AxialCoordinate,
        stepQ: Int,
        stepR: Int
    ) -> Int {
        coordinate.q * stepQ + coordinate.r * stepR
    }

    public static func pitch(forStep step: Int, edo: Int) -> EDOPitch {
        guard edo > 0 else {
            return EDOPitch(
                step: step,
                midiPitch: .nan,
                midiKey: nil,
                cents: .nan,
                frequency: .nan,
                isPlayable: false
            )
        }

        let midiPitch = Double(c4MIDIPitch) + Double(step * 12) / Double(edo)
        let frequency = c4FrequencyHz * pow(2, Double(step) / Double(edo))
        let roundedMIDIKey = javaScriptRoundToInt(midiPitch)
        let cents = roundedMIDIKey.map { (midiPitch - Double($0)) * 100 } ?? .nan
        let isPlayable = midiPitch.isFinite
            && frequency.isFinite
            && roundedMIDIKey.map { midiKeyMinimum...midiKeyMaximum ~= $0 } == true

        return EDOPitch(
            step: step,
            midiPitch: midiPitch,
            midiKey: roundedMIDIKey,
            cents: cents,
            frequency: frequency,
            isPlayable: isPlayable
        )
    }

    public static func pitch(
        for coordinate: AxialCoordinate,
        edo: Int,
        stepQ: Int,
        stepR: Int
    ) -> EDOPitch {
        pitch(
            forStep: step(for: coordinate, stepQ: stepQ, stepR: stepR),
            edo: edo
        )
    }

    public static func pitchWheelValue(cents: Double, rangeSemitones: Double = 1) -> Int {
        guard cents.isFinite, rangeSemitones.isFinite, rangeSemitones > 0 else {
            return 8192
        }

        let rawValue = 8192 + (cents / (rangeSemitones * 100)) * 8192
        if rawValue <= 0 { return 0 }
        if rawValue >= 16383 { return 16383 }
        return Int(floor(rawValue + 0.5))
    }

    private static func javaScriptRoundToInt(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        let rounded = floor(value + 0.5)
        guard rounded >= Double(Int.min), rounded < Double(Int.max) else { return nil }
        return Int(rounded)
    }
}
