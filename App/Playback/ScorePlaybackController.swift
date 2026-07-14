import Foundation
import HexaKeyboardCore
import QuartzCore

struct ScorePlaybackState {
    var score: PlaybackScore?
    var fileName: String?
    var playheadSeconds: Double
    var playing: Bool
    var loading: Bool
    var activeScoreIndices: Set<Int>

    init(
        score: PlaybackScore? = nil,
        fileName: String? = nil,
        playheadSeconds: Double = 0,
        playing: Bool = false,
        loading: Bool = false,
        activeScoreIndices: Set<Int> = []
    ) {
        self.score = score
        self.fileName = fileName
        self.playheadSeconds = playheadSeconds
        self.playing = playing
        self.loading = loading
        self.activeScoreIndices = activeScoreIndices
    }

    var playbackMode: Bool { score != nil }
    var durationSeconds: Double { score?.duration ?? 0 }
}

@MainActor
final class ScorePlaybackController {
    private(set) var state = ScorePlaybackState() {
        didSet { stateDidChange?(state) }
    }

    var stateDidChange: ((ScorePlaybackState) -> Void)?

    private let audioEngine: PolyphonicAudioEngine
    private var activeVoices: [Int: PolyphonicAudioEngine.VoiceToken] = [:]
    private var audioCursor = 0
    private var displayLink: CADisplayLink?
    private var lastFrameTimestamp: CFTimeInterval = 0
    private var visualTailActive = false
    private var closed = false
    private lazy var displayLinkProxy = DisplayLinkProxy(owner: self)

    init(audioEngine: PolyphonicAudioEngine) {
        self.audioEngine = audioEngine
    }

    func beginLoading() {
        guard !closed else { return }
        let finishingScore = visualTailActive ? state.score : nil
        stopClock()
        visualTailActive = false
        stopScheduledAudio()
        state.playheadSeconds = finishingScore.map {
            $0.duration + PLAYBACK_COMPLETION_BURST_SECONDS
        } ?? state.playheadSeconds
        state.playing = false
        state.loading = true
        state.activeScoreIndices = []
    }

    func load(_ score: PlaybackScore, fileName: String) {
        guard !closed else { return }
        stopClock()
        visualTailActive = false
        stopScheduledAudio()
        audioCursor = 0
        state = ScorePlaybackState(score: score, fileName: fileName)
    }

    func loadingFailed() {
        guard !closed else { return }
        state.loading = false
    }

    func togglePlayPause() {
        state.playing ? pause() : play()
    }

    func play() {
        guard !closed else { return }
        stopClock()
        visualTailActive = false
        guard let score = state.score, !state.loading, !score.notes.isEmpty else { return }

        let position = state.playheadSeconds >= score.duration - Self.playbackEpsilonSeconds
            ? 0
            : max(0, state.playheadSeconds)
        stopScheduledAudio()
        resetAudioCursor(score: score, positionSeconds: position)
        lastFrameTimestamp = 0
        state.playheadSeconds = position
        state.playing = true
        state.activeScoreIndices = []
        scheduleAudio(score: score, positionSeconds: position)
        publishActiveNotes(score: score, positionSeconds: position)
        startClock()
    }

    func pause() {
        guard !closed else { return }
        stopClock()
        let finishingScore = visualTailActive ? state.score : nil
        visualTailActive = false
        stopScheduledAudio()
        state.playheadSeconds = finishingScore.map {
            $0.duration + PLAYBACK_COMPLETION_BURST_SECONDS
        } ?? state.playheadSeconds
        state.playing = false
        state.activeScoreIndices = []
    }

    func reset() {
        guard !closed, state.score != nil else { return }
        stopClock()
        visualTailActive = false
        stopScheduledAudio()
        audioCursor = 0
        state.playheadSeconds = 0
        state.playing = false
        state.activeScoreIndices = []
    }

    func terminate() {
        guard !closed else { return }
        stopClock()
        visualTailActive = false
        stopScheduledAudio()
        audioCursor = 0
        state = ScorePlaybackState()
    }

    func close() {
        guard !closed else { return }
        stopClock()
        visualTailActive = false
        stopScheduledAudio()
        closed = true
    }

    fileprivate func handleFrame(_ displayLink: CADisplayLink) {
        guard !closed, state.playing || visualTailActive, let score = state.score else {
            stopClock()
            return
        }

        let timestamp = displayLink.timestamp
        let deltaSeconds: Double
        if lastFrameTimestamp == 0 {
            deltaSeconds = 0
        } else {
            deltaSeconds = (timestamp - lastFrameTimestamp)
                .clamped(to: 0...Self.maximumFrameDeltaSeconds)
        }
        lastFrameTimestamp = timestamp

        if visualTailActive {
            let tailEnd = score.duration + PLAYBACK_COMPLETION_BURST_SECONDS
            let position = min(tailEnd, state.playheadSeconds + deltaSeconds)
            if position >= tailEnd - Self.playbackEpsilonSeconds {
                visualTailActive = false
                state.playheadSeconds = tailEnd
                state.playing = false
                state.activeScoreIndices = []
                stopClock()
                return
            }
            state.playheadSeconds = position
            state.playing = false
            state.activeScoreIndices = []
            return
        }

        let position = min(score.duration, state.playheadSeconds + deltaSeconds)
        scheduleAudio(score: score, positionSeconds: position)

        if position >= score.duration - Self.playbackEpsilonSeconds {
            stopScheduledAudio()
            visualTailActive = true
            state.playheadSeconds = score.duration
            state.playing = false
            state.activeScoreIndices = []
            return
        }

        state.playheadSeconds = position
        publishActiveNotes(score: score, positionSeconds: position)
    }

    private func scheduleAudio(score: PlaybackScore, positionSeconds: Double) {
        let ended = activeVoices.keys.filter { scoreIndex in
            guard let note = score.notes[safe: scoreIndex] else { return true }
            return note.end <= positionSeconds + Self.playbackEpsilonSeconds
        }
        for scoreIndex in ended {
            if let token = activeVoices.removeValue(forKey: scoreIndex) {
                audioEngine.release(token, immediate: true)
            }
        }

        let horizon = positionSeconds + Self.audioLookaheadSeconds
        while audioCursor < score.notes.count {
            let note = score.notes[audioCursor]
            guard note.start.isFinite, note.end.isFinite, note.audioPitch.isFinite else {
                audioCursor += 1
                continue
            }
            if note.end <= positionSeconds + Self.playbackEpsilonSeconds {
                audioCursor += 1
                continue
            }
            if note.start > horizon { break }

            let delaySeconds = max(0, note.start - positionSeconds)
            if let token = try? audioEngine.start(
                pitch: note.audioPitch,
                velocity: note.velocity,
                program: note.program,
                sourceChannel: note.channel,
                bankMSB: note.bankMsb,
                bankLSB: note.bankLsb,
                delaySeconds: delaySeconds
            ) {
                activeVoices[audioCursor] = token
            }
            audioCursor += 1
        }
    }

    private func publishActiveNotes(score: PlaybackScore, positionSeconds: Double) {
        let active = Set(activeVoices.keys.filter { scoreIndex in
            guard let note = score.notes[safe: scoreIndex] else { return false }
            return note.start <= positionSeconds + Self.playbackEpsilonSeconds
                && note.end > positionSeconds + Self.playbackEpsilonSeconds
        })
        if state.activeScoreIndices != active {
            state.activeScoreIndices = active
        }
    }

    private func resetAudioCursor(score: PlaybackScore, positionSeconds: Double) {
        audioCursor = score.notes.firstIndex {
            $0.end > positionSeconds + Self.playbackEpsilonSeconds
        } ?? score.notes.endIndex
    }

    private func stopScheduledAudio() {
        for token in activeVoices.values {
            audioEngine.release(token, immediate: true)
        }
        activeVoices.removeAll(keepingCapacity: true)
    }

    private func startClock() {
        guard displayLink == nil, !closed else { return }
        let link = CADisplayLink(target: displayLinkProxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopClock() {
        displayLink?.invalidate()
        displayLink = nil
        lastFrameTimestamp = 0
    }

    private static let audioLookaheadSeconds = 0.18
    private static let playbackEpsilonSeconds = 0.002
    private static let maximumFrameDeltaSeconds = 0.08
}

@MainActor
private final class DisplayLinkProxy: NSObject {
    weak var owner: ScorePlaybackController?

    init(owner: ScorePlaybackController) {
        self.owner = owner
    }

    @objc func tick(_ displayLink: CADisplayLink) {
        owner?.handleFrame(displayLink)
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
