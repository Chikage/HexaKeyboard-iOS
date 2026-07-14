import Foundation

public enum ScoreContentType: Equatable, Sendable {
    case standardMIDI
    case midi2Clip
    case museScore
}

public enum ScoreContentParserError: LocalizedError, Equatable {
    case unsupportedFormat(String)
    case fileTooLarge(maximumBytes: Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(name):
            return "不支持的乐谱格式“\(name)”；请选择 MID、MIDI、MIDIX、MIDX、MIDI2、MSCZ 或 MSCX 文件。"
        case let .fileTooLarge(maximumBytes):
            return "文件超过 \(maximumBytes / 1_024 / 1_024) MB 限制。"
        }
    }
}

public struct ScoreContentParser: Sendable {
    public static let maximumFileBytes = 64 * 1_024 * 1_024
    public static let supportedExtensions: Set<String> = [
        "mid", "midi", "midix", "midx", "midi2", "mscz", "mscx",
    ]

    private static let midiExtensions: Set<String> = ["mid", "midi", "midix", "midx"]

    public init() {}

    public func classify(fileName: String, data: Data) throws -> ScoreContentType {
        let fileExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        if data.hasZIPHeader || fileExtension == "mscz" || fileExtension == "mscx" {
            return .museScore
        }
        if data.starts(withASCII: "SMF2CLIP") || fileExtension == "midi2" {
            return .midi2Clip
        }
        if data.starts(withASCII: "MThd") || Self.midiExtensions.contains(fileExtension) {
            return .standardMIDI
        }
        throw ScoreContentParserError.unsupportedFormat(fileName)
    }

    public func supports(fileName: String, data: Data = Data()) -> Bool {
        (try? classify(fileName: fileName, data: data)) != nil
    }

    public func parseScore(fileName: String, data: Data) throws -> PlaybackScore {
        guard data.count <= Self.maximumFileBytes else {
            throw ScoreContentParserError.fileTooLarge(maximumBytes: Self.maximumFileBytes)
        }

        switch try classify(fileName: fileName, data: data) {
        case .museScore:
            let converted = try MuseScoreConverter.convert(data, fileName: fileName)
            return try MidiWaterfallParser.detectAndParse(bytes: converted, fileName: fileName)
        case .standardMIDI, .midi2Clip:
            return try MidiWaterfallParser.detectAndParse(bytes: data, fileName: fileName)
        }
    }
}

private extension Data {
    var hasZIPHeader: Bool {
        count >= 4
            && self[startIndex] == 0x50
            && self[index(startIndex, offsetBy: 1)] == 0x4B
            && self[index(startIndex, offsetBy: 2)] == 0x03
            && self[index(startIndex, offsetBy: 3)] == 0x04
    }

    func starts(withASCII value: String) -> Bool {
        let prefix = Array(value.utf8)
        guard count >= prefix.count else { return false }
        return zip(self, prefix).allSatisfy { $0.0 == $0.1 }
    }
}
