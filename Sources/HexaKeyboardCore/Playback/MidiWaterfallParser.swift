import Foundation

/// Parsed, time-normalized score data ready for audio scheduling and keyboard visualization.
public struct PlaybackScore: Equatable, Sendable {
    public let title: String
    public let format: String
    public let notes: [PlaybackNote]
    public let duration: Double
    public let ticksPerQuarter: Int
    public let tempos: [TempoEvent]
    public let meters: [MeterEvent]
    public let tempoMap: [TempoPoint]
    public let rawEvents: [PlaybackNoteEvent]
    public let longNotes: [PlaybackNote]

    public init(
        title: String,
        format: String,
        notes: [PlaybackNote],
        duration: Double,
        ticksPerQuarter: Int = 480,
        tempos: [TempoEvent] = [],
        meters: [MeterEvent] = [],
        tempoMap: [TempoPoint] = [],
        rawEvents: [PlaybackNoteEvent] = [],
        longNotes: [PlaybackNote] = []
    ) {
        self.title = title
        self.format = format
        self.notes = notes
        self.duration = duration
        self.ticksPerQuarter = ticksPerQuarter
        self.tempos = tempos
        self.meters = meters
        self.tempoMap = tempoMap
        self.rawEvents = rawEvents
        self.longNotes = longNotes
    }
}

public struct TempoEvent: Equatable, Sendable {
    public let tick: Int64
    public let usPerQuarter: Double

    public init(tick: Int64, usPerQuarter: Double) {
        self.tick = tick
        self.usPerQuarter = usPerQuarter
    }
}

public struct MeterEvent: Equatable, Sendable {
    public let tick: Int64
    public let numerator: Int
    public let denominator: Int

    public init(tick: Int64, numerator: Int, denominator: Int) {
        self.tick = tick
        self.numerator = numerator
        self.denominator = denominator
    }
}

public struct TempoPoint: Equatable, Sendable {
    public let tick: Int64
    public let second: Double
    public let usPerQuarter: Double

    public init(tick: Int64, second: Double, usPerQuarter: Double) {
        self.tick = tick
        self.second = second
        self.usPerQuarter = usPerQuarter
    }
}

public struct PlaybackNoteEvent: Equatable, Sendable {
    public let tick: Int64
    public let pitch: Int
    public let pitchFloat: Double?
    public let midiPitch: Int
    public let cents: Double
    public let velocity: Int
    public let track: Int
    public let channel: Int
    public let program: Int
    public let bankMsb: Int
    public let bankLsb: Int
    public let order: Int64

    public init(
        tick: Int64,
        pitch: Int,
        pitchFloat: Double?,
        midiPitch: Int,
        cents: Double,
        velocity: Int,
        track: Int,
        channel: Int,
        program: Int,
        bankMsb: Int,
        bankLsb: Int,
        order: Int64
    ) {
        self.tick = tick
        self.pitch = pitch
        self.pitchFloat = pitchFloat
        self.midiPitch = midiPitch
        self.cents = cents
        self.velocity = velocity
        self.track = track
        self.channel = channel
        self.program = program
        self.bankMsb = bankMsb
        self.bankLsb = bankLsb
        self.order = order
    }
}

/// A paired note-on/note-off event.
///
/// `audioPitch` is the exact absolute MIDI pitch and is never snapped or range-filtered.
/// `midiPitch` remains the source event's integer key. `cents` is normalized relative to the
/// nearest integer pitch, while track/channel/program/bank data is captured at note-on.
public struct PlaybackNote: Equatable, Sendable {
    public let startTick: Int64
    public let endTick: Int64
    public let start: Double
    public let end: Double
    public let audioPitch: Double
    public let midiPitch: Int
    public let cents: Double
    public let velocity: Int
    public let channel: Int
    public let track: Int
    public let program: Int
    public let bankMsb: Int
    public let bankLsb: Int

    public init(
        startTick: Int64,
        endTick: Int64,
        start: Double,
        end: Double,
        audioPitch: Double,
        midiPitch: Int,
        cents: Double,
        velocity: Int,
        channel: Int,
        track: Int,
        program: Int,
        bankMsb: Int,
        bankLsb: Int
    ) {
        self.startTick = startTick
        self.endTick = endTick
        self.start = start
        self.end = end
        self.audioPitch = audioPitch
        self.midiPitch = midiPitch
        self.cents = cents
        self.velocity = velocity
        self.channel = channel
        self.track = track
        self.program = program
        self.bankMsb = bankMsb
        self.bankLsb = bankLsb
    }
}

public struct MidiWaterfallParserError: Error, Equatable, Sendable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum MidiWaterfallParser {
    private static let midxMetaType = 0x7F
    private static let midxPitchedOffsetPayloadLength = 7
    private static let midxExperimentalManufacturerID = 0x7D
    private static let midxPitchedOffsetRecordType = 0x03
    private static let offsetCentRange = 64.0
    private static let offsetMagnitudeSteps = 32_768.0
    private static let defaultTempoUsPerQuarter = 500_000.0
    private static let defaultPitchBendRangeSemitones = 2
    private static let pitchBendCenter = 8_192
    private static let pitchBendMaximum = 16_383
    private static let midiControlBankMSB = 0
    private static let midiControlDataEntryMSB = 6
    private static let midiControlBankLSB = 32
    private static let midiControlDataEntryLSB = 38
    private static let midiControlSustain = 64
    private static let midiControlNRPNLSB = 98
    private static let midiControlNRPNMSB = 99
    private static let midiControlRPNLSB = 100
    private static let midiControlRPNMSB = 101
    private static let noteRenderLookbackSeconds = 8.0

    public static func detectAndParse(
        bytes: Data,
        fileName: String = "selected-file"
    ) throws -> PlaybackScore {
        try detectAndParse(bytes: [UInt8](bytes), fileName: fileName)
    }

    public static func detectAndParse(
        bytes: [UInt8],
        fileName: String = "selected-file"
    ) throws -> PlaybackScore {
        let head = try ByteReader(bytes, source: fileName).readASCII(min(8, bytes.count))
        if head.hasPrefix("SMF2CLIP") {
            return try parseMidi2Clip(bytes: bytes, fileName: fileName)
        }
        return try parseSmfMidx(bytes: bytes, fileName: fileName)
    }

    public static func normalizeTempos(_ tempos: [TempoEvent]) -> [TempoEvent] {
        var byTick: [Int64: TempoEvent] = [:]
        for tempo in tempos where tempo.usPerQuarter > 0 {
            byTick[tempo.tick] = tempo
        }
        var output = byTick.keys.sorted().compactMap { byTick[$0] }
        if output.isEmpty || output[0].tick != 0 {
            output.insert(TempoEvent(tick: 0, usPerQuarter: defaultTempoUsPerQuarter), at: 0)
        }
        return output
    }

    public static func normalizeMeters(_ meters: [MeterEvent]) -> [MeterEvent] {
        var byTick: [Int64: MeterEvent] = [:]
        for meter in meters {
            let tick = max(0, meter.tick)
            byTick[tick] = MeterEvent(
                tick: tick,
                numerator: max(1, meter.numerator),
                denominator: max(1, meter.denominator)
            )
        }
        var output = byTick.keys.sorted().compactMap { byTick[$0] }
        if output.isEmpty || output[0].tick != 0 {
            output.insert(MeterEvent(tick: 0, numerator: 4, denominator: 4), at: 0)
        }
        return output
    }

    public static func makeTempoMap(
        tempos: [TempoEvent],
        ticksPerQuarter: Int
    ) -> [TempoPoint] {
        let normalized = normalizeTempos(tempos)
        var map: [TempoPoint] = []
        map.reserveCapacity(normalized.count)
        var currentSecond = 0.0
        var previousTick: Int64 = 0
        var previousMicroseconds = defaultTempoUsPerQuarter
        for tempo in normalized {
            currentSecond += Double(tempo.tick - previousTick)
                * previousMicroseconds
                / 1_000_000.0
                / Double(ticksPerQuarter)
            map.append(
                TempoPoint(
                    tick: tempo.tick,
                    second: currentSecond,
                    usPerQuarter: tempo.usPerQuarter
                )
            )
            previousTick = tempo.tick
            previousMicroseconds = tempo.usPerQuarter
        }
        return map
    }

    public static func tickToSeconds(
        tick: Int64,
        tempoMap: [TempoPoint],
        ticksPerQuarter: Int
    ) -> Double {
        precondition(!tempoMap.isEmpty, "Tempo map must not be empty")
        var low = 0
        var high = tempoMap.count - 1
        while low <= high {
            let middle = (low + high) >> 1
            if tempoMap[middle].tick <= tick {
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        let item = tempoMap[max(0, high)]
        return item.second
            + Double(tick - item.tick) * item.usPerQuarter
            / 1_000_000.0
            / Double(ticksPerQuarter)
    }

    public static func secondsToTick(
        second: Double,
        tempoMap: [TempoPoint],
        ticksPerQuarter: Int
    ) -> Double {
        precondition(!tempoMap.isEmpty, "Tempo map must not be empty")
        let clampedSecond = second < 0 ? 0 : second
        var low = 0
        var high = tempoMap.count - 1
        while low <= high {
            let middle = (low + high) >> 1
            if tempoMap[middle].second <= clampedSecond {
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        let item = tempoMap[max(0, high)]
        return Double(item.tick)
            + (clampedSecond - item.second) * 1_000_000.0
            * Double(ticksPerQuarter)
            / item.usPerQuarter
    }

    public static func measureTicks(_ meter: MeterEvent, ticksPerQuarter: Int) -> Double {
        let ticks = Double(ticksPerQuarter) * 4.0
            * Double(meter.numerator)
            / Double(meter.denominator)
        return ticks < 1 ? 1 : ticks
    }

    private static func parseSmfMidx(
        bytes: [UInt8],
        fileName: String
    ) throws -> PlaybackScore {
        let reader = ByteReader(bytes, source: fileName)
        guard try reader.readASCII(4) == "MThd" else {
            throw MidiWaterfallParserError("Not a MIDI/MIDX file: missing MThd")
        }
        let headerLength = Int(try reader.readU32())
        let header = ByteReader(try reader.read(headerLength), source: "MThd")
        let midiFormat = try header.readU16()
        let trackCount = try header.readU16()
        let division = try header.readU16()
        guard division & 0x8000 == 0 else {
            throw MidiWaterfallParserError("SMPTE time division is not supported")
        }
        guard midiFormat == 0 || midiFormat == 1 else {
            throw MidiWaterfallParserError("Unsupported MIDI format \(midiFormat)")
        }

        var tempos = [TempoEvent(tick: 0, usPerQuarter: defaultTempoUsPerQuarter)]
        var meters = [MeterEvent(tick: 0, numerator: 4, denominator: 4)]
        var rawEvents: [PlaybackNoteEvent] = []
        var order: Int64 = 0

        for track in 0..<trackCount {
            if reader.remaining <= 0 { break }
            let chunkType = try reader.readASCII(4)
            let chunkLength = Int(try reader.readU32())
            let chunk = try reader.read(chunkLength)
            if chunkType != "MTrk" { continue }

            let trackReader = ByteReader(chunk, source: "MTrk[\(track)]")
            var tick: Int64 = 0
            var runningStatus: Int?
            var programs: [Int: Int] = [:]
            var bankMSB: [Int: Int] = [:]
            var bankLSB: [Int: Int] = [:]
            var inlineOffsets: [InlineOffset] = []
            var pitchBendValues = Array(repeating: pitchBendCenter, count: 16)
            var pitchBendRangeSemitones = Array(
                repeating: defaultPitchBendRangeSemitones,
                count: 16
            )
            var pitchBendRangeCents = Array(repeating: 0, count: 16)
            var selectedRPNMSB = Array(repeating: 127, count: 16)
            var selectedRPNLSB = Array(repeating: 127, count: 16)
            var sustainDown = Array(repeating: false, count: 16)
            var sustainedNoteOffs = Array(repeating: [PlaybackNoteEvent](), count: 16)

            func releaseSustainedNotes(channel: Int, releaseTick: Int64) {
                let deferredEvents = sustainedNoteOffs[channel]
                sustainedNoteOffs[channel].removeAll(keepingCapacity: true)
                for deferred in deferredEvents {
                    rawEvents.append(copyEvent(deferred, tick: releaseTick, order: order))
                    order += 1
                }
            }

            while trackReader.remaining > 0 {
                tick += Int64(try trackReader.readVLQ())
                let statusOrData = try trackReader.readByte()

                if statusOrData == 0xFF {
                    let metaType = try trackReader.readByte()
                    let payloadLength = try trackReader.readVLQ()
                    let payload = try trackReader.read(payloadLength)
                    if metaType == 0x2F { break }

                    if metaType == 0x51, payloadLength == 3 {
                        let microseconds = Double(
                            Int(payload[0]) << 16
                                | Int(payload[1]) << 8
                                | Int(payload[2])
                        )
                        tempos.append(TempoEvent(tick: tick, usPerQuarter: microseconds))
                    } else if metaType == 0x58, payloadLength >= 2 {
                        meters.append(
                            MeterEvent(
                                tick: tick,
                                numerator: Int(payload[0]),
                                denominator: kotlinRoundToInt(pow(2, Double(payload[1])))
                            )
                        )
                    } else if metaType == midxMetaType,
                              payloadLength == midxPitchedOffsetPayloadLength {
                        if let decoded = decodePitchedOffsetPayload(payload) {
                            if let last = inlineOffsets.last, last.tick != tick {
                                inlineOffsets.removeAll(keepingCapacity: true)
                            }
                            inlineOffsets.append(
                                InlineOffset(tick: tick, pitch: decoded.pitch, cents: decoded.cents)
                            )
                        } else {
                            inlineOffsets.removeAll(keepingCapacity: true)
                        }
                    } else {
                        inlineOffsets.removeAll(keepingCapacity: true)
                    }
                    continue
                }

                if statusOrData == 0xF0 || statusOrData == 0xF7 {
                    _ = try trackReader.read(try trackReader.readVLQ())
                    runningStatus = nil
                    inlineOffsets.removeAll(keepingCapacity: true)
                    continue
                }

                if statusOrData >= 0xF0 {
                    try skipSystemEvent(reader: trackReader, status: statusOrData)
                    runningStatus = nil
                    inlineOffsets.removeAll(keepingCapacity: true)
                    continue
                }

                let status: Int
                let firstData: Int?
                if statusOrData & 0x80 != 0 {
                    status = statusOrData
                    runningStatus = status
                    firstData = nil
                } else {
                    guard let runningStatus else {
                        throw MidiWaterfallParserError("Running status without prior status")
                    }
                    status = runningStatus
                    firstData = statusOrData
                }

                let eventType = status & 0xF0
                let channel = status & 0x0F
                if eventType == 0xC0 || eventType == 0xD0 {
                    let onlyData = try firstData ?? trackReader.readByte()
                    if eventType == 0xC0 {
                        programs[channel] = onlyData
                    }
                    inlineOffsets.removeAll(keepingCapacity: true)
                    continue
                }

                let data1 = try firstData ?? trackReader.readByte()
                let data2 = try trackReader.readByte()
                if eventType == 0xB0 {
                    switch data1 {
                    case midiControlBankMSB:
                        bankMSB[channel] = data2
                    case midiControlBankLSB:
                        bankLSB[channel] = data2
                    case midiControlRPNMSB:
                        selectedRPNMSB[channel] = data2
                    case midiControlRPNLSB:
                        selectedRPNLSB[channel] = data2
                    case midiControlNRPNMSB, midiControlNRPNLSB:
                        selectedRPNMSB[channel] = 127
                        selectedRPNLSB[channel] = 127
                    case midiControlDataEntryMSB:
                        if selectedRPNMSB[channel] == 0, selectedRPNLSB[channel] == 0 {
                            pitchBendRangeSemitones[channel] = data2
                        }
                    case midiControlDataEntryLSB:
                        if selectedRPNMSB[channel] == 0, selectedRPNLSB[channel] == 0 {
                            pitchBendRangeCents[channel] = data2
                        }
                    case midiControlSustain:
                        let wasDown = sustainDown[channel]
                        sustainDown[channel] = data2 >= 64
                        if wasDown, !sustainDown[channel] {
                            releaseSustainedNotes(channel: channel, releaseTick: tick)
                        }
                    default:
                        break
                    }
                }
                if eventType == 0xE0 {
                    pitchBendValues[channel] = min(
                        pitchBendMaximum,
                        max(0, data2 << 7 | data1)
                    )
                }
                if eventType == 0x80 || eventType == 0x90 {
                    let velocity = eventType == 0x90 ? data2 : 0
                    var effectivePitch = data1
                    var noteCents = 0.0
                    if velocity > 0 {
                        if let last = inlineOffsets.last, last.tick != tick {
                            inlineOffsets.removeAll(keepingCapacity: true)
                        }
                        if let inline = popInline(
                            inlineOffsets: &inlineOffsets,
                            midiPitch: data1,
                            tick: tick
                        ) {
                            effectivePitch = inline.pitch
                            noteCents = inline.cents
                        }
                        noteCents += pitchBendCents(
                            value: pitchBendValues[channel],
                            rangeSemitones: Double(pitchBendRangeSemitones[channel])
                                + Double(pitchBendRangeCents[channel]) / 100.0
                        )
                    } else {
                        inlineOffsets.removeAll(keepingCapacity: true)
                    }

                    let noteEvent = PlaybackNoteEvent(
                        tick: tick,
                        pitch: effectivePitch,
                        pitchFloat: nil,
                        midiPitch: data1,
                        cents: noteCents,
                        velocity: velocity,
                        track: track,
                        channel: channel,
                        program: programs[channel] ?? 0,
                        bankMsb: bankMSB[channel] ?? 0,
                        bankLsb: bankLSB[channel] ?? 0,
                        order: order
                    )
                    if velocity == 0, sustainDown[channel] {
                        sustainedNoteOffs[channel].append(noteEvent)
                    } else {
                        rawEvents.append(noteEvent)
                        order += 1
                    }
                } else {
                    inlineOffsets.removeAll(keepingCapacity: true)
                }
            }

            for channel in sustainedNoteOffs.indices {
                releaseSustainedNotes(channel: channel, releaseTick: tick)
            }
        }

        return try finalizeParsed(
            title: fileName,
            format: "MIDX",
            ticksPerQuarter: division,
            tempos: tempos,
            meters: meters,
            rawEvents: rawEvents
        )
    }

    private static func parseMidi2Clip(
        bytes: [UInt8],
        fileName: String
    ) throws -> PlaybackScore {
        let reader = ByteReader(bytes, source: fileName)
        guard try reader.readASCII(8) == "SMF2CLIP" else {
            throw MidiWaterfallParserError(
                "Not a MIDI 2.0 Clip file: missing SMF2CLIP"
            )
        }
        var ticksPerQuarter = 480
        var tick: Int64 = 0
        var tempos = [TempoEvent(tick: 0, usPerQuarter: defaultTempoUsPerQuarter)]
        let meters = [MeterEvent(tick: 0, numerator: 4, denominator: 4)]
        var rawEvents: [PlaybackNoteEvent] = []
        var order: Int64 = 0
        var programs: [String: Int] = [:]
        var bankMSB: [String: Int] = [:]
        var bankLSB: [String: Int] = [:]
        var sustainDown: [String: Bool] = [:]
        var sustainedNoteOffs: [String: [PlaybackNoteEvent]] = [:]
        var sustainedNoteOffKeyOrder: [String] = []

        func releaseSustainedNotes(key: String, releaseTick: Int64) {
            guard let deferredEvents = sustainedNoteOffs.removeValue(forKey: key) else {
                return
            }
            sustainedNoteOffKeyOrder.removeAll { $0 == key }
            for deferred in deferredEvents {
                rawEvents.append(copyEvent(deferred, tick: releaseTick, order: order))
                order += 1
            }
        }

        func deferSustainedNoteOff(_ event: PlaybackNoteEvent, key: String) {
            if sustainedNoteOffs[key] == nil {
                sustainedNoteOffKeyOrder.append(key)
            }
            sustainedNoteOffs[key, default: []].append(event)
        }

        while reader.remaining > 0 {
            let first = try reader.peekByte()
            let messageType = first >> 4
            let group = first & 0x0F
            let packet = try reader.read(umpPacketSize(messageType))

            if messageType == 0x0 {
                let utilityStatus = Int(packet[1] >> 4) & 0x0F
                if utilityStatus == 0x3 {
                    let declaredTicks = Int(packet[2]) << 8 | Int(packet[3])
                    ticksPerQuarter = max(
                        1,
                        declaredTicks == 0 ? ticksPerQuarter : declaredTicks
                    )
                } else if utilityStatus == 0x4 {
                    let delta = (Int(packet[1]) & 0x0F) << 16
                        | Int(packet[2]) << 8
                        | Int(packet[3])
                    tick += Int64(delta)
                }
                continue
            }

            if messageType == 0xD, packet.count >= 16 {
                if packet[1] == 0x10, packet[2] == 0, packet[3] == 0 {
                    let tenNanoseconds = readU32(from: packet, offset: 4)
                    if tenNanoseconds > 0 {
                        tempos.append(
                            TempoEvent(
                                tick: tick,
                                usPerQuarter: Double(tenNanoseconds) / 100.0
                            )
                        )
                    }
                }
                continue
            }

            if messageType != 0x4 || packet.count < 8 { continue }
            let statusByte = Int(packet[1])
            let eventType = statusByte & 0xF0
            let channel = statusByte & 0x0F
            let key = "\(group):\(channel)"
            let note = Int(packet[2]) & 0x7F
            let attributeType = Int(packet[3])
            let velocity16 = Int(packet[4]) << 8 | Int(packet[5])
            let attribute = Int(packet[6]) << 8 | Int(packet[7])

            if eventType == 0xB0 {
                let controller = Int(packet[2]) & 0x7F
                let controllerValue = scaleDownU32To7(readU32(from: packet, offset: 4))
                if controller == 0 {
                    bankMSB[key] = controllerValue
                } else if controller == 32 {
                    bankLSB[key] = controllerValue
                } else if controller == midiControlSustain {
                    let wasDown = sustainDown[key] == true
                    sustainDown[key] = controllerValue >= 64
                    if wasDown, sustainDown[key] != true {
                        releaseSustainedNotes(key: key, releaseTick: tick)
                    }
                }
                continue
            }

            if eventType == 0xC0 {
                programs[key] = Int(packet[4]) & 0x7F
                if packet[3] & 0x01 != 0 {
                    bankMSB[key] = Int(packet[6]) & 0x7F
                    bankLSB[key] = Int(packet[7]) & 0x7F
                }
                continue
            }

            if eventType == 0x90 {
                let pitchFloat = attributeType == 0x03
                    ? Double(attribute) / 512.0
                    : Double(note)
                let velocity = velocity16 > 0
                    ? max(1, kotlinRoundToInt(Double(velocity16) / 65_535.0 * 127.0))
                    : 0
                let flooredPitch = floor(pitchFloat)
                let noteEvent = PlaybackNoteEvent(
                    tick: tick,
                    pitch: Int(flooredPitch),
                    pitchFloat: pitchFloat,
                    midiPitch: note,
                    cents: (pitchFloat - flooredPitch) * 100.0,
                    velocity: velocity,
                    track: group,
                    channel: channel,
                    program: programs[key] ?? 0,
                    bankMsb: bankMSB[key] ?? 0,
                    bankLsb: bankLSB[key] ?? 0,
                    order: order
                )
                if velocity == 0, sustainDown[key] == true {
                    deferSustainedNoteOff(noteEvent, key: key)
                } else {
                    rawEvents.append(noteEvent)
                    order += 1
                }
            } else if eventType == 0x80 {
                let noteEvent = PlaybackNoteEvent(
                    tick: tick,
                    pitch: note,
                    pitchFloat: Double(note),
                    midiPitch: note,
                    cents: 0,
                    velocity: 0,
                    track: group,
                    channel: channel,
                    program: programs[key] ?? 0,
                    bankMsb: bankMSB[key] ?? 0,
                    bankLsb: bankLSB[key] ?? 0,
                    order: order
                )
                if sustainDown[key] == true {
                    deferSustainedNoteOff(noteEvent, key: key)
                } else {
                    rawEvents.append(noteEvent)
                    order += 1
                }
            }
        }

        for key in Array(sustainedNoteOffKeyOrder) {
            releaseSustainedNotes(key: key, releaseTick: tick)
        }
        return try finalizeParsed(
            title: fileName,
            format: "MIDI 2.0 Clip",
            ticksPerQuarter: ticksPerQuarter,
            tempos: tempos,
            meters: meters,
            rawEvents: rawEvents
        )
    }

    private static func finalizeParsed(
        title: String,
        format: String,
        ticksPerQuarter: Int,
        tempos: [TempoEvent],
        meters: [MeterEvent],
        rawEvents: [PlaybackNoteEvent]
    ) throws -> PlaybackScore {
        guard !rawEvents.isEmpty else {
            throw MidiWaterfallParserError("No note events found")
        }
        let tempoMap = makeTempoMap(tempos: tempos, ticksPerQuarter: ticksPerQuarter)
        let normalizedMeters = normalizeMeters(meters)
        let notes = pairNotes(
            rawEvents: rawEvents,
            tempoMap: tempoMap,
            ticksPerQuarter: ticksPerQuarter
        )
        return PlaybackScore(
            title: title,
            format: format,
            notes: notes,
            duration: notes.map(\.end).max() ?? 0,
            ticksPerQuarter: ticksPerQuarter,
            tempos: normalizeTempos(tempos),
            meters: normalizedMeters,
            tempoMap: tempoMap,
            rawEvents: rawEvents,
            longNotes: notes.filter { $0.end - $0.start > noteRenderLookbackSeconds }
        )
    }

    private static func pairNotes(
        rawEvents: [PlaybackNoteEvent],
        tempoMap: [TempoPoint],
        ticksPerQuarter: Int
    ) -> [PlaybackNote] {
        let sortedEvents = rawEvents.sorted { first, second in
            if first.tick != second.tick { return first.tick < second.tick }
            if (first.velocity == 0) != (second.velocity == 0) {
                return first.velocity == 0
            }
            return first.order < second.order
        }
        var active: [String: EventQueue] = [:]
        var activeKeyOrder: [String] = []
        var notes: [PlaybackNote] = []

        for event in sortedEvents {
            let key = "\(event.track):\(event.channel):\(event.midiPitch)"
            if event.velocity > 0 {
                if active[key] == nil {
                    activeKeyOrder.append(key)
                }
                active[key, default: EventQueue()].append(event)
            } else if var queue = active[key], let start = queue.removeFirst() {
                active[key] = queue
                notes.append(
                    makeNote(
                        start: start,
                        endTick: max(event.tick, start.tick),
                        tempoMap: tempoMap,
                        ticksPerQuarter: ticksPerQuarter
                    )
                )
            }
        }

        for key in activeKeyOrder {
            guard let queue = active[key] else { continue }
            for start in queue.remainingEvents {
                notes.append(
                    makeNote(
                        start: start,
                        endTick: start.tick + Int64(ticksPerQuarter),
                        tempoMap: tempoMap,
                        ticksPerQuarter: ticksPerQuarter
                    )
                )
            }
        }
        return notes.enumerated().sorted {
            if $0.element.start != $1.element.start {
                return $0.element.start < $1.element.start
            }
            if $0.element.audioPitch != $1.element.audioPitch {
                return $0.element.audioPitch < $1.element.audioPitch
            }
            return $0.offset < $1.offset
        }.map { $0.element }
    }

    private static func makeNote(
        start: PlaybackNoteEvent,
        endTick: Int64,
        tempoMap: [TempoPoint],
        ticksPerQuarter: Int
    ) -> PlaybackNote {
        let startPitchFloat = start.pitchFloat ?? Double(start.pitch) + start.cents / 100.0
        return PlaybackNote(
            startTick: start.tick,
            endTick: endTick,
            start: tickToSeconds(
                tick: start.tick,
                tempoMap: tempoMap,
                ticksPerQuarter: ticksPerQuarter
            ),
            end: tickToSeconds(
                tick: endTick,
                tempoMap: tempoMap,
                ticksPerQuarter: ticksPerQuarter
            ),
            audioPitch: startPitchFloat,
            midiPitch: start.midiPitch,
            cents: (startPitchFloat - Double(kotlinRoundToInt(startPitchFloat))) * 100.0,
            velocity: start.velocity,
            channel: start.channel,
            track: start.track,
            program: start.program,
            bankMsb: start.bankMsb,
            bankLsb: start.bankLsb
        )
    }

    private static func popInline(
        inlineOffsets: inout [InlineOffset],
        midiPitch: Int,
        tick: Int64
    ) -> InlineOffset? {
        if let exactIndex = inlineOffsets.firstIndex(where: {
            $0.tick == tick && $0.pitch == midiPitch
        }) {
            return inlineOffsets.remove(at: exactIndex)
        }
        var foundIndex: Int?
        for (index, inline) in inlineOffsets.enumerated() where inline.tick == tick {
            if foundIndex != nil { return nil }
            foundIndex = index
        }
        return foundIndex.map { inlineOffsets.remove(at: $0) }
    }

    private static func decodePitchedOffsetPayload(
        _ payload: [UInt8]
    ) -> InlineOffsetPayload? {
        guard payload.count == midxPitchedOffsetPayloadLength,
              payload[0] == midxExperimentalManufacturerID,
              payload[1] == 0x58,
              payload[2] == 0x54,
              payload[3] == midxPitchedOffsetRecordType else {
            return nil
        }
        let raw = Int(payload[5]) << 8 | Int(payload[6])
        return InlineOffsetPayload(
            pitch: Int(payload[4]),
            cents: decodeCentOffset(raw)
        )
    }

    private static func decodeCentOffset(_ raw: Int) -> Double {
        let sign = raw & 0x8000 != 0 ? -1.0 : 1.0
        let magnitude = raw & 0x7FFF
        return sign * (Double(magnitude) / offsetMagnitudeSteps * offsetCentRange)
    }

    private static func pitchBendCents(value: Int, rangeSemitones: Double) -> Double {
        let delta = min(pitchBendMaximum, max(0, value)) - pitchBendCenter
        let normalized: Double
        if delta > 0 {
            normalized = Double(delta) / Double(pitchBendMaximum - pitchBendCenter)
        } else if delta < 0 {
            normalized = Double(delta) / Double(pitchBendCenter)
        } else {
            normalized = 0
        }
        return normalized * max(0, rangeSemitones) * 100.0
    }

    private static func skipSystemEvent(reader: ByteReader, status: Int) throws {
        let length: Int
        switch status {
        case 0xF1, 0xF3:
            length = 1
        case 0xF2:
            length = 2
        default:
            length = 0
        }
        _ = try reader.read(length)
    }

    private static func umpPacketSize(_ messageType: Int) -> Int {
        switch messageType {
        case 0x0, 0x1, 0x2:
            4
        case 0x3, 0x4:
            8
        case 0x5, 0xD, 0xF:
            16
        default:
            4
        }
    }

    private static func readU32(from bytes: [UInt8], offset: Int) -> UInt64 {
        UInt64(bytes[offset]) << 24
            | UInt64(bytes[offset + 1]) << 16
            | UInt64(bytes[offset + 2]) << 8
            | UInt64(bytes[offset + 3])
    }

    private static func scaleDownU32To7(_ value: UInt64) -> Int {
        min(
            127,
            max(
                0,
                kotlinRoundToInt(Double(value) * 127.0 / Double(UInt32.max))
            )
        )
    }

    private static func copyEvent(
        _ event: PlaybackNoteEvent,
        tick: Int64,
        order: Int64
    ) -> PlaybackNoteEvent {
        PlaybackNoteEvent(
            tick: tick,
            pitch: event.pitch,
            pitchFloat: event.pitchFloat,
            midiPitch: event.midiPitch,
            cents: event.cents,
            velocity: event.velocity,
            track: event.track,
            channel: event.channel,
            program: event.program,
            bankMsb: event.bankMsb,
            bankLsb: event.bankLsb,
            order: order
        )
    }

    /// Matches Kotlin's `Double.roundToInt`, including its 32-bit saturation bounds.
    private static func kotlinRoundToInt(_ value: Double) -> Int {
        if value >= Double(Int32.max) { return Int(Int32.max) }
        if value <= Double(Int32.min) { return Int(Int32.min) }
        return Int(floor(value + 0.5))
    }

    private struct InlineOffset {
        let tick: Int64
        let pitch: Int
        let cents: Double
    }

    private struct InlineOffsetPayload {
        let pitch: Int
        let cents: Double
    }

    private struct EventQueue {
        private var events: [PlaybackNoteEvent] = []
        private var head = 0

        var remainingEvents: ArraySlice<PlaybackNoteEvent> {
            events[head...]
        }

        mutating func append(_ event: PlaybackNoteEvent) {
            events.append(event)
        }

        mutating func removeFirst() -> PlaybackNoteEvent? {
            guard head < events.count else { return nil }
            defer { head += 1 }
            return events[head]
        }
    }

    private final class ByteReader {
        private let data: [UInt8]
        private let source: String
        private var position = 0

        init(_ data: [UInt8], source: String) {
            self.data = data
            self.source = source
        }

        var remaining: Int { data.count - position }

        func read(_ count: Int) throws -> [UInt8] {
            guard count >= 0, count <= remaining else {
                throw MidiWaterfallParserError(
                    "\(source): unexpected end of file at byte \(position)"
                )
            }
            let output = Array(data[position..<(position + count)])
            position += count
            return output
        }

        func readByte() throws -> Int {
            Int(try read(1)[0])
        }

        func peekByte() throws -> Int {
            guard remaining > 0 else {
                throw MidiWaterfallParserError("\(source): unexpected end of file")
            }
            return Int(data[position])
        }

        func readU16() throws -> Int {
            let bytes = try read(2)
            return Int(bytes[0]) << 8 | Int(bytes[1])
        }

        func readU32() throws -> UInt64 {
            let bytes = try read(4)
            return UInt64(bytes[0]) << 24
                | UInt64(bytes[1]) << 16
                | UInt64(bytes[2]) << 8
                | UInt64(bytes[3])
        }

        func readASCII(_ count: Int) throws -> String {
            let bytes = try read(count)
            return String(bytes.map { Character(UnicodeScalar(Int($0))!) })
        }

        func readVLQ() throws -> Int {
            var value = 0
            for _ in 0..<4 {
                let byte = try readByte()
                value = value << 7 | byte & 0x7F
                if byte < 0x80 { return value }
            }
            throw MidiWaterfallParserError(
                "\(source): invalid variable-length quantity"
            )
        }
    }
}
