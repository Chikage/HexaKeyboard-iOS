import Foundation

public let PLAYBACK_PREVIEW_SECONDS = 1.8
public let MAX_PLAYBACK_PREVIEW_NOTES = 16
public let PLAYBACK_COMPLETION_BURST_SECONDS = 0.34
public let PLAYBACK_REPEAT_WINDOW_SECONDS = 0.42
private let playbackRepeatGapSeconds = 0.18
private let maxCompletedNotesPerKey = 4

public struct KeyboardPlaybackNote: Equatable, Sendable {
    public let scoreIndex: Int
    public let coordinate: AxialCoordinate
    public let start: Double
    public let end: Double
    public let audioPitch: Double
    public let velocity: Int
    public let track: Int
    public let repeatedHit: Bool

    public init(
        scoreIndex: Int,
        coordinate: AxialCoordinate,
        start: Double,
        end: Double,
        audioPitch: Double,
        velocity: Int,
        track: Int,
        repeatedHit: Bool
    ) {
        self.scoreIndex = scoreIndex
        self.coordinate = coordinate
        self.start = start
        self.end = end
        self.audioPitch = audioPitch
        self.velocity = velocity
        self.track = track
        self.repeatedHit = repeatedHit
    }
}

public struct KeyboardPlaybackTimeline: Equatable, Sendable {
    public let notes: [KeyboardPlaybackNote]
    public let notesByEnd: [KeyboardPlaybackNote]
    public let duration: Double

    public init(
        notes: [KeyboardPlaybackNote],
        notesByEnd: [KeyboardPlaybackNote],
        duration: Double
    ) {
        self.notes = notes
        self.notesByEnd = notesByEnd
        self.duration = duration
    }

    public static let empty = KeyboardPlaybackTimeline(
        notes: [],
        notesByEnd: [],
        duration: 0
    )
}

public struct UpcomingPlaybackNote: Equatable, Sendable {
    public let note: KeyboardPlaybackNote
    public let progress: Float

    public init(note: KeyboardPlaybackNote, progress: Float) {
        self.note = note
        self.progress = progress
    }
}

public struct CompletedPlaybackNote: Equatable, Sendable {
    public let note: KeyboardPlaybackNote
    public let progress: Float

    public init(note: KeyboardPlaybackNote, progress: Float) {
        self.note = note
        self.progress = progress
    }
}

public struct PlaybackKeyVisual: Equatable, Sendable {
    public let upcoming: UpcomingPlaybackNote?
    public let activeNotes: [KeyboardPlaybackNote]
    public let completedNotes: [CompletedPlaybackNote]
    public let flash: Float

    public init(
        upcoming: UpcomingPlaybackNote? = nil,
        activeNotes: [KeyboardPlaybackNote] = [],
        completedNotes: [CompletedPlaybackNote] = [],
        flash: Float = 0
    ) {
        self.upcoming = upcoming
        self.activeNotes = activeNotes
        self.completedNotes = completedNotes
        self.flash = flash
    }

    public var activeTracks: [Int] {
        Array(Set(activeNotes.map(\.track))).sorted()
    }

    public var isActive: Bool { !activeNotes.isEmpty }
}

public struct PlaybackVisualFrame: Equatable, Sendable {
    public let keys: [AxialCoordinate: PlaybackKeyVisual]

    public init(keys: [AxialCoordinate: PlaybackKeyVisual]) {
        self.keys = keys
    }

    public static let empty = PlaybackVisualFrame(keys: [:])
}

public extension PlaybackScore {
    /// Snaps score notes to the nearest visible key without changing `PlaybackNote.audioPitch`.
    func snapToKeyboard(_ layout: HexaKeyboardLayout) -> KeyboardPlaybackTimeline {
        guard !notes.isEmpty, !layout.cells.isEmpty else {
            return .empty
        }
        let pitchIndex = KeyboardPitchIndex(keys: layout.cells)
        var mapped: [KeyboardPlaybackNote] = []
        mapped.reserveCapacity(notes.count)
        var previousByCoordinate: [AxialCoordinate: KeyboardPlaybackNote] = [:]

        for (index, note) in notes.enumerated() {
            guard note.audioPitch.isFinite,
                  let key = pitchIndex.nearest(audioPitch: note.audioPitch) else {
                continue
            }
            let previous = previousByCoordinate[key.coordinate]
            let repeated = previous.map {
                note.start - $0.start <= PLAYBACK_REPEAT_WINDOW_SECONDS
                    || note.start - $0.end <= playbackRepeatGapSeconds
            } ?? false
            let mappedNote = KeyboardPlaybackNote(
                scoreIndex: index,
                coordinate: key.coordinate,
                start: note.start,
                end: max(note.end, note.start),
                audioPitch: note.audioPitch,
                velocity: note.velocity,
                track: note.track,
                repeatedHit: repeated
            )
            mapped.append(mappedNote)
            previousByCoordinate[key.coordinate] = mappedNote
        }

        return KeyboardPlaybackTimeline(
            notes: mapped,
            notesByEnd: mapped.sorted {
                if $0.end != $1.end { return $0.end < $1.end }
                return $0.scoreIndex < $1.scoreIndex
            },
            duration: duration
        )
    }
}

public extension KeyboardPlaybackTimeline {
    func visualFrame(
        at positionSeconds: Double,
        activeScoreIndices: Set<Int>
    ) -> PlaybackVisualFrame {
        guard !notes.isEmpty else { return .empty }
        let position = positionSeconds < 0 ? 0 : positionSeconds
        var builders: [AxialCoordinate: PlaybackKeyVisualBuilder] = [:]

        let upcomingStart = notes.upperBoundByStart(position)
        let upcomingEnd = notes.upperBoundByStart(position + PLAYBACK_PREVIEW_SECONDS)
        var previewNoteCount = 0
        for index in upcomingStart..<upcomingEnd {
            let note = notes[index]
            let noteDelta = note.start - position
            let delta = noteDelta < 0 ? 0 : noteDelta
            let progress = Float(1.0 - delta / PLAYBACK_PREVIEW_SECONDS)
                .clamped(to: 0...1)
            let existingBuilder = builders[note.coordinate]
            if existingBuilder == nil, previewNoteCount >= MAX_PLAYBACK_PREVIEW_NOTES {
                break
            }
            let builder: PlaybackKeyVisualBuilder
            if let existingBuilder {
                builder = existingBuilder
            } else {
                builder = PlaybackKeyVisualBuilder()
                builders[note.coordinate] = builder
            }
            if builder.upcoming == nil || note.start < builder.upcoming!.note.start {
                if builder.upcoming == nil { previewNoteCount += 1 }
                builder.upcoming = UpcomingPlaybackNote(note: note, progress: progress)
            }
        }

        for scoreIndex in activeScoreIndices {
            guard let note = note(forScoreIndex: scoreIndex) else { continue }
            let builder = builders[note.coordinate] ?? PlaybackKeyVisualBuilder()
            builders[note.coordinate] = builder
            builder.active.append(note)
        }

        let completedStart = notesByEnd.lowerBoundByEnd(
            position - PLAYBACK_COMPLETION_BURST_SECONDS
        )
        let completedEnd = notesByEnd.upperBoundByEnd(position)
        for index in completedStart..<completedEnd {
            let note = notesByEnd[index]
            let noteAge = position - note.end
            let age = noteAge < 0 ? 0 : noteAge
            let progress = Float(age / PLAYBACK_COMPLETION_BURST_SECONDS)
                .clamped(to: 0...1)
            let builder = builders[note.coordinate] ?? PlaybackKeyVisualBuilder()
            builders[note.coordinate] = builder
            if builder.completed.count < maxCompletedNotesPerKey {
                builder.completed.append(CompletedPlaybackNote(note: note, progress: progress))
            }
        }

        let recentStart = notes.lowerBoundByStart(position - PLAYBACK_REPEAT_WINDOW_SECONDS)
        let recentEnd = notes.upperBoundByStart(position)
        var recentHitCounts: [AxialCoordinate: Int] = [:]
        for index in recentStart..<recentEnd {
            let note = notes[index]
            recentHitCounts[note.coordinate, default: 0] += 1
            let noteAge = position - note.start
            let age = noteAge < 0 ? 0 : noteAge
            let impact = Float(exp(-age * 12.0))
            let builder = builders[note.coordinate] ?? PlaybackKeyVisualBuilder()
            builders[note.coordinate] = builder
            builder.flash = max(builder.flash, impact)
        }

        for (coordinate, count) in recentHitCounts {
            guard let builder = builders[coordinate] else { continue }
            let repeatedActive = builder.active.contains(where: \.repeatedHit)
            if count >= 2 || repeatedActive {
                let pulse = Float(0.5 + 0.5 * sin(position * Double.pi * 18.0))
                builder.flash = max(builder.flash, 0.34 + pulse * 0.66)
            }
        }

        return PlaybackVisualFrame(
            keys: builders.mapValues { $0.build() }
        )
    }

    /// Spelling-compatible wrapper for code ported directly from Android.
    func visualFrameAt(
        _ positionSeconds: Double,
        activeScoreIndices: Set<Int>
    ) -> PlaybackVisualFrame {
        visualFrame(at: positionSeconds, activeScoreIndices: activeScoreIndices)
    }

    private func note(forScoreIndex scoreIndex: Int) -> KeyboardPlaybackNote? {
        if notes.indices.contains(scoreIndex), notes[scoreIndex].scoreIndex == scoreIndex {
            return notes[scoreIndex]
        }
        return notes.first { $0.scoreIndex == scoreIndex }
    }
}

private final class PlaybackKeyVisualBuilder {
    var upcoming: UpcomingPlaybackNote?
    var active: [KeyboardPlaybackNote] = []
    var completed: [CompletedPlaybackNote] = []
    var flash: Float = 0

    func build() -> PlaybackKeyVisual {
        PlaybackKeyVisual(
            upcoming: upcoming,
            activeNotes: active.sorted {
                if $0.track != $1.track { return $0.track < $1.track }
                return $0.scoreIndex < $1.scoreIndex
            },
            completedNotes: completed,
            flash: flash.clamped(to: 0...1)
        )
    }
}

private final class KeyboardPitchIndex {
    private struct PitchCandidate {
        let pitch: Double
        let key: HexKey
    }

    private let candidates: [PitchCandidate]

    init(keys: [HexKey]) {
        let grouped = Dictionary(grouping: keys.filter { $0.audioPitch.midiPitch.isFinite }) {
            $0.audioPitch.midiPitch
        }
        candidates = grouped.compactMap { pitch, equivalentKeys in
            guard let key = equivalentKeys.min(by: Self.keyPrecedes) else { return nil }
            return PitchCandidate(pitch: pitch, key: key)
        }.sorted { $0.pitch < $1.pitch }
    }

    func nearest(audioPitch: Double) -> HexKey? {
        guard !candidates.isEmpty, audioPitch.isFinite else { return nil }
        var low = 0
        var high = candidates.count
        while low < high {
            let middle = (low + high) >> 1
            if candidates[middle].pitch < audioPitch {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let above = candidates[safe: low]
        let below = candidates[safe: low - 1]
        switch (above, below) {
        case (nil, let below?):
            return below.key
        case (let above?, nil):
            return above.key
        case (let above?, let below?):
            let aboveDistance = abs(above.pitch - audioPitch)
            let belowDistance = abs(audioPitch - below.pitch)
            if aboveDistance < belowDistance { return above.key }
            if aboveDistance > belowDistance { return below.key }

            let aboveCenterDistance = Self.centerDistanceSquared(above.key)
            let belowCenterDistance = Self.centerDistanceSquared(below.key)
            if aboveCenterDistance < belowCenterDistance { return above.key }
            if aboveCenterDistance > belowCenterDistance { return below.key }
            if above.key.coordinate.q < below.key.coordinate.q { return above.key }
            if above.key.coordinate.q > below.key.coordinate.q { return below.key }
            return above.key.coordinate.r <= below.key.coordinate.r ? above.key : below.key
        case (nil, nil):
            return nil
        }
    }

    private static func keyPrecedes(_ first: HexKey, _ second: HexKey) -> Bool {
        let firstDistance = centerDistanceSquared(first)
        let secondDistance = centerDistanceSquared(second)
        if firstDistance != secondDistance { return firstDistance < secondDistance }
        if first.coordinate.q != second.coordinate.q {
            return first.coordinate.q < second.coordinate.q
        }
        return first.coordinate.r < second.coordinate.r
    }

    private static func centerDistanceSquared(_ key: HexKey) -> Double {
        key.center.x * key.center.x + key.center.y * key.center.y
    }
}

private extension [KeyboardPlaybackNote] {
    func lowerBoundByStart(_ value: Double) -> Int {
        lowerBound(value) { $0.start }
    }

    func upperBoundByStart(_ value: Double) -> Int {
        upperBound(value) { $0.start }
    }

    func lowerBoundByEnd(_ value: Double) -> Int {
        lowerBound(value) { $0.end }
    }

    func upperBoundByEnd(_ value: Double) -> Int {
        upperBound(value) { $0.end }
    }
}

private extension Array {
    func lowerBound(_ value: Double, selector: (Element) -> Double) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) >> 1
            if selector(self[middle]) < value {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    func upperBound(_ value: Double, selector: (Element) -> Double) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) >> 1
            if selector(self[middle]) <= value {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
