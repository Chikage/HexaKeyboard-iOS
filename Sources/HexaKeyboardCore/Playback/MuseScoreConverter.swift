import Compression
import Foundation

public enum MuseScoreConversionError: Error, LocalizedError, Equatable {
    case emptyXML
    case unsupportedXML(String)
    case invalidXML(String)
    case noScore(String)
    case invalidArchive(String)
    case noMuseScoreDocument(String)
    case unsupportedCompression(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyXML:
            return "Empty XML document"
        case let .unsupportedXML(message),
             let .invalidXML(message),
             let .noScore(message),
             let .invalidArchive(message),
             let .noMuseScoreDocument(message):
            return message
        case let .unsupportedCompression(method):
            return "Unsupported ZIP compression method: \(method)"
        }
    }
}

/// Converts MuseScore `.mscx` XML and `.mscz` archives to Standard MIDI or
/// the MIDX extension used by HexaKeyboard for per-note cent offsets.
public enum MuseScoreConverter {
    private static let defaultDivision = 480
    private static let defaultBPM = 120.0
    private static let defaultVelocity = 80
    private static let defaultTimeSigN = 4
    private static let defaultTimeSigD = 4

    private static let midxMetaType: UInt8 = 0x7F
    private static let midxPayloadLength: UInt8 = 7
    private static let midxExperimentalManufacturerID: UInt8 = 0x7D
    private static let midxPitchedOffsetRecordType: UInt8 = 0x03
    private static let midxCentRange = 64.0
    private static let midxSafeCentRange = 63.0
    private static let midxOffsetSteps = 32_768.0
    private static let midiControlSustain = 64
    private static let maxRepeatCount = 8

    public static func convert(_ data: Data, fileName: String = "selected-file") throws -> Data {
        try convertToMIDX(data, fileName: fileName)
    }

    public static func convertToMIDX(_ data: Data, fileName: String = "selected-file") throws -> Data {
        try writeMIDIFile(parseScore(data, fileName: fileName), includeMIDXExtensions: true)
    }

    /// Compatibility spelling matching the Android API.
    public static func convertToMidx(_ data: Data, fileName: String = "selected-file") throws -> Data {
        try convertToMIDX(data, fileName: fileName)
    }

    public static func convertToMIDI(_ data: Data, fileName: String = "selected-file") throws -> Data {
        try writeMIDIFile(parseScore(data, fileName: fileName), includeMIDXExtensions: false)
    }

    /// Compatibility spelling matching the Android API.
    public static func convertToMidi(_ data: Data, fileName: String = "selected-file") throws -> Data {
        try convertToMIDI(data, fileName: fileName)
    }

    public static func convert(contentsOf inputURL: URL) throws -> Data {
        try convert(Data(contentsOf: inputURL), fileName: inputURL.lastPathComponent)
    }

    public static func convertToMIDX(contentsOf inputURL: URL) throws -> Data {
        try convertToMIDX(Data(contentsOf: inputURL), fileName: inputURL.lastPathComponent)
    }

    public static func convertToMIDI(contentsOf inputURL: URL) throws -> Data {
        try convertToMIDI(Data(contentsOf: inputURL), fileName: inputURL.lastPathComponent)
    }

    private static func parseScore(_ input: Data, fileName: String) throws -> ScoreData {
        let xml = try readMuseScoreXML(input, fileName: fileName)
        let root = try parseXML(xml)
        let sourceName = fileName.isEmpty ? "selected-file" : fileName
        return try parseScoreXML(root, sourceName: sourceName)
    }

    private static func readMuseScoreXML(_ input: Data, fileName: String) throws -> Data {
        let lowerName = fileName.lowercased()
        if lowerName.hasSuffix(".mscz") || isZIP(input) {
            return try readMSCZRootXML(input, sourceName: fileName)
        }
        return input
    }

    private static func readMSCZRootXML(_ input: Data, sourceName: String) throws -> Data {
        let archive = try ZIPArchive(data: input)
        var rootPath: String?
        if let container = archive.entry(named: "META-INF/container.xml") {
            rootPath = normalizeZIPPath(try firstRootfilePath(archive.data(for: container)))
        }

        let scoreEntry = rootPath.flatMap(archive.entry(named:)) ?? archive.firstMSCXEntry()
        guard let scoreEntry else {
            throw MuseScoreConversionError.noMuseScoreDocument(
                "No .mscx score found inside \(sourceName.isEmpty ? "selected-file" : sourceName)"
            )
        }
        return try archive.data(for: scoreEntry)
    }

    private static func normalizeZIPPath(_ path: String?) -> String? {
        guard var value = path?.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        while value.hasPrefix("/") {
            value.removeFirst()
        }
        guard !value.isEmpty, !value.contains(":") else { return nil }
        var clean: [Substring] = []
        for part in value.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty || part == "." { continue }
            if part == ".." { return nil }
            clean.append(part)
        }
        guard !clean.isEmpty else { return nil }
        return clean.joined(separator: "/")
    }

    private static func isZIP(_ data: Data) -> Bool {
        data.count >= 4
            && data[data.startIndex] == 0x50
            && data[data.startIndex + 1] == 0x4B
            && data[data.startIndex + 2] == 0x03
            && data[data.startIndex + 3] == 0x04
    }

    private static func parseXML(_ bytes: Data) throws -> XMLNode {
        let normalized = try normalizeXMLBytes(bytes)
        try rejectUnsupportedXML(normalized)
        let delegate = XMLTreeDelegate()
        let parser = XMLParser(data: normalized)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = delegate.root else {
            let detail = parser.parserError?.localizedDescription ?? "Empty XML document"
            throw MuseScoreConversionError.invalidXML("Could not parse MuseScore XML: \(detail)")
        }
        return root
    }

    private static func firstRootfilePath(_ bytes: Data) throws -> String? {
        let root = try parseXML(bytes)
        return firstDescendant(root, "rootfile")?.attribute("full-path")
    }

    private static func normalizeXMLBytes(_ bytes: Data) throws -> Data {
        guard !bytes.isEmpty else { throw MuseScoreConversionError.emptyXML }
        var start = bytes.startIndex
        if bytes.count >= 3,
           bytes[start] == 0xEF,
           bytes[start + 1] == 0xBB,
           bytes[start + 2] == 0xBF
        {
            start += 3
        }
        while start < bytes.endIndex {
            switch bytes[start] {
            case 0x20, 0x09, 0x0A, 0x0D:
                start += 1
            default:
                return start == bytes.startIndex ? bytes : Data(bytes[start...])
            }
        }
        throw MuseScoreConversionError.emptyXML
    }

    private static func rejectUnsupportedXML(_ bytes: Data) throws {
        let xml = String(decoding: bytes, as: UTF8.self).lowercased()
        if xml.contains("<!doctype") {
            throw MuseScoreConversionError.unsupportedXML("MuseScore XML with DOCTYPE is not supported")
        }
        if xml.contains("<!entity") {
            throw MuseScoreConversionError.unsupportedXML("MuseScore XML with entity declarations is not supported")
        }
    }
}

private extension MuseScoreConverter {
    struct ZIPEntry {
        let name: String
        let method: Int
        let crc32: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        let isDirectory: Bool
    }

    struct ZIPArchive {
        let bytes: Data
        let entries: [ZIPEntry]

        init(data: Data) throws {
            bytes = data
            guard let eocd = Self.findEndOfCentralDirectory(in: data),
                  Self.u32(data, eocd) == 0x0605_4B50
            else {
                throw MuseScoreConversionError.invalidArchive("Invalid or unsupported MSCZ ZIP archive")
            }

            let diskNumber = Self.u16(data, eocd + 4)
            let centralDiskNumber = Self.u16(data, eocd + 6)
            let entriesOnDisk = Int(Self.u16(data, eocd + 8))
            let entryCount = Int(Self.u16(data, eocd + 10))
            let centralOffset = Int(Self.u32(data, eocd + 16))
            guard diskNumber == 0, centralDiskNumber == 0, entriesOnDisk == entryCount else {
                throw MuseScoreConversionError.invalidArchive("Multi-disk MSCZ archives are not supported")
            }
            guard entryCount != 0xFFFF, centralOffset != Int(UInt32.max) else {
                throw MuseScoreConversionError.invalidArchive("ZIP64 MSCZ archives are not supported")
            }

            var parsed: [ZIPEntry] = []
            var offset = centralOffset
            for _ in 0..<entryCount {
                guard offset >= 0,
                      offset + 46 <= data.count,
                      Self.u32(data, offset) == 0x0201_4B50
                else {
                    throw MuseScoreConversionError.invalidArchive("Invalid MSCZ central directory")
                }
                let flags = Self.u16(data, offset + 8)
                guard flags & 1 == 0 else {
                    throw MuseScoreConversionError.invalidArchive("Encrypted MSCZ entries are not supported")
                }
                let method = Int(Self.u16(data, offset + 10))
                let checksum = Self.u32(data, offset + 16)
                let compressedSize = Int(Self.u32(data, offset + 20))
                let uncompressedSize = Int(Self.u32(data, offset + 24))
                let nameLength = Int(Self.u16(data, offset + 28))
                let extraLength = Int(Self.u16(data, offset + 30))
                let commentLength = Int(Self.u16(data, offset + 32))
                let localOffset = Int(Self.u32(data, offset + 42))
                let nameStart = offset + 46
                let nameEnd = nameStart + nameLength
                guard nameEnd <= data.count else {
                    throw MuseScoreConversionError.invalidArchive("Invalid MSCZ entry name")
                }
                let name = String(decoding: data[nameStart..<nameEnd], as: UTF8.self)
                parsed.append(
                    ZIPEntry(
                        name: name,
                        method: method,
                        crc32: checksum,
                        compressedSize: compressedSize,
                        uncompressedSize: uncompressedSize,
                        localHeaderOffset: localOffset,
                        isDirectory: name.hasSuffix("/") || name.hasSuffix("\\")
                    )
                )
                offset = nameEnd + extraLength + commentLength
            }
            entries = parsed
        }

        func entry(named path: String) -> ZIPEntry? {
            guard let normalized = MuseScoreConverter.normalizeZIPPath(path) else { return nil }
            return entries.first {
                !$0.isDirectory && MuseScoreConverter.normalizeZIPPath($0.name) == normalized
            }
        }

        func firstMSCXEntry() -> ZIPEntry? {
            entries.first {
                !$0.isDirectory
                    && (MuseScoreConverter.normalizeZIPPath($0.name)?.lowercased().hasSuffix(".mscx") == true)
            }
        }

        func data(for entry: ZIPEntry) throws -> Data {
            let header = entry.localHeaderOffset
            guard header >= 0,
                  header + 30 <= bytes.count,
                  Self.u32(bytes, header) == 0x0403_4B50
            else {
                throw MuseScoreConversionError.invalidArchive("Invalid MSCZ local file header")
            }
            let nameLength = Int(Self.u16(bytes, header + 26))
            let extraLength = Int(Self.u16(bytes, header + 28))
            let start = header + 30 + nameLength + extraLength
            let end = start + entry.compressedSize
            guard start >= 0, end >= start, end <= bytes.count else {
                throw MuseScoreConversionError.invalidArchive("Truncated MSCZ entry: \(entry.name)")
            }
            let compressed = Data(bytes[start..<end])
            let result: Data
            switch entry.method {
            case 0:
                guard compressed.count == entry.uncompressedSize else {
                    throw MuseScoreConversionError.invalidArchive("Invalid stored MSCZ entry: \(entry.name)")
                }
                result = compressed
            case 8:
                result = try Self.inflate(
                    compressed,
                    expectedSize: entry.uncompressedSize,
                    name: entry.name
                )
            default:
                throw MuseScoreConversionError.unsupportedCompression(entry.method)
            }
            guard Self.crc32(result) == entry.crc32 else {
                throw MuseScoreConversionError.invalidArchive("CRC mismatch in MSCZ entry: \(entry.name)")
            }
            return result
        }

        private static func inflate(_ input: Data, expectedSize: Int, name: String) throws -> Data {
            if expectedSize == 0 { return Data() }
            guard expectedSize > 0 else {
                throw MuseScoreConversionError.invalidArchive("Invalid uncompressed size for \(name)")
            }
            var output = Data(count: expectedSize)
            let decoded = output.withUnsafeMutableBytes { destination in
                input.withUnsafeBytes { source in
                    compression_decode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!,
                        expectedSize,
                        source.bindMemory(to: UInt8.self).baseAddress!,
                        input.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            guard decoded == expectedSize else {
                throw MuseScoreConversionError.invalidArchive("Could not decompress MSCZ entry: \(name)")
            }
            return output
        }

        private static func findEndOfCentralDirectory(in data: Data) -> Int? {
            guard data.count >= 22 else { return nil }
            let lowerBound = max(0, data.count - 65_557)
            var index = data.count - 22
            while index >= lowerBound {
                if u32(data, index) == 0x0605_4B50 { return index }
                if index == 0 { break }
                index -= 1
            }
            return nil
        }

        private static func crc32(_ data: Data) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in data {
                crc ^= UInt32(byte)
                for _ in 0..<8 {
                    crc = (crc & 1) == 0 ? crc >> 1 : (crc >> 1) ^ 0xEDB8_8320
                }
            }
            return crc ^ 0xFFFF_FFFF
        }

        private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
            guard offset >= 0, offset + 2 <= data.count else { return 0 }
            return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }

        private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
            guard offset >= 0, offset + 4 <= data.count else { return 0 }
            return UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
        }
    }

    final class XMLNode {
        let name: String
        var attributes: [String: String] = [:]
        var children: [XMLNode] = []
        var textContent = ""

        init(name: String) {
            self.name = name
        }

        func attribute(_ name: String) -> String {
            attributes[name] ?? ""
        }
    }

    final class XMLTreeDelegate: NSObject, XMLParserDelegate {
        var root: XMLNode?
        private var stack: [XMLNode] = []

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let node = XMLNode(name: elementName)
            node.attributes = attributeDict
            if let parent = stack.last {
                parent.children.append(node)
            } else {
                root = node
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.textContent.append(string)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            _ = stack.popLast()
        }
    }
}

private extension MuseScoreConverter {
    static func parseScoreXML(_ root: XMLNode, sourceName: String) throws -> ScoreData {
        guard let scoreElement = root.name == "Score" ? root : firstChild(root, "Score") else {
            throw MuseScoreConversionError.noScore("No <Score> element found in \(sourceName)")
        }

        let score = ScoreData()
        score.division = intText(firstChild(scoreElement, "Division"), defaultDivision)
        if score.division <= 0 { score.division = defaultDivision }

        parseScoreStyle(scoreElement, score: score)
        parseParts(scoreElement, score: score)
        parseStaffBodies(scoreElement, score: score)

        if score.tempoEvents.isEmpty {
            score.tempoEvents.append(TempoEvent(tick: 0, bpm: defaultBPM))
        }
        if score.timeSigEvents.isEmpty {
            score.timeSigEvents.append(
                TimeSigEvent(tick: 0, numerator: defaultTimeSigN, denominator: defaultTimeSigD)
            )
        }
        return score
    }

    static func parseScoreStyle(_ scoreElement: XMLNode, score: ScoreData) {
        guard let style = firstChild(scoreElement, "Style") else { return }
        let ratio = intText(firstChild(style, "swingRatio"), 0)
        if ratio > 0 { score.swingRatio = clamped(ratio, 50, 90) }
    }

    static func parseParts(_ scoreElement: XMLNode, score: ScoreData) {
        var partIndex = 0
        var nextChannel = 0
        for part in children(scoreElement, "Part") {
            let program = parsePartProgram(part)
            let bankMSB = parsePartBank(part, controllerNumber: 0)
            let bankLSB = parsePartBank(part, controllerNumber: 32)
            let midiChannel = parsePartMIDIChannel(part)
            let gateTimePercent = parsePartGateTime(part)
            let trackName = parsePartTrackName(part)
            let instrumentName = parsePartInstrumentName(part)
            let partStaffs = children(part, "Staff")
            if partStaffs.isEmpty { continue }

            let channel: Int
            if midiChannel >= 0 {
                channel = clamped(midiChannel, 0, 15)
            } else {
                channel = chooseChannel(nextChannel)
                nextChannel += 1
            }
            var firstStaffInPart = true
            for staffElement in partStaffs {
                let staffID = intAttribute(staffElement, "id", score.staffInfos.count + 1)
                let info = StaffInfo(
                    staffID: staffID,
                    partIndex: partIndex,
                    program: clamped(program, 0, 127),
                    bankMSB: bankMSB,
                    bankLSB: bankLSB,
                    channel: channel,
                    gateTimePercent: gateTimePercent,
                    writeProgramChange: firstStaffInPart,
                    trackName: trackName,
                    instrumentName: instrumentName
                )
                score.staffInfos[staffID] = info
                firstStaffInPart = false
            }
            partIndex += 1
        }
    }

    static func parsePartProgram(_ part: XMLNode) -> Int {
        let channel = primaryChannelElement(part)
        var program = firstChild(channel, "program")
        let instrument = firstChild(part, "Instrument")
        if program == nil { program = firstDescendant(instrument, "program") }
        guard let program else { return 0 }
        let value = program.attribute("value")
        return value.isEmpty ? parseInt(text(program), 0) : parseInt(value, 0)
    }

    static func parsePartMIDIChannel(_ part: XMLNode) -> Int {
        intText(firstChild(primaryChannelElement(part), "midiChannel"), -1)
    }

    static func parsePartBank(_ part: XMLNode, controllerNumber: Int) -> Int {
        guard let channel = primaryChannelElement(part) else { return -1 }
        for controller in children(channel, "controller") {
            if intAttribute(controller, "ctrl", -1) == controllerNumber {
                return clamped(intAttribute(controller, "value", 0), 0, 127)
            }
        }
        return -1
    }

    static func primaryChannelElement(_ part: XMLNode) -> XMLNode? {
        guard let instrument = firstChild(part, "Instrument") else { return nil }
        let channels = children(instrument, "Channel")
        for channel in channels {
            let name = channel.attribute("name")
            if name.isEmpty || name.caseInsensitiveCompare("normal") == .orderedSame
                || name.caseInsensitiveCompare("open") == .orderedSame
            {
                return channel
            }
        }
        return channels.first
    }

    static func parsePartGateTime(_ part: XMLNode) -> Int {
        guard let instrument = firstChild(part, "Instrument") else { return 100 }
        for articulation in children(instrument, "Articulation") {
            if articulation.attribute("name").isEmpty {
                return clamped(intText(firstChild(articulation, "gateTime"), 100), 1, 1000)
            }
        }
        return 100
    }

    static func parsePartTrackName(_ part: XMLNode) -> String {
        let name = text(firstChild(part, "trackName"))
        if !name.isEmpty { return name }
        return text(firstChild(firstChild(part, "Instrument"), "trackName"))
    }

    static func parsePartInstrumentName(_ part: XMLNode) -> String {
        let instrument = firstChild(part, "Instrument")
        let longName = text(firstChild(instrument, "longName"))
        if !longName.isEmpty { return longName }
        let shortName = text(firstChild(instrument, "shortName"))
        if !shortName.isEmpty { return shortName }
        return text(firstChild(instrument, "instrumentId"))
    }

    static func chooseChannel(_ index: Int) -> Int {
        let channel = index % 15
        return channel >= 9 ? channel + 1 : channel
    }

    static func parseStaffBodies(_ scoreElement: XMLNode, score: ScoreData) {
        var fallbackStaffID = 1
        let staffBodies = children(scoreElement, "Staff")
        let timeline = buildMeasureTimeline(staffBodies, division: score.division)
        for staffBody in staffBodies {
            let staffID = intAttribute(staffBody, "id", fallbackStaffID)
            fallbackStaffID += 1
            let info: StaffInfo
            if let existing = score.staffInfos[staffID] {
                info = existing
            } else {
                info = StaffInfo(
                    staffID: staffID,
                    partIndex: score.staffInfos.count,
                    program: 0,
                    bankMSB: -1,
                    bankLSB: -1,
                    channel: chooseChannel(score.staffInfos.count),
                    gateTimePercent: 100,
                    writeProgramChange: true,
                    trackName: "",
                    instrumentName: ""
                )
                score.staffInfos[staffID] = info
            }
            let track = score.track(for: info)
            collectPlaybackSpanners(staffBody, track: track, timeline: timeline, division: score.division)
            parseStaffBody(staffBody, score: score, track: track, timeline: timeline)
        }
    }

    static func buildMeasureTimeline(_ staffBodies: [XMLNode], division: Int) -> MeasureTimeline {
        let measuresByStaff = staffBodies.map { children($0, "Measure") }
        let maxMeasures = measuresByStaff.map(\.count).max() ?? 0
        var starts: [Int] = []
        var lengths: [Int] = []
        var tick = 0
        var currentSigN = defaultTimeSigN
        var currentSigD = defaultTimeSigD

        for measureIndex in 0..<maxMeasures {
            starts.append(tick)
            if let signature = firstTimeSig(at: measureIndex, measuresByStaff: measuresByStaff) {
                currentSigN = signature.numerator
                currentSigD = signature.denominator
            }
            let length = max(
                1,
                measureLength(
                    at: measureIndex,
                    measuresByStaff: measuresByStaff,
                    division: division,
                    sigN: currentSigN,
                    sigD: currentSigD,
                    measureStart: tick
                )
            )
            lengths.append(length)
            tick += length
        }

        let timeline = MeasureTimeline(sourceStarts: starts, sourceLengths: lengths)
        var repeatStart = 0
        var outputTick = 0
        for measureIndex in 0..<maxMeasures {
            if measureHasStartRepeat(measuresByStaff, measureIndex) { repeatStart = measureIndex }
            outputTick = addMeasureSlot(timeline, measureIndex: measureIndex, outputTick: outputTick)
            let repeatCount = measureEndRepeatCount(measuresByStaff, measureIndex)
            if repeatCount > 1 {
                let safeCount = clamped(repeatCount, 2, maxRepeatCount)
                if safeCount > 1 {
                    for _ in 1..<safeCount {
                        if repeatStart <= measureIndex {
                            for replayIndex in repeatStart...measureIndex {
                                outputTick = addMeasureSlot(
                                    timeline,
                                    measureIndex: replayIndex,
                                    outputTick: outputTick
                                )
                            }
                        }
                    }
                }
                repeatStart = measureIndex + 1
            }
        }
        return timeline
    }

    @discardableResult
    static func addMeasureSlot(_ timeline: MeasureTimeline, measureIndex: Int, outputTick: Int) -> Int {
        let sourceStart = timeline.sourceStarts.indices.contains(measureIndex)
            ? timeline.sourceStarts[measureIndex] : 0
        let sourceLength = timeline.sourceLengths.indices.contains(measureIndex)
            ? timeline.sourceLengths[measureIndex] : defaultDivision
        let length = max(1, sourceLength)
        timeline.slots.append(
            MeasureSlot(
                measureIndex: measureIndex,
                sourceStart: sourceStart,
                outputStart: outputTick,
                length: length
            )
        )
        return outputTick + length
    }

    static func measureHasStartRepeat(_ measuresByStaff: [[XMLNode]], _ measureIndex: Int) -> Bool {
        measuresByStaff.contains {
            $0.indices.contains(measureIndex) && firstChild($0[measureIndex], "startRepeat") != nil
        }
    }

    static func measureEndRepeatCount(_ measuresByStaff: [[XMLNode]], _ measureIndex: Int) -> Int {
        var repeatCount = 0
        for measures in measuresByStaff where measures.indices.contains(measureIndex) {
            if let endRepeat = firstChild(measures[measureIndex], "endRepeat") {
                repeatCount = max(repeatCount, max(2, intText(endRepeat, 2)))
            }
        }
        return repeatCount
    }

    static func firstTimeSig(at measureIndex: Int, measuresByStaff: [[XMLNode]]) -> TimeSigEvent? {
        for measures in measuresByStaff where measures.indices.contains(measureIndex) {
            if let timeSig = firstTimeSig(in: measures[measureIndex]) {
                let n = intText(firstChild(timeSig, "sigN"), defaultTimeSigN)
                let d = intText(firstChild(timeSig, "sigD"), defaultTimeSigD)
                if n > 0, d > 0 {
                    return TimeSigEvent(tick: 0, numerator: n, denominator: d)
                }
            }
        }
        return nil
    }

    static func firstTimeSig(in measure: XMLNode) -> XMLNode? {
        for voice in children(measure, "voice") {
            if let timeSig = firstChild(voice, "TimeSig") { return timeSig }
        }
        return nil
    }

    static func measureLength(
        at measureIndex: Int,
        measuresByStaff: [[XMLNode]],
        division: Int,
        sigN: Int,
        sigD: Int,
        measureStart: Int
    ) -> Int {
        let signatureTicks = ticksForTimeSignature(division: division, sigN: sigN, sigD: sigD)
        var irregular = false
        var irregularTicks = 0
        for measures in measuresByStaff where measures.indices.contains(measureIndex) {
            let measure = measures[measureIndex]
            if hasAttributeValue(measure, "len") {
                let explicitTicks = ratioTicks(measure.attribute("len"), division: division)
                if explicitTicks > 0 { return explicitTicks }
            }
            if intText(firstChild(measure, "irregular"), 0) != 0 {
                irregular = true
                irregularTicks = max(
                    irregularTicks,
                    measureContentTicks(
                        measure,
                        division: division,
                        measureTicks: signatureTicks,
                        measureStart: measureStart
                    )
                )
            }
        }
        return irregular && irregularTicks > 0 ? irregularTicks : signatureTicks
    }

    static func measureContentTicks(
        _ measure: XMLNode,
        division: Int,
        measureTicks: Int,
        measureStart: Int
    ) -> Int {
        var maxTicks = 0
        for voice in children(measure, "voice") {
            var tick = 0
            var legacyTupletRatio = 1.0
            var legacyTupletRemaining = 0
            var tupletsByID: [String: TupletInfo] = [:]
            for element in voice.children {
                switch element.name {
                case "Tuplet":
                    if let info = parseTupletInfo(element, knownTuplets: tupletsByID) {
                        if !info.id.isEmpty {
                            tupletsByID[info.id] = info
                        } else {
                            legacyTupletRatio = info.ratio
                            legacyTupletRemaining = info.actualNotes
                        }
                    }
                case "endTuplet":
                    legacyTupletRatio = 1
                    legacyTupletRemaining = 0
                case "tick":
                    tick = max(0, fileTick(text(element)) - measureStart)
                case "location":
                    tick += locationTicks(element, division: division, measureTicks: measureTicks)
                case "Rest", "Chord":
                    if element.name == "Chord", isGraceChord(element) { continue }
                    let ratio = tupletRatio(
                        for: element,
                        knownTuplets: tupletsByID,
                        fallbackRatio: legacyTupletRatio
                    )
                    tick += max(0, durationTicks(element, division: division, tupletRatio: ratio, measureTicks: measureTicks))
                    if legacyTupletRemaining > 0, firstChild(element, "Tuplet") == nil {
                        legacyTupletRemaining -= 1
                        if legacyTupletRemaining <= 0 { legacyTupletRatio = 1 }
                    }
                default:
                    break
                }
            }
            maxTicks = max(maxTicks, tick)
        }
        return maxTicks
    }

    static func parseStaffBody(
        _ staffBody: XMLNode,
        score: ScoreData,
        track: TrackData,
        timeline: MeasureTimeline
    ) {
        let measures = children(staffBody, "Measure")
        var voiceStates: [Int: VoiceState] = [:]
        for slot in timeline.slots where measures.indices.contains(slot.measureIndex) {
            let measure = measures[slot.measureIndex]
            let voices = children(measure, "voice")
            if voices.isEmpty { continue }
            for voiceIndex in voices.indices {
                let state: VoiceState
                if let existing = voiceStates[voiceIndex] {
                    state = existing
                } else {
                    state = VoiceState()
                    state.velocity = defaultVelocity
                    state.swingRatio = score.swingRatio
                    state.swingUnitDenominator = score.swingUnitDenominator
                    voiceStates[voiceIndex] = state
                }
                state.tick = slot.outputStart
                state.gridTick = slot.outputStart
                state.measureStart = slot.outputStart
                state.sourceMeasureStart = slot.sourceStart
                state.measureTicks = max(1, slot.length)
                state.tupletRatio = 1
                state.tupletRemaining = 0
                state.tupletsByID.removeAll(keepingCapacity: true)
                state.pendingGraceChords.removeAll(keepingCapacity: true)
                state.pendingFermataMultiplier = 1
                parseVoice(voices[voiceIndex], score: score, track: track, state: state, voiceIndex: voiceIndex)
            }
        }

        for state in voiceStates.values {
            for playback in state.activeTies.values { emitPlayback(track, score: score, playback: playback) }
            state.activeTies.removeAll()
        }
    }

    static func parseVoice(
        _ voice: XMLNode,
        score: ScoreData,
        track: TrackData,
        state: VoiceState,
        voiceIndex: Int
    ) {
        var childIndex = 0
        while childIndex < voice.children.count {
            let element = voice.children[childIndex]
            switch element.name {
            case "Tempo":
                let tempo = doubleText(firstChild(element, "tempo"), -1)
                if tempo > 0 {
                    let bpm = tempo * 60
                    state.bpm = bpm
                    score.tempoEvents.append(TempoEvent(tick: state.tick, bpm: bpm))
                }
            case "TimeSig":
                let n = intText(firstChild(element, "sigN"), defaultTimeSigN)
                let d = intText(firstChild(element, "sigD"), defaultTimeSigD)
                if n > 0, d > 0 {
                    state.lastTimeSigN = n
                    state.lastTimeSigD = d
                    score.timeSigEvents.append(TimeSigEvent(tick: state.tick, numerator: n, denominator: d))
                }
            case "Dynamic":
                state.velocity = clamped(intText(firstChild(element, "velocity"), state.velocity), 1, 127)
            case "StaffText", "SystemText":
                applySwingText(element, state: state)
            case "location":
                let offset = locationTicks(element, division: score.division, measureTicks: state.measureTicks)
                state.tick += offset
                state.gridTick += offset
            case "tick":
                let absoluteTick = fileTick(text(element))
                state.tick = state.measureStart + max(0, absoluteTick - state.sourceMeasureStart)
                state.gridTick = state.tick
            case "Tuplet":
                if let info = parseTupletInfo(element, knownTuplets: state.tupletsByID) {
                    if !info.id.isEmpty {
                        state.tupletsByID[info.id] = info
                    } else {
                        state.tupletRatio = info.ratio
                        state.tupletRemaining = info.actualNotes
                    }
                }
            case "endTuplet":
                state.tupletRatio = 1
                state.tupletRemaining = 0
            case "Rest":
                let duration = durationTicks(
                    element,
                    division: score.division,
                    tupletRatio: tupletRatio(
                        for: element,
                        knownTuplets: state.tupletsByID,
                        fallbackRatio: state.tupletRatio
                    ),
                    measureTicks: state.measureTicks
                )
                state.tick += max(0, applyAndConsumeFermata(state, duration: swungDuration(state, duration: duration, division: score.division)))
                state.gridTick += max(0, duration)
                consumeTupletSlot(state, element: element)
            case "Chord":
                let nominalDuration = durationTicks(
                    element,
                    division: score.division,
                    tupletRatio: tupletRatio(
                        for: element,
                        knownTuplets: state.tupletsByID,
                        fallbackRatio: state.tupletRatio
                    ),
                    measureTicks: state.measureTicks
                )
                if isGraceChord(element) {
                    state.pendingGraceChords.append(element)
                } else {
                    let partnerIndex = twoChordTremoloPartnerIndex(voice, chordIndex: childIndex)
                    if partnerIndex >= 0 {
                        let partner = voice.children[partnerIndex]
                        let partnerDuration = durationTicks(
                            partner,
                            division: score.division,
                            tupletRatio: tupletRatio(
                                for: partner,
                                knownTuplets: state.tupletsByID,
                                fallbackRatio: state.tupletRatio
                            ),
                            measureTicks: state.measureTicks
                        )
                        let gridDuration = max(1, nominalDuration + partnerDuration)
                        let playedDuration = applyAndConsumeFermata(state, duration: gridDuration)
                        appendTwoChordTremoloWithGraceNotes(
                            element,
                            secondChord: partner,
                            score: score,
                            track: track,
                            state: state,
                            voiceIndex: voiceIndex,
                            nominalDuration: max(1, playedDuration)
                        )
                        state.tick += max(0, playedDuration)
                        state.gridTick += max(0, gridDuration)
                        consumeTupletSlot(state, element: element)
                        consumeTupletSlot(state, element: partner)
                        childIndex = partnerIndex
                    } else {
                        let playedDuration = applyAndConsumeFermata(
                            state,
                            duration: swungDuration(state, duration: nominalDuration, division: score.division)
                        )
                        appendChordWithGraceNotes(
                            element,
                            score: score,
                            track: track,
                            state: state,
                            voiceIndex: voiceIndex,
                            nominalDuration: max(1, playedDuration)
                        )
                        state.tick += max(0, playedDuration)
                        state.gridTick += max(0, nominalDuration)
                        consumeTupletSlot(state, element: element)
                    }
                    state.pendingGraceChords.removeAll(keepingCapacity: true)
                }
            case "Fermata":
                state.pendingFermataMultiplier = max(
                    state.pendingFermataMultiplier,
                    fermataMultiplier(element)
                )
            default:
                break
            }
            childIndex += 1
        }
    }

    static func applyAndConsumeFermata(_ state: VoiceState, duration: Int) -> Int {
        let multiplier = state.pendingFermataMultiplier
        state.pendingFermataMultiplier = 1
        return multiplier <= 1 ? duration : max(1, javaRound(Double(duration) * multiplier))
    }

    static func applySwingText(_ textElement: XMLNode, state: VoiceState) {
        guard let swing = firstChild(textElement, "swing") else { return }
        let ratio = intAttribute(swing, "ratio", state.swingRatio)
        state.swingRatio = ratio <= 0 ? 0 : clamped(ratio, 50, 90)
        let unit = swing.attribute("unit").lowercased()
        if unit.contains("16") {
            state.swingUnitDenominator = 16
        } else if unit.contains("eighth") || unit.contains("8") {
            state.swingUnitDenominator = 8
        }
    }

    static func swungDuration(_ state: VoiceState, duration: Int, division: Int) -> Int {
        guard state.swingRatio > 50, duration > 0 else { return duration }
        let unit = max(1, javaRound(Double(division) * 4 / Double(max(1, state.swingUnitDenominator))))
        guard abs(duration - unit) <= 1 else { return duration }
        let pair = unit * 2
        let position = positiveModulo(state.gridTick - state.measureStart, pair)
        let first = clamped(javaRound(Double(pair) * Double(state.swingRatio) / 100), 1, pair - 1)
        if position == 0 { return first }
        if abs(position - unit) <= 1 { return max(1, pair - first) }
        return duration
    }
}

private extension MuseScoreConverter {
    static func appendChordWithGraceNotes(
        _ chord: XMLNode,
        score: ScoreData,
        track: TrackData,
        state: VoiceState,
        voiceIndex: Int,
        nominalDuration: Int
    ) {
        let beforeGrace = state.pendingGraceChords.filter { !isGraceAfterChord($0) }
        let afterGrace = state.pendingGraceChords.filter(isGraceAfterChord)
        let split = gracePlaybackSplit(
            mainChord: chord,
            state: state,
            beforeGrace: beforeGrace,
            afterGrace: afterGrace,
            nominalDuration: nominalDuration,
            division: score.division
        )
        for (index, grace) in beforeGrace.enumerated() {
            appendChordNotes(
                grace,
                score: score,
                track: track,
                state: state,
                voiceIndex: voiceIndex,
                chordStartTick: state.tick + split.beforeEach * index,
                nominalDuration: split.beforeEach
            )
        }

        let mainStart = state.tick + split.beforeTotal
        let mainDuration = max(1, nominalDuration - split.beforeTotal - split.afterTotal)
        appendChordNotes(
            chord,
            score: score,
            track: track,
            state: state,
            voiceIndex: voiceIndex,
            chordStartTick: mainStart,
            nominalDuration: mainDuration
        )

        let afterTick = state.tick + nominalDuration - split.afterTotal
        for (index, grace) in afterGrace.enumerated() {
            appendChordNotes(
                grace,
                score: score,
                track: track,
                state: state,
                voiceIndex: voiceIndex,
                chordStartTick: afterTick + split.afterEach * index,
                nominalDuration: split.afterEach
            )
        }
    }

    static func appendTwoChordTremoloWithGraceNotes(
        _ firstChord: XMLNode,
        secondChord: XMLNode,
        score: ScoreData,
        track: TrackData,
        state: VoiceState,
        voiceIndex: Int,
        nominalDuration: Int
    ) {
        let beforeGrace = state.pendingGraceChords.filter { !isGraceAfterChord($0) }
        var beforeTotal = 0
        var beforeEach = 0
        if !beforeGrace.isEmpty, nominalDuration > 1 {
            beforeTotal = min(nominalDuration - 1, max(1, nominalDuration / 8))
            beforeEach = max(1, beforeTotal / beforeGrace.count)
            beforeTotal = beforeEach * beforeGrace.count
        }
        for (index, grace) in beforeGrace.enumerated() {
            appendChordNotes(
                grace,
                score: score,
                track: track,
                state: state,
                voiceIndex: voiceIndex,
                chordStartTick: state.tick + beforeEach * index,
                nominalDuration: beforeEach
            )
        }
        appendTwoChordTremoloNotes(
            firstChord,
            secondChord: secondChord,
            score: score,
            track: track,
            state: state,
            voiceIndex: voiceIndex,
            chordStartTick: state.tick + beforeTotal,
            nominalDuration: max(1, nominalDuration - beforeTotal)
        )
    }

    static func appendChordNotes(
        _ chord: XMLNode,
        score: ScoreData,
        track: TrackData,
        state: VoiceState,
        voiceIndex: Int,
        chordStartTick: Int,
        nominalDuration: Int
    ) {
        appendChordNotesWithTimings(
            chord,
            score: score,
            track: track,
            state: state,
            voiceIndex: voiceIndex,
            chordStartTick: chordStartTick,
            nominalDuration: nominalDuration,
            timings: eventTimings(
                chord,
                track: track,
                chordStartTick: chordStartTick,
                nominalDuration: nominalDuration,
                division: score.division
            )
        )
    }

    static func appendChordNotesWithTimings(
        _ chord: XMLNode,
        score: ScoreData,
        track: TrackData,
        state: VoiceState,
        voiceIndex: Int,
        chordStartTick: Int,
        nominalDuration: Int,
        timings: [EventTiming]
    ) {
        let performance = chordPerformance(chord)
        let gateTimePercent = clamped(
            track.gateTimePercent * performance.gateTimePercent / 100,
            1,
            1000
        )
        let notes = children(chord, "Note")
        let arpeggio = isPlayableArpeggio(chord)
        for (noteIndex, note) in notes.enumerated() {
            let xmlPitch = intText(firstChild(note, "pitch"), -1)
            if xmlPitch < 0 || intText(firstChild(note, "play"), 1) == 0 { continue }
            let tuning = noteTuningCents(note)
            let baseVelocity = clamped(
                noteVelocity(note, inheritedVelocity: state.velocity) + performance.velocityOffset,
                1,
                127
            )
            let tiePrev = hasTieEndpoint(note, endpoint: "prev")
            let tieNext = hasTieEndpoint(note, endpoint: "next")
            let arpeggioOffset = arpeggio
                ? arpeggioOffsetTicks(
                    chord,
                    noteIndex: noteIndex,
                    noteCount: notes.count,
                    nominalDuration: nominalDuration,
                    division: score.division,
                    bpm: state.bpm
                )
                : 0
            let noteTimings = noteEventTimings(
                note,
                track: track,
                chordStartTick: chordStartTick,
                nominalDuration: nominalDuration,
                division: score.division,
                fallback: timings,
                noteIndex: noteIndex,
                xmlPitch: xmlPitch
            )

            for timing in noteTimings {
                let startTick = chordStartTick + timing.offsetTicks + arpeggioOffset
                let pitchShift = pitchShiftAt(track, tick: startTick)
                let eventPitch = Double(xmlPitch + pitchShift) + timing.pitchDelta
                let normalized = normalizeMIDXPitchCents(pitch: eventPitch, cents: tuning)
                let nativePitch = clamped(javaRound(eventPitch), 0, 127)
                let endTick = max(startTick + 1, startTick + timing.lengthTicks)
                let velocity = clamped(
                    baseVelocity
                        + hairpinVelocityOffset(track, tick: startTick)
                        + playbackVelocityOffset(track, tick: startTick),
                    1,
                    127
                )
                let effectiveGate = playbackGateTimePercent(
                    track,
                    tick: startTick,
                    baseGateTimePercent: gateTimePercent
                )
                let key = TieKey(
                    staffID: track.staffID,
                    voiceIndex: voiceIndex,
                    pitch: xmlPitch,
                    tuning: Double(javaRound(tuning * 1000)) / 1000
                )

                if tiePrev {
                    if let active = state.activeTies[key] {
                        active.endTick = max(active.endTick, endTick)
                        if !tieNext {
                            state.activeTies.removeValue(forKey: key)
                            emitPlayback(track, score: score, playback: active)
                        }
                        continue
                    }
                    if !tieNext { continue }
                }

                let playback = NotePlayback(
                    startTick: startTick,
                    endTick: endTick,
                    pitch: normalized.pitch,
                    nativePitch: nativePitch,
                    cents: normalized.cents,
                    velocity: velocity,
                    gateTimePercent: effectiveGate
                )
                if tieNext {
                    state.activeTies[key] = playback
                } else {
                    emitPlayback(track, score: score, playback: playback)
                }
            }
        }
    }

    static func appendTwoChordTremoloNotes(
        _ firstChord: XMLNode,
        secondChord: XMLNode,
        score: ScoreData,
        track: TrackData,
        state: VoiceState,
        voiceIndex: Int,
        chordStartTick: Int,
        nominalDuration: Int
    ) {
        let unit = tremoloUnitTicks(
            tremoloSubtype(firstChild(firstChord, "Tremolo")),
            division: score.division
        )
        var offset = 0
        var index = 0
        while offset < nominalDuration {
            let length = min(max(1, unit), nominalDuration - offset)
            appendChordNotesWithTimings(
                index.isMultiple(of: 2) ? firstChord : secondChord,
                score: score,
                track: track,
                state: state,
                voiceIndex: voiceIndex,
                chordStartTick: chordStartTick + offset,
                nominalDuration: length,
                timings: singleEventTiming(length)
            )
            offset += length
            index += 1
        }
    }

    static func noteEventTimings(
        _ note: XMLNode,
        track: TrackData,
        chordStartTick: Int,
        nominalDuration: Int,
        division: Int,
        fallback: [EventTiming],
        noteIndex: Int,
        xmlPitch: Int
    ) -> [EventTiming] {
        if let bend = bendEventTimings(note, nominalDuration: nominalDuration) { return bend }
        if let guitarBend = guitarBendEventTimings(
            track,
            chordStartTick: chordStartTick,
            nominalDuration: nominalDuration,
            noteIndex: noteIndex,
            xmlPitch: xmlPitch
        ) { return guitarBend }
        if let glissando = glissandoEventTimings(
            track,
            chordStartTick: chordStartTick,
            nominalDuration: nominalDuration,
            division: division,
            noteIndex: noteIndex,
            xmlPitch: xmlPitch
        ) { return glissando }
        if let vibrato = vibratoEventTimings(
            track,
            chordStartTick: chordStartTick,
            nominalDuration: nominalDuration,
            division: division
        ) { return vibrato }
        return fallback
    }

    static func bendEventTimings(_ note: XMLNode, nominalDuration: Int) -> [EventTiming]? {
        guard let bend = firstChild(note, "Bend"), intText(firstChild(bend, "play"), 1) != 0 else {
            return nil
        }
        var points = children(bend, "point").map {
            BendPoint(
                time: clamped(intAttribute($0, "time", 0), 0, 60),
                pitchDelta: Double(intAttribute($0, "pitch", 0)) / 50
            )
        }
        guard !points.isEmpty else { return nil }
        points.sort { $0.time < $1.time }
        if points.count == 1 {
            return repeatedPitchTiming(
                points[0].pitchDelta,
                nominalDuration: nominalDuration,
                unitTicks: nominalDuration
            )
        }

        var result: [EventTiming] = []
        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]
            if end.time <= start.time { continue }
            let startTick = javaRound(Double(nominalDuration * start.time) / 60)
            let endTick = javaRound(Double(nominalDuration * end.time) / 60)
            let span = max(1, endTick - startTick)
            let slices = clamped(Int(ceil(abs(end.pitchDelta - start.pitchDelta) * 2)), 1, 8)
            var sliceOffset = startTick
            for slice in 0..<slices {
                let nextOffset = startTick + javaRound(Double(span * (slice + 1)) / Double(slices))
                let progress = slices <= 1 ? 0 : Double(slice) / Double(slices - 1)
                result.append(
                    EventTiming(
                        offsetTicks: sliceOffset,
                        lengthTicks: max(1, nextOffset - sliceOffset),
                        pitchDelta: start.pitchDelta + (end.pitchDelta - start.pitchDelta) * progress
                    )
                )
                sliceOffset = nextOffset
            }
        }
        if let last = points.last {
            let lastTick = javaRound(Double(nominalDuration * last.time) / 60)
            if lastTick < nominalDuration {
                result.append(
                    EventTiming(
                        offsetTicks: lastTick,
                        lengthTicks: nominalDuration - lastTick,
                        pitchDelta: last.pitchDelta
                    )
                )
            }
        }
        return result.isEmpty ? nil : result
    }

    static func guitarBendEventTimings(
        _ track: TrackData,
        chordStartTick: Int,
        nominalDuration: Int,
        noteIndex: Int,
        xmlPitch: Int
    ) -> [EventTiming]? {
        guard nominalDuration > 1 else { return nil }
        for range in track.guitarBendRanges
        where range.startTick == chordStartTick && range.noteIndex == noteIndex && range.sourcePitch == xmlPitch {
            var totalDelta = Double(range.targetPitch - range.sourcePitch)
                + (range.targetCents - range.sourceCents) / 100
            let type = range.type.lowercased()
            if abs(totalDelta) < 0.000_001, type.contains("slight") { totalDelta = 0.5 }
            if abs(totalDelta) < 0.000_001, type.contains("dip") || type.contains("scoop") { totalDelta = -1 }
            if abs(totalDelta) < 0.000_001 { return nil }

            let activeDuration = range.endTick > range.startTick
                ? min(nominalDuration, range.endTick - range.startTick)
                : nominalDuration
            let startFactor = clampFactor(range.startFactor)
            var endFactor = clampFactor(range.endFactor)
            if endFactor < startFactor { endFactor = startFactor }
            if type.contains("dip") {
                let targetFactor = range.hasTargetFactor
                    ? clampFactor(range.targetFactor) : (startFactor + endFactor) / 2
                return bendDipTimings(
                    targetDelta: -abs(totalDelta),
                    activeDuration: activeDuration,
                    nominalDuration: nominalDuration,
                    startFactor: startFactor,
                    targetFactor: targetFactor,
                    endFactor: endFactor
                )
            }
            if type.contains("scoop") {
                return bendScoopTimings(
                    startDelta: -abs(totalDelta),
                    activeDuration: activeDuration,
                    nominalDuration: nominalDuration,
                    startFactor: startFactor,
                    endFactor: endFactor
                )
            }
            return bendRampTimings(
                totalDelta: totalDelta,
                activeDuration: activeDuration,
                nominalDuration: nominalDuration,
                startFactor: startFactor,
                endFactor: endFactor
            )
        }
        return nil
    }

    static func bendRampTimings(
        totalDelta: Double,
        activeDuration: Int,
        nominalDuration: Int,
        startFactor: Double,
        endFactor: Double
    ) -> [EventTiming]? {
        var result: [EventTiming] = []
        let rampStart = min(activeDuration - 1, max(0, javaRound(Double(activeDuration) * startFactor)))
        let rampEnd = min(
            activeDuration,
            max(rampStart + 1, javaRound(Double(activeDuration) * endFactor))
        )
        if rampStart > 0 {
            result.append(EventTiming(offsetTicks: 0, lengthTicks: rampStart, pitchDelta: 0))
        }
        let slices = clamped(Int(ceil(abs(totalDelta) * 2)), 1, 8)
        var offset = rampStart
        for slice in 0..<slices where offset < rampEnd {
            let next = rampStart + javaRound(Double((rampEnd - rampStart) * (slice + 1)) / Double(slices))
            result.append(
                EventTiming(
                    offsetTicks: offset,
                    lengthTicks: max(1, next - offset),
                    pitchDelta: totalDelta * Double(slice + 1) / Double(slices)
                )
            )
            offset = next
        }
        if rampEnd < nominalDuration {
            result.append(
                EventTiming(
                    offsetTicks: rampEnd,
                    lengthTicks: nominalDuration - rampEnd,
                    pitchDelta: totalDelta
                )
            )
        }
        return result.isEmpty ? nil : result
    }

    static func bendDipTimings(
        targetDelta: Double,
        activeDuration: Int,
        nominalDuration: Int,
        startFactor: Double,
        targetFactor: Double,
        endFactor: Double
    ) -> [EventTiming]? {
        if activeDuration <= 2 {
            return bendRampTimings(
                totalDelta: targetDelta,
                activeDuration: activeDuration,
                nominalDuration: nominalDuration,
                startFactor: startFactor,
                endFactor: endFactor
            )
        }
        let start = min(activeDuration - 2, max(0, javaRound(Double(activeDuration) * startFactor)))
        let target = min(
            activeDuration - 1,
            max(start + 1, javaRound(Double(activeDuration) * targetFactor))
        )
        let end = min(activeDuration, max(target + 1, javaRound(Double(activeDuration) * endFactor)))
        var result: [EventTiming] = []
        if start > 0 { result.append(EventTiming(offsetTicks: 0, lengthTicks: start, pitchDelta: 0)) }
        result.append(EventTiming(offsetTicks: start, lengthTicks: max(1, target - start), pitchDelta: targetDelta))
        result.append(EventTiming(offsetTicks: target, lengthTicks: max(1, end - target), pitchDelta: 0))
        if end < nominalDuration {
            result.append(EventTiming(offsetTicks: end, lengthTicks: nominalDuration - end, pitchDelta: 0))
        }
        return result
    }

    static func bendScoopTimings(
        startDelta: Double,
        activeDuration: Int,
        nominalDuration: Int,
        startFactor: Double,
        endFactor: Double
    ) -> [EventTiming] {
        if activeDuration <= 1 {
            return repeatedPitchTiming(
                startDelta,
                nominalDuration: nominalDuration,
                unitTicks: nominalDuration
            )
        }
        let holdEnd = max(1, min(activeDuration - 1, javaRound(Double(activeDuration) * startFactor)))
        let settleEnd = min(
            activeDuration,
            max(holdEnd + 1, javaRound(Double(activeDuration) * endFactor))
        )
        var result = [
            EventTiming(offsetTicks: 0, lengthTicks: holdEnd, pitchDelta: startDelta),
            EventTiming(offsetTicks: holdEnd, lengthTicks: max(1, settleEnd - holdEnd), pitchDelta: 0),
        ]
        if settleEnd < nominalDuration {
            result.append(
                EventTiming(
                    offsetTicks: settleEnd,
                    lengthTicks: nominalDuration - settleEnd,
                    pitchDelta: 0
                )
            )
        }
        return result
    }
}

private extension MuseScoreConverter {
    static func glissandoEventTimings(
        _ track: TrackData,
        chordStartTick: Int,
        nominalDuration: Int,
        division: Int,
        noteIndex: Int,
        xmlPitch: Int
    ) -> [EventTiming]? {
        for range in track.glissandoRanges
        where range.startTick == chordStartTick && range.noteIndex == noteIndex && range.sourcePitch == xmlPitch {
            let totalDelta = Double(range.targetPitch - range.sourcePitch)
                + (range.targetCents - range.sourceCents) / 100
            if abs(totalDelta) < 0.000_001 { return nil }
            let activeDuration = range.endTick > range.startTick
                ? min(nominalDuration, range.endTick - range.startTick)
                : nominalDuration
            if range.continuous {
                let slices = clamped(Int(ceil(abs(totalDelta) * 2)), 2, 16)
                var result: [EventTiming] = []
                var offset = 0
                for index in 0..<slices {
                    let next = javaRound(Double(activeDuration * (index + 1)) / Double(slices))
                    result.append(
                        EventTiming(
                            offsetTicks: offset,
                            lengthTicks: max(1, next - offset),
                            pitchDelta: totalDelta * Double(index) / Double(slices)
                        )
                    )
                    offset = next
                }
                if activeDuration < nominalDuration {
                    result.append(
                        EventTiming(
                            offsetTicks: activeDuration,
                            lengthTicks: nominalDuration - activeDuration,
                            pitchDelta: totalDelta
                        )
                    )
                }
                return result
            }
            return discreteGlissandoTimings(
                range,
                totalDelta: totalDelta,
                activeDuration: activeDuration,
                nominalDuration: nominalDuration,
                division: division
            )
        }
        return nil
    }

    static func discreteGlissandoTimings(
        _ range: PitchRange,
        totalDelta: Double,
        activeDuration: Int,
        nominalDuration: Int,
        division: Int
    ) -> [EventTiming] {
        let direction = totalDelta >= 0 ? 1 : -1
        let semitones = max(1, Int(floor(abs(totalDelta))))
        var deltas: [Double] = []
        for step in 0..<semitones {
            let semitone = step * direction
            if range.whiteKeysOnly, !isWhiteKey(range.sourcePitch + semitone) { continue }
            if range.blackKeysOnly, isWhiteKey(range.sourcePitch + semitone) { continue }
            deltas.append(Double(semitone))
        }
        if deltas.isEmpty { deltas.append(0) }
        let unit = max(1, min(max(1, division / 16), max(1, activeDuration / deltas.count)))
        var result: [EventTiming] = []
        var offset = 0
        for index in deltas.indices where offset < activeDuration {
            let length = index == deltas.count - 1
                ? max(1, activeDuration - offset)
                : min(unit, max(1, activeDuration - offset))
            result.append(
                EventTiming(offsetTicks: offset, lengthTicks: length, pitchDelta: deltas[index])
            )
            offset += length
        }
        if activeDuration < nominalDuration {
            result.append(
                EventTiming(
                    offsetTicks: activeDuration,
                    lengthTicks: nominalDuration - activeDuration,
                    pitchDelta: totalDelta
                )
            )
        }
        return result
    }

    static func vibratoEventTimings(
        _ track: TrackData,
        chordStartTick: Int,
        nominalDuration: Int,
        division: Int
    ) -> [EventTiming]? {
        guard nominalDuration > 1 else { return nil }
        let chordEndTick = chordStartTick + nominalDuration
        for range in track.vibratoRanges
        where range.endTick > chordStartTick && range.startTick < chordEndTick {
            let activeStart = max(0, range.startTick - chordStartTick)
            let activeEnd = min(nominalDuration, range.endTick - chordStartTick)
            if activeEnd <= activeStart { continue }
            var result: [EventTiming] = []
            if activeStart > 0 {
                result.append(EventTiming(offsetTicks: 0, lengthTicks: activeStart, pitchDelta: 0))
            }
            let unit = max(
                1,
                min(max(1, division / 32), max(1, (activeEnd - activeStart) / 4))
            )
            var offset = activeStart
            var index = 0
            let semitoneWidth = range.cents / 100
            while offset < activeEnd {
                let next = min(activeEnd, offset + unit)
                let delta: Double
                if range.sawtooth {
                    delta = index % 3 == 0 ? 0 : (index % 3 == 1 ? semitoneWidth : -semitoneWidth)
                } else {
                    delta = index.isMultiple(of: 2) ? semitoneWidth : -semitoneWidth
                }
                result.append(
                    EventTiming(offsetTicks: offset, lengthTicks: max(1, next - offset), pitchDelta: delta)
                )
                offset = next
                index += 1
            }
            if activeEnd < nominalDuration {
                result.append(
                    EventTiming(
                        offsetTicks: activeEnd,
                        lengthTicks: nominalDuration - activeEnd,
                        pitchDelta: 0
                    )
                )
            }
            return result.isEmpty ? nil : result
        }
        return nil
    }

    static func isWhiteKey(_ pitch: Int) -> Bool {
        [0, 2, 4, 5, 7, 9, 11].contains(positiveModulo(pitch, 12))
    }

    static func emitPlayback(_ track: TrackData, score: ScoreData, playback: NotePlayback) {
        playback.pitch = clamped(playback.pitch, 0, 127)
        playback.nativePitch = clamped(playback.nativePitch, 0, 127)
        playback.velocity = clamped(playback.velocity, 1, 127)
        let gate = playback.gateTimePercent > 0 ? playback.gateTimePercent : track.gateTimePercent
        var endTick = gatedEndTick(
            startTick: playback.startTick,
            endTick: playback.endTick,
            gateTimePercent: gate
        )
        endTick = pedalExtendedEndTick(track, startTick: playback.startTick, endTick: endTick)
        track.events.append(
            .noteOn(
                tick: playback.startTick,
                pitch: playback.pitch,
                nativePitch: playback.nativePitch,
                velocity: playback.velocity,
                cents: playback.cents
            )
        )
        track.events.append(.noteOff(tick: endTick, nativePitch: playback.nativePitch))
        score.noteCount += 1
        if encodeCentOffset(playback.cents) != 0 { score.microtonalCount += 1 }
    }

    static func gatedEndTick(startTick: Int, endTick: Int, gateTimePercent: Int) -> Int {
        let duration = max(1, endTick - startTick)
        let gatedDuration = Int(floor(Double(duration * clamped(gateTimePercent, 1, 1000)) / 100)) - 1
        return startTick + max(1, gatedDuration)
    }

    static func eventTimings(
        _ chord: XMLNode,
        track: TrackData,
        chordStartTick: Int,
        nominalDuration: Int,
        division: Int
    ) -> [EventTiming] {
        guard let events = firstChild(chord, "Events") else {
            if let ornament = ornamentEventTimings(chord, nominalDuration: nominalDuration, division: division) {
                return ornament
            }
            if let trill = trillEventTimings(
                track,
                chordStartTick: chordStartTick,
                nominalDuration: nominalDuration,
                division: division
            ) { return trill }
            if let tremolo = tremoloEventTimings(chord, nominalDuration: nominalDuration, division: division) {
                return tremolo
            }
            if let line = chordLineEventTimings(chord, nominalDuration: nominalDuration, division: division) {
                return line
            }
            return singleEventTiming(nominalDuration)
        }

        var result = children(events, "Event").map { event in
            let ontime = doubleText(firstChild(event, "ontime"), 0)
            let length = doubleText(firstChild(event, "len"), 1000)
            let pitch = doubleText(firstChild(event, "pitch"), 0)
            return EventTiming(
                offsetTicks: javaRound(Double(nominalDuration) * ontime / 1000),
                lengthTicks: max(1, javaRound(Double(nominalDuration) * length / 1000)),
                pitchDelta: pitch
            )
        }
        if result.isEmpty { result = singleEventTiming(nominalDuration) }
        return result
    }

    static func singleEventTiming(_ nominalDuration: Int) -> [EventTiming] {
        [EventTiming(offsetTicks: 0, lengthTicks: max(1, nominalDuration), pitchDelta: 0)]
    }

    static func gracePlaybackSplit(
        mainChord: XMLNode,
        state: VoiceState,
        beforeGrace: [XMLNode],
        afterGrace: [XMLNode],
        nominalDuration: Int,
        division: Int
    ) -> GracePlaybackSplit {
        let split = GracePlaybackSplit()
        let beforeCount = beforeGrace.count
        let afterCount = afterGrace.count
        guard beforeCount + afterCount > 0, nominalDuration > 1 else { return split }

        let dots = intText(firstChild(mainChord, "dots"), 0)
        let dottedShare = javaRound(Double(nominalDuration) * fermataBaseGraceRatio(dots))
        let acciaccaturaLike = beforeCount > 1
            || (beforeCount == 1 && firstChild(beforeGrace[0], "acciaccatura") != nil)

        if beforeCount > 0 {
            if acciaccaturaLike {
                let ticksFor65msEach = max(
                    1,
                    javaRound(max(1, state.bpm) / 60 * Double(division) * 0.065 * Double(beforeCount))
                )
                split.beforeTotal = min(max(1, nominalDuration / 2), ticksFor65msEach)
            } else if afterCount > 0 {
                split.beforeTotal = javaRound(
                    Double(dottedShare) * Double(beforeCount) / Double(beforeCount + afterCount)
                )
            } else {
                split.beforeTotal = dottedShare
            }
        }
        if afterCount > 0 {
            if beforeCount > 0, !acciaccaturaLike {
                split.afterTotal = javaRound(
                    Double(dottedShare) * Double(afterCount) / Double(beforeCount + afterCount)
                )
            } else {
                split.afterTotal = dottedShare
            }
        }

        let maxGrace = max(0, nominalDuration - 1)
        let totalGrace = split.beforeTotal + split.afterTotal
        if totalGrace > maxGrace, totalGrace > 0 {
            let scale = Double(maxGrace) / Double(totalGrace)
            split.beforeTotal = max(0, javaRound(Double(split.beforeTotal) * scale))
            split.afterTotal = max(0, javaRound(Double(split.afterTotal) * scale))
        }
        split.beforeEach = beforeCount == 0 ? 0 : max(1, split.beforeTotal / beforeCount)
        split.afterEach = afterCount == 0 ? 0 : max(1, split.afterTotal / afterCount)
        split.beforeTotal = split.beforeEach * beforeCount
        split.afterTotal = split.afterEach * afterCount
        if split.beforeTotal + split.afterTotal >= nominalDuration {
            let overflow = split.beforeTotal + split.afterTotal - nominalDuration + 1
            if split.afterTotal >= overflow {
                split.afterTotal -= overflow
                split.afterEach = afterCount == 0 ? 0 : max(1, split.afterTotal / afterCount)
                split.afterTotal = split.afterEach * afterCount
            } else {
                split.beforeTotal = max(0, split.beforeTotal - overflow)
                split.beforeEach = beforeCount == 0 ? 0 : max(1, split.beforeTotal / beforeCount)
                split.beforeTotal = split.beforeEach * beforeCount
            }
        }
        return split
    }

    static func fermataBaseGraceRatio(_ dots: Int) -> Double {
        dots == 1 ? 0.667 : (dots >= 2 ? 0.571 : 0.5)
    }

    static func isGraceChord(_ chord: XMLNode) -> Bool {
        firstChild(chord, "acciaccatura") != nil
            || firstChild(chord, "appoggiatura") != nil
            || firstChild(chord, "grace4") != nil
            || firstChild(chord, "grace16") != nil
            || firstChild(chord, "grace32") != nil
            || isGraceAfterChord(chord)
    }

    static func isGraceAfterChord(_ chord: XMLNode) -> Bool {
        firstChild(chord, "grace8after") != nil
            || firstChild(chord, "grace16after") != nil
            || firstChild(chord, "grace32after") != nil
    }

    static func chordPerformance(_ chord: XMLNode) -> ChordPerformance {
        var gateTimePercent = 100
        var velocityOffset = 0
        for articulation in children(chord, "Articulation") {
            if intText(firstChild(articulation, "play"), 1) == 0 { continue }
            let lower = articulationName(articulation).lowercased()
            if lower.contains("staccatissimo") {
                gateTimePercent = min(gateTimePercent, 25)
            } else if lower.contains("staccato") {
                gateTimePercent = min(gateTimePercent, 50)
            } else if lower.contains("portato") || lower.contains("tenutostaccato") {
                gateTimePercent = min(gateTimePercent, 75)
            }
            if lower.contains("marcato") || lower.contains("sforzato") {
                velocityOffset += 22
            } else if lower.contains("accent") {
                velocityOffset += lower.contains("soft") ? 6 : 14
            }
        }
        return ChordPerformance(
            gateTimePercent: gateTimePercent,
            velocityOffset: clamped(velocityOffset, -64, 64)
        )
    }

    static func articulationName(_ articulation: XMLNode) -> String {
        let subtype = text(firstChild(articulation, "subtype"))
        return subtype.isEmpty ? articulation.attribute("name") : subtype
    }

    static func ornamentEventTimings(
        _ chord: XMLNode,
        nominalDuration: Int,
        division: Int
    ) -> [EventTiming]? {
        for articulation in children(chord, "Articulation") {
            if intText(firstChild(articulation, "play"), 1) == 0 { continue }
            if let pattern = ornamentPattern(articulationName(articulation)) {
                return patternEventTimings(
                    ornamentPitchDeltas(pattern.pitchDeltas, articulation: articulation),
                    repeatPattern: pattern.repeats,
                    sustainLast: pattern.sustainLast,
                    nominalDuration: nominalDuration,
                    unitTicks: pattern.unitTicks(division: division)
                )
            }
        }
        return nil
    }

    static func ornamentPitchDeltas(_ source: [Int], articulation: XMLNode) -> [Int] {
        let above = ornamentIntervalSemitones(
            text(firstChild(articulation, "intervalAbove")),
            fallback: 1
        )
        let below = -ornamentIntervalSemitones(
            text(firstChild(articulation, "intervalBelow")),
            fallback: 1
        )
        var result = source.map { value in
            value > 0 ? above * value : (value < 0 ? -below * value : 0)
        }
        if boolText(firstChild(articulation, "startOnUpperNote"), false),
           result.count >= 2,
           result[0] == 0,
           result[1] > 0
        {
            result[0] = result[1]
            result[1] = 0
        }
        return result
    }

    static func ornamentIntervalSemitones(_ value: String, fallback: Int) -> Int {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        let lower = value.lowercased()
        var base: Int
        if lower.contains("octave") {
            base = 12
        } else if lower.contains("seventh") {
            base = lower.contains("major") ? 11 : 10
        } else if lower.contains("sixth") {
            base = lower.contains("major") ? 9 : 8
        } else if lower.contains("fifth") {
            base = 7
        } else if lower.contains("fourth") {
            base = 5
        } else if lower.contains("third") {
            base = lower.contains("major") ? 4 : 3
        } else if lower.contains("second") {
            base = lower.contains("major") ? 2 : 1
        } else if lower.contains("unison") {
            base = 0
        } else {
            return fallback
        }
        if lower.contains("augmented") {
            base += 1
        } else if lower.contains("diminished") {
            base -= 1
        } else if lower.contains("auto") {
            base = fallback
        }
        return max(0, base)
    }
}

private extension MuseScoreConverter {
    static func tremoloEventTimings(
        _ chord: XMLNode,
        nominalDuration: Int,
        division: Int
    ) -> [EventTiming]? {
        guard let tremolo = firstChild(chord, "Tremolo"),
              intText(firstChild(tremolo, "play"), 1) != 0
        else { return nil }
        return repeatedPitchTiming(
            0,
            nominalDuration: nominalDuration,
            unitTicks: tremoloUnitTicks(tremoloSubtype(tremolo), division: division)
        )
    }

    static func trillEventTimings(
        _ track: TrackData,
        chordStartTick: Int,
        nominalDuration: Int,
        division: Int
    ) -> [EventTiming]? {
        guard nominalDuration > 1 else { return nil }
        let chordEndTick = chordStartTick + nominalDuration
        for range in track.trillRanges
        where range.endTick > chordStartTick && range.startTick < chordEndTick {
            guard let pattern = trillPattern(range.name) else { continue }
            let activeStart = max(0, range.startTick - chordStartTick)
            let activeEnd = min(nominalDuration, range.endTick - chordStartTick)
            if activeEnd <= activeStart { continue }
            var result: [EventTiming] = []
            if activeStart > 0 {
                result.append(EventTiming(offsetTicks: 0, lengthTicks: activeStart, pitchDelta: 0))
            }
            result.append(
                contentsOf: patternEventTimings(
                    pattern.pitchDeltas,
                    repeatPattern: pattern.repeats,
                    sustainLast: pattern.sustainLast,
                    nominalDuration: activeEnd - activeStart,
                    unitTicks: pattern.unitTicks(division: division)
                ).map {
                    EventTiming(
                        offsetTicks: activeStart + $0.offsetTicks,
                        lengthTicks: $0.lengthTicks,
                        pitchDelta: $0.pitchDelta
                    )
                }
            )
            if activeEnd < nominalDuration {
                result.append(
                    EventTiming(
                        offsetTicks: activeEnd,
                        lengthTicks: nominalDuration - activeEnd,
                        pitchDelta: 0
                    )
                )
            }
            return result.isEmpty ? nil : result
        }
        return nil
    }

    static func trillPattern(_ name: String) -> OrnamentPattern? {
        let lower = name.lowercased()
        if lower.isEmpty || lower.contains("trill") {
            return OrnamentPattern([0, 1], repeats: true, sustainLast: true, denominator: 32)
        }
        if lower.contains("upprall") {
            return OrnamentPattern([-1, 0, 1, 0], repeats: true, sustainLast: true, denominator: 16)
        }
        if lower.contains("downprall") || lower.contains("downmordent") {
            return OrnamentPattern([1, 0, 1, 0, -1, 0], repeats: true, sustainLast: true, denominator: 16)
        }
        if lower.contains("prallprall") {
            return OrnamentPattern([0, 1], repeats: true, sustainLast: true, denominator: 16)
        }
        return ornamentPattern("ornament\(name)")
    }

    static func tremoloSubtype(_ tremolo: XMLNode?) -> String {
        text(firstChild(tremolo, "subtype")).lowercased()
    }

    static func tremoloUnitTicks(_ subtype: String, division: Int) -> Int {
        var denominator = 16
        let numeric = parseInt(subtype, -1)
        if numeric == 7 || numeric == 2 || subtype.contains("32") || subtype.contains("three")
            || subtype.contains("r32") || subtype.contains("c32")
        {
            denominator = 32
        } else if numeric == 8 || numeric == 3 || subtype.contains("64") || subtype.contains("four")
            || subtype.contains("r64") || subtype.contains("c64")
        {
            denominator = 64
        } else if numeric == 5 || numeric == 0 || subtype.contains("8") || subtype.contains("one")
            || subtype.contains("r8") || subtype.contains("c8")
        {
            denominator = 8
        }
        return max(1, javaRound(Double(division) * 4 / Double(denominator)))
    }

    static func isTwoChordTremolo(_ chord: XMLNode) -> Bool {
        guard let tremolo = firstChild(chord, "Tremolo"),
              intText(firstChild(tremolo, "play"), 1) != 0
        else { return false }
        let subtype = tremoloSubtype(tremolo)
        let numeric = parseInt(subtype, -1)
        return numeric >= 5 || subtype.hasPrefix("c") || subtype.contains("two") || subtype.contains("change")
    }

    static func twoChordTremoloPartnerIndex(_ voice: XMLNode, chordIndex: Int) -> Int {
        guard voice.children.indices.contains(chordIndex),
              isTwoChordTremolo(voice.children[chordIndex])
        else { return -1 }
        let nextIndex = chordIndex + 1
        guard voice.children.indices.contains(nextIndex) else { return -1 }
        let next = voice.children[nextIndex]
        return next.name == "Chord" && !isGraceChord(next) ? nextIndex : -1
    }

    static func ornamentPattern(_ name: String) -> OrnamentPattern? {
        let lower = name.lowercased()
        guard lower.contains("ornament") else { return nil }
        if lower.contains("turninverted") || lower.contains("turnslash") {
            return OrnamentPattern([-1, 0, 1, 0], repeats: false, sustainLast: true, denominator: 32)
        }
        if lower.contains("turn") {
            return OrnamentPattern([1, 0, -1, 0], repeats: false, sustainLast: true, denominator: 32)
        }
        if lower.contains("shorttrill") {
            return OrnamentPattern([0, 1, 0], repeats: false, sustainLast: true, denominator: 32)
        }
        if lower.contains("trill") || lower.contains("tremblement") {
            return OrnamentPattern([0, 1], repeats: true, sustainLast: true, denominator: 32)
        }
        if lower.contains("prallmordent") {
            return OrnamentPattern([1, 0, -1, 0], repeats: false, sustainLast: true, denominator: 32)
        }
        if lower.contains("mordent") && !lower.contains("upmordent") && !lower.contains("downmordent") {
            return OrnamentPattern([0, -1, 0], repeats: false, sustainLast: true, denominator: 32)
        }
        if lower.contains("lineprall") {
            return OrnamentPattern([1, 0], repeats: true, sustainLast: true, denominator: 16)
        }
        if lower.contains("upprall") || lower.contains("upmordent") {
            return OrnamentPattern([-1, 0, 1, 0], repeats: true, sustainLast: true, denominator: 16)
        }
        if lower.contains("downmordent") {
            return OrnamentPattern([1, 0, 1, 0, -1, 0], repeats: true, sustainLast: true, denominator: 16)
        }
        if lower.contains("pralldown") {
            return OrnamentPattern([1, 0, 1, 0, -1, 0, 0, 0], repeats: true, sustainLast: true, denominator: 16)
        }
        if lower.contains("prallup") {
            return OrnamentPattern([1, 0, 1, 0], repeats: true, sustainLast: true, denominator: 16)
        }
        if lower.contains("precompmordentupperprefix") {
            return OrnamentPattern([1, 1, 1, 0, 1, 0], repeats: true, sustainLast: true, denominator: 16)
        }
        return nil
    }

    static func patternEventTimings(
        _ pitchDeltas: [Int],
        repeatPattern: Bool,
        sustainLast: Bool,
        nominalDuration: Int,
        unitTicks: Int
    ) -> [EventTiming] {
        guard !pitchDeltas.isEmpty, nominalDuration > 1 else { return singleEventTiming(nominalDuration) }
        if repeatPattern {
            var result: [EventTiming] = []
            var offset = 0
            var index = 0
            while offset < nominalDuration {
                let length = min(max(1, unitTicks), nominalDuration - offset)
                result.append(
                    EventTiming(
                        offsetTicks: offset,
                        lengthTicks: length,
                        pitchDelta: Double(pitchDeltas[index % pitchDeltas.count])
                    )
                )
                offset += length
                index += 1
            }
            return result
        }

        var result: [EventTiming] = []
        var offset = 0
        let step = max(1, min(max(1, unitTicks), nominalDuration / pitchDeltas.count))
        for index in pitchDeltas.indices {
            let length = index == pitchDeltas.count - 1 && sustainLast
                ? max(1, nominalDuration - offset)
                : min(step, max(1, nominalDuration - offset))
            result.append(
                EventTiming(
                    offsetTicks: offset,
                    lengthTicks: length,
                    pitchDelta: Double(pitchDeltas[index])
                )
            )
            offset += length
            if offset >= nominalDuration { break }
        }
        return result.isEmpty ? singleEventTiming(nominalDuration) : result
    }

    static func chordLineEventTimings(
        _ chord: XMLNode,
        nominalDuration: Int,
        division: Int
    ) -> [EventTiming]? {
        guard let chordLine = firstChild(chord, "ChordLine"),
              intText(firstChild(chordLine, "play"), 1) != 0,
              nominalDuration > 1
        else { return nil }
        let subtype = text(firstChild(chordLine, "subtype")).lowercased()
        let numeric = parseInt(subtype, -1)
        let amount: Double
        let settlesToMain: Bool
        if numeric == 1 || subtype.contains("fall") {
            amount = -2
            settlesToMain = false
        } else if numeric == 2 || subtype.contains("doit") {
            amount = 2
            settlesToMain = false
        } else if numeric == 3 || subtype.contains("plop") {
            amount = 2
            settlesToMain = true
        } else if numeric == 4 || subtype.contains("scoop") {
            amount = -2
            settlesToMain = true
        } else {
            return nil
        }
        let effect = max(1, min(max(1, division / 4), max(1, nominalDuration / 3)))
        if settlesToMain {
            var result = [EventTiming(offsetTicks: 0, lengthTicks: effect, pitchDelta: amount)]
            if effect < nominalDuration {
                result.append(
                    EventTiming(offsetTicks: effect, lengthTicks: nominalDuration - effect, pitchDelta: 0)
                )
            }
            return result
        }
        let main = max(1, nominalDuration - effect)
        return [
            EventTiming(offsetTicks: 0, lengthTicks: main, pitchDelta: 0),
            EventTiming(offsetTicks: main, lengthTicks: nominalDuration - main, pitchDelta: amount),
        ]
    }

    static func repeatedPitchTiming(
        _ pitchDelta: Double,
        nominalDuration: Int,
        unitTicks: Int
    ) -> [EventTiming] {
        var result: [EventTiming] = []
        var offset = 0
        while offset < nominalDuration {
            let length = min(max(1, unitTicks), nominalDuration - offset)
            result.append(
                EventTiming(offsetTicks: offset, lengthTicks: length, pitchDelta: pitchDelta)
            )
            offset += length
        }
        return result.isEmpty ? singleEventTiming(nominalDuration) : result
    }

    static func isPlayableArpeggio(_ chord: XMLNode) -> Bool {
        guard let arpeggio = firstChild(chord, "Arpeggio"),
              intText(firstChild(arpeggio, "play"), 1) != 0
        else { return false }
        let subtype = text(firstChild(arpeggio, "subtype"))
        return parseInt(subtype, -1) != 3 && !subtype.lowercased().contains("bracket")
    }

    static func arpeggioOffsetTicks(
        _ chord: XMLNode,
        noteIndex: Int,
        noteCount: Int,
        nominalDuration: Int,
        division: Int,
        bpm: Double
    ) -> Int {
        guard noteCount > 1 else { return 0 }
        let arpeggio = firstChild(chord, "Arpeggio")
        let subtype = text(firstChild(arpeggio, "subtype")).lowercased()
        let numericSubtype = parseInt(subtype, -1)
        let down = numericSubtype == 2 || numericSubtype == 5 || subtype.contains("down")
        let order = down ? noteCount - noteIndex - 1 : noteIndex
        let stretch = max(0.1, doubleText(firstChild(arpeggio, "timeStretch"), 1))
        let userLength = max(0, doubleText(firstChild(arpeggio, "userLen1"), 0))
        let defaultStep = max(1, min(max(1, division / 32), max(1, nominalDuration / (noteCount * 8))))
        var step: Int
        if userLength > 0 {
            let ticks = max(1, javaRound(userLength * max(1, bpm) * Double(division) / 60))
            step = max(1, ticks / max(1, noteCount - 1))
        } else {
            step = max(1, javaRound(Double(defaultStep) * stretch))
        }
        step = min(step, max(1, nominalDuration / max(2, noteCount)))
        return order * step
    }

    static func pitchShiftAt(_ track: TrackData, tick: Int) -> Int {
        track.ottavaRanges.reduce(into: 0) { shift, range in
            if tick >= range.startTick, tick < range.endTick { shift += range.semitones }
        }
    }

    static func playbackVelocityOffset(_ track: TrackData, tick: Int) -> Int {
        clamped(
            track.playbackRanges.reduce(into: 0) { offset, range in
                if tick >= range.startTick, tick < range.endTick { offset += range.velocityOffset }
            },
            -64,
            64
        )
    }

    static func playbackGateTimePercent(
        _ track: TrackData,
        tick: Int,
        baseGateTimePercent: Int
    ) -> Int {
        track.playbackRanges.reduce(baseGateTimePercent) { gate, range in
            tick >= range.startTick && tick < range.endTick
                ? clamped(gate * range.gateTimePercent / 100, 1, 1000)
                : gate
        }
    }

    static func hairpinVelocityOffset(_ track: TrackData, tick: Int) -> Int {
        var offset = 0
        for range in track.hairpins where tick >= range.startTick && tick <= range.endTick {
            let span = max(1, range.endTick - range.startTick)
            let progress = Double(tick - range.startTick) / Double(span)
            offset += javaRound(Double(range.velocityDelta) * progress)
        }
        return clamped(offset, -64, 64)
    }

    static func noteVelocity(_ note: XMLNode, inheritedVelocity: Int) -> Int {
        let velocityElement = firstChild(note, "velocity")
        let velocityTypeElement = firstChild(note, "veloType")
        let velocityOffsetElement = firstChild(note, "veloOffset")
        var velocity = inheritedVelocity
        if let velocityElement {
            velocity = intText(velocityElement, velocity)
        } else if let velocityOffsetElement {
            velocity += intText(velocityOffsetElement, 0)
        }
        if text(velocityTypeElement).caseInsensitiveCompare("offset") == .orderedSame,
           let velocityElement
        {
            velocity = inheritedVelocity + intText(velocityElement, 0)
        }
        return clamped(velocity, 1, 127)
    }

    static func noteTuningCents(_ note: XMLNode) -> Double {
        if let offset = firstChild(note, "centOffset") { return doubleText(offset, 0) }
        return doubleText(firstChild(note, "tuning"), 0)
    }

    static func hasTieEndpoint(_ note: XMLNode, endpoint: String) -> Bool {
        children(note, "Spanner").contains {
            $0.attribute("type") == "Tie" && firstChild($0, endpoint) != nil
        }
    }

    static func fermataMultiplier(_ fermata: XMLNode) -> Double {
        let subtype = text(firstChild(fermata, "subtype")).lowercased()
        if subtype.contains("verylong") { return 3 }
        if subtype.contains("long") { return 2 }
        if subtype.contains("short") { return 1.25 }
        return 1.5
    }
}

private extension MuseScoreConverter {
    static func collectPlaybackSpanners(
        _ staffBody: XMLNode,
        track: TrackData,
        timeline: MeasureTimeline,
        division: Int
    ) {
        var activeHairpins: [String: HairpinRange] = [:]
        var closedHairpins: [HairpinRange] = []
        let measures = children(staffBody, "Measure")
        for slot in timeline.slots where measures.indices.contains(slot.measureIndex) {
            let measure = measures[slot.measureIndex]
            scanMeasureLevelSpanners(
                measure,
                activeHairpins: &activeHairpins,
                closedHairpins: &closedHairpins,
                measureStart: slot.outputStart,
                measureTicks: slot.length,
                division: division
            )
            for voice in children(measure, "voice") {
                scanVoiceSpanners(
                    voice,
                    track: track,
                    activeHairpins: &activeHairpins,
                    closedHairpins: &closedHairpins,
                    slot: slot,
                    division: division
                )
            }
        }
        track.hairpins.append(contentsOf: closedHairpins)
        for range in activeHairpins.values {
            if range.endTick <= range.startTick { range.endTick = range.startTick + defaultDivision }
            track.hairpins.append(range)
        }
    }

    static func scanMeasureLevelSpanners(
        _ measure: XMLNode,
        activeHairpins: inout [String: HairpinRange],
        closedHairpins: inout [HairpinRange],
        measureStart: Int,
        measureTicks: Int,
        division: Int
    ) {
        for child in measure.children where child.name == "endSpanner" {
            closeHairpin(
                activeHairpins: &activeHairpins,
                closedHairpins: &closedHairpins,
                id: child.attribute("id"),
                endTick: measureStart + childLocationOffset(child, division: division, measureTicks: measureTicks)
            )
        }
    }

    static func scanVoiceSpanners(
        _ voice: XMLNode,
        track: TrackData,
        activeHairpins: inout [String: HairpinRange],
        closedHairpins: inout [HairpinRange],
        slot: MeasureSlot,
        division: Int
    ) {
        var tick = slot.outputStart
        var legacyTupletRatio = 1.0
        var legacyTupletRemaining = 0
        var tupletsByID: [String: TupletInfo] = [:]
        for (childIndex, element) in voice.children.enumerated() {
            switch element.name {
            case "Tuplet":
                if let info = parseTupletInfo(element, knownTuplets: tupletsByID) {
                    if !info.id.isEmpty {
                        tupletsByID[info.id] = info
                    } else {
                        legacyTupletRatio = info.ratio
                        legacyTupletRemaining = info.actualNotes
                    }
                }
            case "endTuplet":
                legacyTupletRatio = 1
                legacyTupletRemaining = 0
            case "tick":
                tick = slot.outputStart + max(0, fileTick(text(element)) - slot.sourceStart)
            case "location":
                tick += locationTicks(element, division: division, measureTicks: slot.length)
            case "HairPin":
                let id = element.attribute("id")
                if !id.isEmpty {
                    activeHairpins[id] = HairpinRange(
                        startTick: tick,
                        endTick: tick + slot.length,
                        velocityDelta: hairpinVelocityDelta(element)
                    )
                }
            case "Spanner":
                switch element.attribute("type") {
                case "Pedal":
                    addPedalRangeFromSpanner(
                        element,
                        track: track,
                        startTick: tick,
                        measureTicks: slot.length,
                        division: division,
                        childTag: "Pedal",
                        emitControlChange: true
                    )
                case "LetRing":
                    addPedalRangeFromSpanner(
                        element,
                        track: track,
                        startTick: tick,
                        measureTicks: slot.length,
                        division: division,
                        childTag: "LetRing",
                        emitControlChange: false
                    )
                case "PalmMute":
                    addPlaybackRangeFromSpanner(
                        element,
                        track: track,
                        startTick: tick,
                        measureTicks: slot.length,
                        division: division,
                        childTag: "PalmMute",
                        gateTimePercent: 55,
                        velocityOffset: -10
                    )
                case "Slur", "HammerOnPullOff":
                    addPlaybackRangeFromSpanner(
                        element,
                        track: track,
                        startTick: tick,
                        measureTicks: slot.length,
                        division: division,
                        childTag: element.attribute("type"),
                        gateTimePercent: 110,
                        velocityOffset: 0
                    )
                case "Vibrato":
                    addVibratoRangeFromSpanner(
                        element,
                        track: track,
                        startTick: tick,
                        measureTicks: slot.length,
                        division: division
                    )
                case "Ottava":
                    addOttavaRangeFromSpanner(
                        element,
                        track: track,
                        startTick: tick,
                        measureTicks: slot.length,
                        division: division
                    )
                case "Trill":
                    addTrillRangeFromSpanner(
                        element,
                        track: track,
                        startTick: tick,
                        measureTicks: slot.length,
                        division: division
                    )
                default:
                    break
                }
            case "endSpanner":
                closeHairpin(
                    activeHairpins: &activeHairpins,
                    closedHairpins: &closedHairpins,
                    id: element.attribute("id"),
                    endTick: tick + childLocationOffset(element, division: division, measureTicks: slot.length)
                )
            case "Rest", "Chord":
                if element.name == "Chord", isGraceChord(element) { continue }
                let ratio = tupletRatio(
                    for: element,
                    knownTuplets: tupletsByID,
                    fallbackRatio: legacyTupletRatio
                )
                let duration = max(
                    0,
                    durationTicks(
                        element,
                        division: division,
                        tupletRatio: ratio,
                        measureTicks: slot.length
                    )
                )
                if element.name == "Chord" {
                    addGlissandoRangesFromChord(
                        voice,
                        chordIndex: childIndex,
                        chord: element,
                        track: track,
                        startTick: tick,
                        measureTicks: slot.length,
                        division: division
                    )
                    addGuitarBendRangesFromChord(
                        voice,
                        chordIndex: childIndex,
                        chord: element,
                        track: track,
                        startTick: tick,
                        nominalDuration: duration,
                        measureTicks: slot.length,
                        division: division
                    )
                }
                tick += duration
                if legacyTupletRemaining > 0, firstChild(element, "Tuplet") == nil {
                    legacyTupletRemaining -= 1
                    if legacyTupletRemaining <= 0 { legacyTupletRatio = 1 }
                }
            default:
                break
            }
        }
    }

    static func addGlissandoRangesFromChord(
        _ voice: XMLNode,
        chordIndex: Int,
        chord: XMLNode,
        track: TrackData,
        startTick: Int,
        measureTicks: Int,
        division: Int
    ) {
        let notes = children(chord, "Note")
        for (noteIndex, note) in notes.enumerated() {
            let sourcePitch = intText(firstChild(note, "pitch"), -1)
            if sourcePitch < 0 { continue }
            for spanner in children(note, "Spanner") {
                guard spanner.attribute("type") == "Glissando",
                      firstChild(spanner, "prev") == nil,
                      let glissando = firstChild(spanner, "Glissando"),
                      let next = firstChild(spanner, "next"),
                      intText(firstChild(glissando, "play"), 1) != 0,
                      let targetNote = glissandoTargetNote(
                        voice,
                        chordIndex: chordIndex,
                        noteIndex: noteIndex
                      )
                else { continue }
                var length = locationTicks(
                    firstChild(next, "location"),
                    division: division,
                    measureTicks: measureTicks
                )
                if length <= 0 { length = max(1, division) }
                let style = text(firstChild(glissando, "glissandoStyle")).lowercased()
                track.glissandoRanges.append(
                    PitchRange(
                        startTick: startTick,
                        endTick: startTick + max(1, length),
                        noteIndex: noteIndex,
                        sourcePitch: sourcePitch,
                        sourceCents: noteTuningCents(note),
                        targetPitch: intText(firstChild(targetNote, "pitch"), sourcePitch),
                        targetCents: noteTuningCents(targetNote),
                        continuous: style.contains("portamento") || style.contains("continuous"),
                        whiteKeysOnly: style.contains("white"),
                        blackKeysOnly: style.contains("black")
                    )
                )
            }
        }
    }

    static func glissandoTargetNote(
        _ voice: XMLNode,
        chordIndex: Int,
        noteIndex: Int
    ) -> XMLNode? {
        guard chordIndex + 1 < voice.children.count else { return nil }
        for index in (chordIndex + 1)..<voice.children.count {
            let candidate = voice.children[index]
            if candidate.name != "Chord" || isGraceChord(candidate) { continue }
            let notes = children(candidate, "Note")
            return notes.isEmpty ? nil : notes[min(noteIndex, notes.count - 1)]
        }
        return nil
    }

    static func addGuitarBendRangesFromChord(
        _ voice: XMLNode,
        chordIndex: Int,
        chord: XMLNode,
        track: TrackData,
        startTick: Int,
        nominalDuration: Int,
        measureTicks: Int,
        division: Int
    ) {
        let notes = children(chord, "Note")
        for (noteIndex, note) in notes.enumerated() {
            let sourcePitch = intText(firstChild(note, "pitch"), -1)
            if sourcePitch < 0 { continue }
            for spanner in children(note, "Spanner") {
                guard spanner.attribute("type") == "GuitarBend",
                      firstChild(spanner, "prev") == nil,
                      let bend = firstChild(spanner, "GuitarBend"),
                      intText(firstChild(bend, "play"), 1) != 0
                else { continue }
                let targetNote = guitarBendTargetNote(
                    voice,
                    chordIndex: chordIndex,
                    noteIndex: noteIndex
                )
                let targetPitch = targetNote.map {
                    intText(firstChild($0, "pitch"), sourcePitch)
                } ?? sourcePitch
                let targetCents = targetNote.map(noteTuningCents) ?? noteTuningCents(note)
                var length = spannerLengthTicks(spanner, division: division, measureTicks: measureTicks)
                if length <= 0 { length = max(1, nominalDuration) }
                let targetFactor = firstChild(bend, "bendTargetTimeFactor")
                track.guitarBendRanges.append(
                    GuitarBendRange(
                        startTick: startTick,
                        endTick: startTick + max(1, length),
                        noteIndex: noteIndex,
                        sourcePitch: sourcePitch,
                        sourceCents: noteTuningCents(note),
                        targetPitch: targetPitch,
                        targetCents: targetCents,
                        type: text(firstChild(bend, "guitarBendType")),
                        startFactor: doubleText(firstChild(bend, "bendStartTimeFactor"), 0),
                        targetFactor: doubleText(targetFactor, 0.5),
                        endFactor: doubleText(firstChild(bend, "bendEndTimeFactor"), 1),
                        hasTargetFactor: targetFactor != nil
                    )
                )
            }
        }
    }

    static func guitarBendTargetNote(
        _ voice: XMLNode,
        chordIndex: Int,
        noteIndex: Int
    ) -> XMLNode? {
        findGuitarBendEndpointNote(
            voice,
            startIndex: chordIndex + 1,
            endIndex: voice.children.count,
            step: 1,
            noteIndex: noteIndex
        ) ?? findGuitarBendEndpointNote(
            voice,
            startIndex: chordIndex - 1,
            endIndex: -1,
            step: -1,
            noteIndex: noteIndex
        )
    }

    static func findGuitarBendEndpointNote(
        _ voice: XMLNode,
        startIndex: Int,
        endIndex: Int,
        step: Int,
        noteIndex: Int
    ) -> XMLNode? {
        var index = startIndex
        while index != endIndex {
            defer { index += step }
            guard voice.children.indices.contains(index) else { continue }
            let candidate = voice.children[index]
            guard candidate.name == "Chord" else { continue }
            let notes = children(candidate, "Note")
            guard !notes.isEmpty else { continue }
            let indexed = notes[min(noteIndex, notes.count - 1)]
            if hasSpannerEndpoint(indexed, type: "GuitarBend", endpoint: "prev") { return indexed }
            if let endpoint = notes.first(where: {
                hasSpannerEndpoint($0, type: "GuitarBend", endpoint: "prev")
            }) { return endpoint }
        }
        return nil
    }

    static func hasSpannerEndpoint(_ note: XMLNode, type: String, endpoint: String) -> Bool {
        children(note, "Spanner").contains {
            $0.attribute("type") == type && firstChild($0, endpoint) != nil
        }
    }

    static func hairpinVelocityDelta(_ hairpin: XMLNode) -> Int {
        let delta = max(1, intText(firstChild(hairpin, "veloChange"), 15))
        let subtype = text(firstChild(hairpin, "subtype")).lowercased()
        return subtype == "1" || subtype.contains("decresc") || subtype.contains("dim") ? -delta : delta
    }

    static func closeHairpin(
        activeHairpins: inout [String: HairpinRange],
        closedHairpins: inout [HairpinRange],
        id: String,
        endTick: Int
    ) {
        guard !id.isEmpty, let range = activeHairpins.removeValue(forKey: id) else { return }
        range.endTick = max(range.startTick + 1, endTick)
        closedHairpins.append(range)
    }

    static func addPedalRangeFromSpanner(
        _ spanner: XMLNode,
        track: TrackData,
        startTick: Int,
        measureTicks: Int,
        division: Int,
        childTag: String,
        emitControlChange: Bool
    ) {
        guard firstChild(spanner, childTag) != nil,
              firstChild(spanner, "next") != nil,
              firstChild(spanner, "prev") == nil
        else { return }
        let endTick = startTick + max(
            1,
            spannerLengthTicks(spanner, division: division, measureTicks: measureTicks)
        )
        track.pedalRanges.append(PedalRange(startTick: startTick, endTick: endTick))
        if emitControlChange {
            track.events.append(.controlChange(tick: startTick, controller: midiControlSustain, value: 127))
            track.events.append(.controlChange(tick: endTick, controller: midiControlSustain, value: 0))
        }
    }

    static func addPlaybackRangeFromSpanner(
        _ spanner: XMLNode,
        track: TrackData,
        startTick: Int,
        measureTicks: Int,
        division: Int,
        childTag: String,
        gateTimePercent: Int,
        velocityOffset: Int
    ) {
        guard firstChild(spanner, childTag) != nil,
              firstChild(spanner, "next") != nil,
              firstChild(spanner, "prev") == nil
        else { return }
        track.playbackRanges.append(
            PlaybackRange(
                startTick: startTick,
                endTick: startTick + max(
                    1,
                    spannerLengthTicks(spanner, division: division, measureTicks: measureTicks)
                ),
                gateTimePercent: clamped(gateTimePercent, 1, 1000),
                velocityOffset: clamped(velocityOffset, -64, 64)
            )
        )
    }

    static func addVibratoRangeFromSpanner(
        _ spanner: XMLNode,
        track: TrackData,
        startTick: Int,
        measureTicks: Int,
        division: Int
    ) {
        guard let vibrato = firstChild(spanner, "Vibrato"),
              firstChild(spanner, "next") != nil,
              firstChild(spanner, "prev") == nil
        else { return }
        let subtype = text(firstChild(vibrato, "subtype")).lowercased()
        track.vibratoRanges.append(
            VibratoRange(
                startTick: startTick,
                endTick: startTick + max(
                    1,
                    spannerLengthTicks(spanner, division: division, measureTicks: measureTicks)
                ),
                cents: subtype.contains("wide") ? 24 : 14,
                sawtooth: subtype.contains("saw")
            )
        )
    }

    static func addOttavaRangeFromSpanner(
        _ spanner: XMLNode,
        track: TrackData,
        startTick: Int,
        measureTicks: Int,
        division: Int
    ) {
        guard let ottava = firstChild(spanner, "Ottava"),
              firstChild(spanner, "next") != nil,
              firstChild(spanner, "prev") == nil
        else { return }
        var semitones = ottavaSemitoneShift(text(firstChild(ottava, "subtype")))
        if semitones == 0 {
            semitones = ottavaSemitoneShift(text(firstChild(ottava, "ottavaType")))
        }
        guard semitones != 0 else { return }
        track.ottavaRanges.append(
            PitchShiftRange(
                startTick: startTick,
                endTick: startTick + max(
                    1,
                    spannerLengthTicks(spanner, division: division, measureTicks: measureTicks)
                ),
                semitones: semitones
            )
        )
    }

    static func ottavaSemitoneShift(_ subtype: String) -> Int {
        let lower = subtype.lowercased()
        let numeric = parseInt(lower, -1)
        if numeric == 0 || lower.contains("8va") { return 12 }
        if numeric == 1 || lower.contains("8vb") { return -12 }
        if numeric == 2 || lower.contains("15ma") { return 24 }
        if numeric == 3 || lower.contains("15mb") { return -24 }
        if numeric == 4 || lower.contains("22ma") { return 36 }
        if numeric == 5 || lower.contains("22mb") { return -36 }
        return 0
    }

    static func spannerLengthTicks(_ spanner: XMLNode, division: Int, measureTicks: Int) -> Int {
        locationTicks(
            firstChild(firstChild(spanner, "next"), "location"),
            division: division,
            measureTicks: measureTicks
        )
    }

    static func addTrillRangeFromSpanner(
        _ spanner: XMLNode,
        track: TrackData,
        startTick: Int,
        measureTicks: Int,
        division: Int
    ) {
        guard let trill = firstChild(spanner, "Trill"), firstChild(spanner, "prev") == nil else {
            return
        }
        var length = locationTicks(
            firstChild(firstChild(spanner, "next"), "location"),
            division: division,
            measureTicks: measureTicks
        )
        if length <= 0 { length = max(1, measureTicks) }
        track.trillRanges.append(
            OrnamentRange(
                startTick: startTick,
                endTick: startTick + max(1, length),
                name: text(firstChild(trill, "subtype"))
            )
        )
    }

    static func pedalExtendedEndTick(_ track: TrackData, startTick: Int, endTick: Int) -> Int {
        var result = endTick
        for range in track.pedalRanges
        where startTick < range.endTick && result >= range.startTick && result < range.endTick {
            result = range.endTick
        }
        return max(endTick, result)
    }
}

private extension MuseScoreConverter {
    static func childLocationOffset(_ element: XMLNode, division: Int, measureTicks: Int) -> Int {
        locationTicks(firstChild(element, "location"), division: division, measureTicks: measureTicks)
    }

    static func locationTicks(_ location: XMLNode?, division: Int, measureTicks: Int) -> Int {
        guard let location else { return 0 }
        var ticks = 0
        if let measures = firstChild(location, "measures") {
            ticks += intText(measures, 0) * max(1, measureTicks)
        }
        if let fractions = firstChild(location, "fractions") {
            ticks += ratioTicks(text(fractions), division: division)
        }
        return ticks
    }

    static func parseTupletInfo(
        _ tuplet: XMLNode,
        knownTuplets: [String: TupletInfo]
    ) -> TupletInfo? {
        let normal = intText(firstChild(tuplet, "normalNotes"), 0)
        let actual = intText(firstChild(tuplet, "actualNotes"), 0)
        guard normal > 0, actual > 0 else { return nil }
        var ratio = Double(normal) / Double(actual)
        let parentID = text(firstChild(tuplet, "Tuplet"))
        if let parent = knownTuplets[parentID] { ratio *= parent.ratio }
        return TupletInfo(id: tuplet.attribute("id"), ratio: ratio, actualNotes: actual)
    }

    static func tupletRatio(
        for element: XMLNode,
        knownTuplets: [String: TupletInfo],
        fallbackRatio: Double
    ) -> Double {
        if let reference = firstChild(element, "Tuplet"),
           let info = knownTuplets[text(reference)]
        {
            return info.ratio
        }
        return fallbackRatio
    }

    static func ticksForTimeSignature(division: Int, sigN requestedN: Int, sigD requestedD: Int) -> Int {
        let n = requestedN > 0 && requestedD > 0 ? requestedN : defaultTimeSigN
        let d = requestedN > 0 && requestedD > 0 ? requestedD : defaultTimeSigD
        return javaRound(Double(division) * 4 * Double(n) / Double(d))
    }

    static func durationTicks(
        _ element: XMLNode,
        division: Int,
        tupletRatio: Double,
        measureTicks: Int
    ) -> Int {
        if let explicitDuration = firstChild(element, "duration") {
            let ticks = ratioTicks(text(explicitDuration), division: division)
            if ticks > 0 { return max(1, javaRound(Double(ticks) * tupletRatio)) }
        }
        let base = durationTypeTicks(
            text(firstChild(element, "durationType")),
            division: division,
            measureTicks: measureTicks
        )
        let dots = intText(firstChild(element, "dots"), 0)
        var multiplier = 1.0
        var addition = 0.5
        if dots > 0 {
            for _ in 0..<dots {
                multiplier += addition
                addition *= 0.5
            }
        }
        return max(1, javaRound(Double(base) * multiplier * tupletRatio))
    }

    static func durationTypeTicks(_ durationType: String, division: Int, measureTicks: Int) -> Int {
        let type = durationType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch type {
        case "measure": return measureTicks > 0 ? measureTicks : division * 4
        case "longa": return division * 16
        case "breve": return division * 8
        case "whole": return division * 4
        case "half": return division * 2
        case "", "quarter": return division
        case "eighth": return max(1, division / 2)
        case "16th": return max(1, division / 4)
        case "32nd": return max(1, division / 8)
        case "64th": return max(1, division / 16)
        case "128th": return max(1, division / 32)
        case "256th": return max(1, division / 64)
        default:
            if type.hasSuffix("th") {
                let denominator = parseInt(String(type.dropLast(2)), 4)
                if denominator > 0 {
                    return max(1, javaRound(Double(division) * 4 / Double(denominator)))
                }
            }
            return division
        }
    }

    static func ratioTicks(_ text: String?, division: Int) -> Int {
        guard let text else { return 0 }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return 0 }
        if let slash = value.firstIndex(of: "/") {
            let numerator = parseDouble(String(value[..<slash]), 0)
            let denominator = parseDouble(String(value[value.index(after: slash)...]), 1)
            if denominator != 0 {
                return javaRound(Double(division) * 4 * numerator / denominator)
            }
        }
        return javaRound(parseDouble(value, 0) * Double(division))
    }

    static func fileTick(_ text: String) -> Int {
        javaRound(parseDouble(text, 0))
    }

    static func consumeTupletSlot(_ state: VoiceState, element: XMLNode) {
        guard firstChild(element, "Tuplet") == nil else { return }
        if state.tupletRemaining > 0 {
            state.tupletRemaining -= 1
            if state.tupletRemaining <= 0 { state.tupletRatio = 1 }
        }
    }

    static func normalizeMIDXPitchCents(pitch requestedPitch: Double, cents requestedCents: Double) -> NormalizedPitch {
        let pitch = requestedPitch.isFinite ? requestedPitch : 0
        let cents = requestedCents.isFinite ? requestedCents : 0
        var targetPitch = javaRound(pitch)
        var residualCents = cents + (pitch - Double(targetPitch)) * 100
        var guardCount = 0
        while residualCents > midxSafeCentRange, guardCount < 512 {
            targetPitch += 1
            residualCents -= 100
            guardCount += 1
        }
        while residualCents < -midxSafeCentRange, guardCount < 512 {
            targetPitch -= 1
            residualCents += 100
            guardCount += 1
        }
        if abs(residualCents) < 0.000_001 { residualCents = 0 }
        return NormalizedPitch(pitch: clamped(targetPitch, 0, 127), cents: residualCents)
    }

    static func encodeCentOffset(_ requestedCents: Double) -> Int {
        let cents = requestedCents.isFinite ? requestedCents : 0
        let sign = cents < 0 ? 0x8000 : 0
        let magnitude = min(
            0x7FFF,
            javaRound(abs(cents) / midxCentRange * midxOffsetSteps)
        )
        return sign | magnitude
    }
}

private extension MuseScoreConverter {
    static func writeMIDIFile(_ score: ScoreData, includeMIDXExtensions: Bool) throws -> Data {
        var output = Data()
        let tracks = score.tracksWithEvents()
        appendChunk(
            &output,
            type: "MThd",
            data: headerData(division: score.division, trackCount: max(1, tracks.count))
        )
        if tracks.isEmpty {
            appendChunk(
                &output,
                type: "MTrk",
                data: mergedTrackData(
                    nil,
                    score: score,
                    includeMeta: true,
                    includeMIDXExtensions: includeMIDXExtensions
                )
            )
        } else {
            for (index, track) in tracks.enumerated() {
                appendChunk(
                    &output,
                    type: "MTrk",
                    data: mergedTrackData(
                        track,
                        score: score,
                        includeMeta: index == 0,
                        includeMIDXExtensions: includeMIDXExtensions
                    )
                )
            }
        }
        return output
    }

    static func headerData(division: Int, trackCount: Int) -> Data {
        var output = Data()
        appendU16(&output, 1)
        appendU16(&output, trackCount)
        appendU16(&output, clamped(division, 1, 0x7FFF))
        return output
    }

    static func metaEvents(_ score: ScoreData) -> [MetaTickEvent] {
        var events = score.tempoEvents.map {
            MetaTickEvent(tick: $0.tick, order: 0, payload: .tempo($0))
        }
        events.append(contentsOf: score.timeSigEvents.map {
            MetaTickEvent(tick: $0.tick, order: 1, payload: .timeSignature($0))
        })
        return events.enumerated().sorted {
            if $0.element.tick != $1.element.tick { return $0.element.tick < $1.element.tick }
            if $0.element.order != $1.element.order { return $0.element.order < $1.element.order }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    static func appendMetaEvent(_ output: inout Data, event: MetaTickEvent) {
        switch event.payload {
        case let .tempo(tempo):
            let microseconds = javaRound(60_000_000 / max(1, min(1000, tempo.bpm)))
            output.append(0xFF)
            output.append(0x51)
            output.append(0x03)
            appendU24(&output, microseconds)
        case let .timeSignature(signature):
            output.append(0xFF)
            output.append(0x58)
            output.append(0x04)
            output.append(UInt8(clamped(signature.numerator, 1, 255)))
            output.append(UInt8(timeSigDenominatorPower(signature.denominator)))
            output.append(24)
            output.append(8)
        }
    }

    static func timeSigDenominatorPower(_ denominator: Int) -> Int {
        var value = 1
        var power = 0
        while value < denominator, power < 8 {
            value <<= 1
            power += 1
        }
        return power
    }

    static func mergedTrackData(
        _ track: TrackData?,
        score: ScoreData,
        includeMeta: Bool,
        includeMIDXExtensions: Bool
    ) -> Data {
        var events: [TrackTickEvent] = []
        if includeMeta {
            events.append(contentsOf: metaEvents(score).map(TrackTickEvent.meta))
        }
        if let track {
            events.append(contentsOf: track.events.map(TrackTickEvent.midi))
        }
        events = events.enumerated().sorted {
            if $0.element.tick != $1.element.tick { return $0.element.tick < $1.element.tick }
            if $0.element.order != $1.element.order { return $0.element.order < $1.element.order }
            if $0.element.pitch != $1.element.pitch { return $0.element.pitch < $1.element.pitch }
            return $0.offset < $1.offset
        }.map(\.element)

        var output = Data()
        if let track, !track.trackName.isEmpty {
            appendVLQ(&output, 0)
            appendTextMeta(&output, metaType: 0x03, value: track.trackName)
        }
        if let track, !track.instrumentName.isEmpty {
            appendVLQ(&output, 0)
            appendTextMeta(&output, metaType: 0x04, value: track.instrumentName)
        }
        if let track, track.writeProgramChange {
            if track.bankMSB >= 0 {
                appendVLQ(&output, 0)
                output.append(UInt8(0xB0 | (track.channel & 0x0F)))
                output.append(0)
                output.append(UInt8(track.bankMSB & 0x7F))
            }
            if track.bankLSB >= 0 {
                appendVLQ(&output, 0)
                output.append(UInt8(0xB0 | (track.channel & 0x0F)))
                output.append(0x20)
                output.append(UInt8(track.bankLSB & 0x7F))
            }
            appendVLQ(&output, 0)
            output.append(UInt8(0xC0 | (track.channel & 0x0F)))
            output.append(UInt8(track.program & 0x7F))
        }

        var previousTick = 0
        for event in events {
            let tick = max(0, event.tick)
            appendVLQ(&output, tick - previousTick)
            if let meta = event.meta {
                appendMetaEvent(&output, event: meta)
            } else if let midi = event.midi, let track {
                if includeMIDXExtensions,
                   midi.kind == .noteOn,
                   encodeCentOffset(midi.cents) != 0
                {
                    appendMIDXOffsetExtension(&output, pitch: midi.pitch, cents: midi.cents)
                    appendVLQ(&output, 0)
                }
                switch midi.kind {
                case .noteOff:
                    output.append(UInt8(0x80 | (track.channel & 0x0F)))
                    output.append(UInt8(midi.nativePitch & 0x7F))
                    output.append(0)
                case .control:
                    output.append(UInt8(0xB0 | (track.channel & 0x0F)))
                    output.append(UInt8(midi.controller & 0x7F))
                    output.append(UInt8(midi.value & 0x7F))
                case .noteOn:
                    output.append(UInt8(0x90 | (track.channel & 0x0F)))
                    output.append(UInt8(midi.nativePitch & 0x7F))
                    output.append(UInt8(midi.velocity & 0x7F))
                }
            }
            previousTick = tick
        }

        appendVLQ(&output, 0)
        output.append(0xFF)
        output.append(0x2F)
        output.append(0)
        return output
    }

    static func appendMIDXOffsetExtension(_ output: inout Data, pitch: Int, cents: Double) {
        output.append(0xFF)
        output.append(midxMetaType)
        output.append(midxPayloadLength)
        output.append(midxExperimentalManufacturerID)
        output.append(0x58)
        output.append(0x54)
        output.append(midxPitchedOffsetRecordType)
        output.append(UInt8(clamped(pitch, 0, 127)))
        appendU16(&output, encodeCentOffset(cents))
    }

    static func appendTextMeta(_ output: inout Data, metaType: UInt8, value: String) {
        let bytes = Data(value.utf8)
        output.append(0xFF)
        output.append(metaType & 0x7F)
        appendVLQ(&output, bytes.count)
        output.append(bytes)
    }

    static func appendChunk(_ output: inout Data, type: String, data: Data) {
        output.append(contentsOf: type.utf8)
        appendU32(&output, data.count)
        output.append(data)
    }

    static func appendU16(_ output: inout Data, _ value: Int) {
        output.append(UInt8((value >> 8) & 0xFF))
        output.append(UInt8(value & 0xFF))
    }

    static func appendU24(_ output: inout Data, _ value: Int) {
        output.append(UInt8((value >> 16) & 0xFF))
        output.append(UInt8((value >> 8) & 0xFF))
        output.append(UInt8(value & 0xFF))
    }

    static func appendU32(_ output: inout Data, _ value: Int) {
        output.append(UInt8((value >> 24) & 0xFF))
        output.append(UInt8((value >> 16) & 0xFF))
        output.append(UInt8((value >> 8) & 0xFF))
        output.append(UInt8(value & 0xFF))
    }

    static func appendVLQ(_ output: inout Data, _ requestedValue: Int) {
        var value = max(0, min(0x0FFF_FFFF, requestedValue))
        var stack = [value & 0x7F]
        value >>= 7
        while value > 0 {
            stack.append((value & 0x7F) | 0x80)
            value >>= 7
        }
        for byte in stack.reversed() { output.append(UInt8(byte)) }
    }
}

private extension MuseScoreConverter {
    static func firstChild(_ parent: XMLNode?, _ tag: String) -> XMLNode? {
        parent?.children.first { $0.name == tag }
    }

    static func children(_ parent: XMLNode?, _ tag: String? = nil) -> [XMLNode] {
        guard let parent else { return [] }
        guard let tag else { return parent.children }
        return parent.children.filter { $0.name == tag }
    }

    static func firstDescendant(_ parent: XMLNode?, _ tag: String) -> XMLNode? {
        guard let parent else { return nil }
        for child in parent.children {
            if child.name == tag { return child }
            if let descendant = firstDescendant(child, tag) { return descendant }
        }
        return nil
    }

    static func text(_ element: XMLNode?) -> String {
        element?.textContent.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func intText(_ element: XMLNode?, _ fallback: Int) -> Int {
        parseInt(text(element), fallback)
    }

    static func doubleText(_ element: XMLNode?, _ fallback: Double) -> Double {
        parseDouble(text(element), fallback)
    }

    static func boolText(_ element: XMLNode?, _ fallback: Bool) -> Bool {
        let value = text(element).lowercased()
        if value.isEmpty { return fallback }
        return value == "1" || value == "true" || value == "yes"
    }

    static func intAttribute(_ element: XMLNode?, _ name: String, _ fallback: Int) -> Int {
        guard let element else { return fallback }
        return parseInt(element.attribute(name), fallback)
    }

    static func hasAttributeValue(_ element: XMLNode?, _ name: String) -> Bool {
        !(element?.attribute(name).isEmpty ?? true)
    }

    static func parseInt(_ value: String?, _ fallback: Int) -> Int {
        guard let value,
              let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed.isFinite
        else { return fallback }
        return javaRound(parsed)
    }

    static func parseDouble(_ value: String?, _ fallback: Double) -> Double {
        guard let value,
              let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return fallback }
        return parsed
    }

    static func clampFactor(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, min(1, value))
    }

    static func clamped(_ value: Int, _ minimum: Int, _ maximum: Int) -> Int {
        max(minimum, min(maximum, value))
    }

    static func javaRound(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        let rounded = floor(value + 0.5)
        if rounded <= Double(Int.min) { return Int.min }
        if rounded >= Double(Int.max) { return Int.max }
        return Int(rounded)
    }

    static func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
        let remainder = value % modulus
        return remainder >= 0 ? remainder : remainder + modulus
    }
}

private extension MuseScoreConverter {
    final class ScoreData {
        var division = defaultDivision
        var noteCount = 0
        var microtonalCount = 0
        var swingRatio = 0
        var swingUnitDenominator = 8
        var staffInfos: [Int: StaffInfo] = [:]
        var tracks: [Int: TrackData] = [:]
        var tempoEvents: [TempoEvent] = []
        var timeSigEvents: [TimeSigEvent] = []

        func track(for info: StaffInfo) -> TrackData {
            if let track = tracks[info.staffID] { return track }
            let track = TrackData(
                staffID: info.staffID,
                partIndex: info.partIndex,
                program: info.program,
                bankMSB: info.bankMSB,
                bankLSB: info.bankLSB,
                channel: info.channel,
                gateTimePercent: info.gateTimePercent,
                writeProgramChange: info.writeProgramChange,
                trackName: info.trackName,
                instrumentName: info.instrumentName
            )
            tracks[info.staffID] = track
            return track
        }

        func tracksWithEvents() -> [TrackData] {
            tracks.keys.sorted().compactMap { key in
                guard let track = tracks[key], !track.events.isEmpty else { return nil }
                return track
            }
        }
    }

    struct StaffInfo {
        let staffID: Int
        let partIndex: Int
        let program: Int
        let bankMSB: Int
        let bankLSB: Int
        let channel: Int
        let gateTimePercent: Int
        let writeProgramChange: Bool
        let trackName: String
        let instrumentName: String
    }

    final class TrackData {
        let staffID: Int
        let partIndex: Int
        let program: Int
        let bankMSB: Int
        let bankLSB: Int
        let channel: Int
        let gateTimePercent: Int
        let writeProgramChange: Bool
        let trackName: String
        let instrumentName: String
        var events: [MIDIEvent] = []
        var pedalRanges: [PedalRange] = []
        var hairpins: [HairpinRange] = []
        var trillRanges: [OrnamentRange] = []
        var glissandoRanges: [PitchRange] = []
        var guitarBendRanges: [GuitarBendRange] = []
        var ottavaRanges: [PitchShiftRange] = []
        var playbackRanges: [PlaybackRange] = []
        var vibratoRanges: [VibratoRange] = []

        init(
            staffID: Int,
            partIndex: Int,
            program: Int,
            bankMSB: Int,
            bankLSB: Int,
            channel: Int,
            gateTimePercent: Int,
            writeProgramChange: Bool,
            trackName: String,
            instrumentName: String
        ) {
            self.staffID = staffID
            self.partIndex = partIndex
            self.program = program
            self.bankMSB = bankMSB
            self.bankLSB = bankLSB
            self.channel = channel
            self.gateTimePercent = gateTimePercent
            self.writeProgramChange = writeProgramChange
            self.trackName = trackName
            self.instrumentName = instrumentName
        }
    }

    final class VoiceState {
        var tick = 0
        var gridTick = 0
        var measureStart = 0
        var sourceMeasureStart = 0
        var measureTicks = 0
        var velocity = 0
        var bpm = defaultBPM
        var swingRatio = 0
        var swingUnitDenominator = 8
        var tupletRatio = 1.0
        var tupletRemaining = 0
        var lastTimeSigN = 0
        var lastTimeSigD = 0
        var pendingFermataMultiplier = 1.0
        var tupletsByID: [String: TupletInfo] = [:]
        var activeTies: [TieKey: NotePlayback] = [:]
        var pendingGraceChords: [XMLNode] = []
    }

    final class MeasureTimeline {
        let sourceStarts: [Int]
        let sourceLengths: [Int]
        var slots: [MeasureSlot] = []

        init(sourceStarts: [Int], sourceLengths: [Int]) {
            self.sourceStarts = sourceStarts
            self.sourceLengths = sourceLengths
        }
    }

    struct MeasureSlot {
        let measureIndex: Int
        let sourceStart: Int
        let outputStart: Int
        let length: Int
    }

    struct PedalRange {
        let startTick: Int
        let endTick: Int
    }

    final class HairpinRange {
        let startTick: Int
        var endTick: Int
        let velocityDelta: Int

        init(startTick: Int, endTick: Int, velocityDelta: Int) {
            self.startTick = startTick
            self.endTick = endTick
            self.velocityDelta = velocityDelta
        }
    }

    struct OrnamentRange {
        let startTick: Int
        let endTick: Int
        let name: String
    }

    struct PitchRange {
        let startTick: Int
        let endTick: Int
        let noteIndex: Int
        let sourcePitch: Int
        let sourceCents: Double
        let targetPitch: Int
        let targetCents: Double
        let continuous: Bool
        let whiteKeysOnly: Bool
        let blackKeysOnly: Bool
    }

    struct GuitarBendRange {
        let startTick: Int
        let endTick: Int
        let noteIndex: Int
        let sourcePitch: Int
        let sourceCents: Double
        let targetPitch: Int
        let targetCents: Double
        let type: String
        let startFactor: Double
        let targetFactor: Double
        let endFactor: Double
        let hasTargetFactor: Bool
    }

    struct PitchShiftRange {
        let startTick: Int
        let endTick: Int
        let semitones: Int
    }

    struct PlaybackRange {
        let startTick: Int
        let endTick: Int
        let gateTimePercent: Int
        let velocityOffset: Int
    }

    struct VibratoRange {
        let startTick: Int
        let endTick: Int
        let cents: Double
        let sawtooth: Bool
    }

    struct BendPoint {
        let time: Int
        let pitchDelta: Double
    }

    final class GracePlaybackSplit {
        var beforeTotal = 0
        var beforeEach = 0
        var afterTotal = 0
        var afterEach = 0
    }

    struct ChordPerformance {
        let gateTimePercent: Int
        let velocityOffset: Int
    }

    struct OrnamentPattern {
        let pitchDeltas: [Int]
        let repeats: Bool
        let sustainLast: Bool
        let denominator: Int

        init(_ pitchDeltas: [Int], repeats: Bool, sustainLast: Bool, denominator: Int) {
            self.pitchDeltas = pitchDeltas
            self.repeats = repeats
            self.sustainLast = sustainLast
            self.denominator = denominator
        }

        func unitTicks(division: Int) -> Int {
            max(1, MuseScoreConverter.javaRound(Double(division) * 4 / Double(max(1, denominator))))
        }
    }

    struct TupletInfo {
        let id: String
        let ratio: Double
        let actualNotes: Int
    }

    struct TempoEvent {
        let tick: Int
        let bpm: Double
    }

    struct TimeSigEvent {
        let tick: Int
        let numerator: Int
        let denominator: Int
    }

    enum MetaPayload {
        case tempo(TempoEvent)
        case timeSignature(TimeSigEvent)
    }

    struct MetaTickEvent {
        let tick: Int
        let order: Int
        let payload: MetaPayload
    }

    struct TrackTickEvent {
        let tick: Int
        let order: Int
        let pitch: Int
        let meta: MetaTickEvent?
        let midi: MIDIEvent?

        static func meta(_ event: MetaTickEvent) -> TrackTickEvent {
            TrackTickEvent(tick: event.tick, order: event.order, pitch: 0, meta: event, midi: nil)
        }

        static func midi(_ event: MIDIEvent) -> TrackTickEvent {
            let order = event.kind == .noteOff ? 10 : (event.kind == .control ? 15 : 20)
            return TrackTickEvent(
                tick: event.tick,
                order: order,
                pitch: event.pitch,
                meta: nil,
                midi: event
            )
        }
    }

    struct MIDIEvent {
        enum Kind {
            case noteOff
            case noteOn
            case control
        }

        let tick: Int
        let kind: Kind
        let pitch: Int
        let nativePitch: Int
        let velocity: Int
        let cents: Double
        let controller: Int
        let value: Int

        static func noteOn(
            tick: Int,
            pitch: Int,
            nativePitch: Int,
            velocity: Int,
            cents: Double
        ) -> MIDIEvent {
            MIDIEvent(
                tick: tick,
                kind: .noteOn,
                pitch: pitch,
                nativePitch: nativePitch,
                velocity: velocity,
                cents: cents,
                controller: 0,
                value: 0
            )
        }

        static func noteOff(tick: Int, nativePitch: Int) -> MIDIEvent {
            MIDIEvent(
                tick: tick,
                kind: .noteOff,
                pitch: nativePitch,
                nativePitch: nativePitch,
                velocity: 0,
                cents: 0,
                controller: 0,
                value: 0
            )
        }

        static func controlChange(tick: Int, controller: Int, value: Int) -> MIDIEvent {
            MIDIEvent(
                tick: tick,
                kind: .control,
                pitch: 0,
                nativePitch: 0,
                velocity: 0,
                cents: 0,
                controller: MuseScoreConverter.clamped(controller, 0, 127),
                value: MuseScoreConverter.clamped(value, 0, 127)
            )
        }
    }

    final class NotePlayback {
        var startTick: Int
        var endTick: Int
        var pitch: Int
        var nativePitch: Int
        var cents: Double
        var velocity: Int
        var gateTimePercent: Int

        init(
            startTick: Int,
            endTick: Int,
            pitch: Int,
            nativePitch: Int,
            cents: Double,
            velocity: Int,
            gateTimePercent: Int
        ) {
            self.startTick = startTick
            self.endTick = endTick
            self.pitch = pitch
            self.nativePitch = nativePitch
            self.cents = cents
            self.velocity = velocity
            self.gateTimePercent = gateTimePercent
        }
    }

    struct NormalizedPitch {
        let pitch: Int
        let cents: Double
    }

    struct EventTiming {
        let offsetTicks: Int
        let lengthTicks: Int
        let pitchDelta: Double
    }

    struct TieKey: Hashable {
        let staffID: Int
        let voiceIndex: Int
        let pitch: Int
        let tuning: Double
    }
}
