import Combine
import CoreGraphics
import Foundation
import HexaKeyboardCore

enum KeyboardDisplayMode: String, CaseIterable, Identifiable {
    case coordinates
    case pitch
    case period

    var id: Self { self }

    var title: String {
        switch self {
        case .coordinates: "坐标"
        case .pitch: "音级"
        case .period: "周期"
        }
    }
}

@MainActor
final class KeyboardViewModel: ObservableObject {
    static let minimumKeyboardScale: CGFloat = 0.84
    static let maximumKeyboardScale: CGFloat = 3

    @Published private(set) var configuration: HexaKeyboardConfiguration
    @Published private(set) var layout: HexaKeyboardLayout
    @Published private(set) var touchSelection: TouchSelectionState
    @Published private(set) var playbackState: ScorePlaybackState
    @Published private(set) var playbackTimeline: KeyboardPlaybackTimeline?
    @Published var displayMode: KeyboardDisplayMode = .pitch
    @Published var keyboardScale: CGFloat = minimumKeyboardScale
    @Published var keyboardPan: CGPoint = .zero
    @Published private(set) var touchSensitivityPercent = 120
    @Published private(set) var midiProgramNumber = 0
    @Published private(set) var pseudoPressureEnabled = true
    @Published private(set) var audioReady = false
    @Published private(set) var toastMessage: String?

    let audioEngine: PolyphonicAudioEngine

    private let scoreParser = ScoreContentParser()
    private let playbackController: ScorePlaybackController
    private var touchVoices: [Int: PolyphonicAudioEngine.VoiceToken] = [:]
    private var toastTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(configuration: HexaKeyboardConfiguration = .default) {
        var requested = configuration
        requested.radius = 24
        requested.rotationDegrees = 12
        let normalized = requested.normalized()
        let layout = HexaKeyboardLayoutEngine.build(configuration: normalized)
        let engine = PolyphonicAudioEngine()
        let playbackController = ScorePlaybackController(audioEngine: engine)

        self.configuration = normalized
        self.layout = layout
        touchSelection = TouchSelectionState(
            latchedCoordinates: layout.defaultSelection.map { [$0.coordinate] } ?? [],
            anchorCoordinate: layout.defaultSelection?.coordinate
        )
        audioEngine = engine
        self.playbackController = playbackController
        playbackState = playbackController.state
        playbackTimeline = nil
        audioReady = engine.isReady

        playbackController.stateDidChange = { [weak self] state in
            guard let self else { return }
            playbackState = state
        }
        engine.$isReady
            .removeDuplicates()
            .sink { [weak self] ready in self?.audioReady = ready }
            .store(in: &cancellables)
    }

    var selectedCoordinates: Set<AxialCoordinate> {
        touchSelection.selectedCoordinates
    }

    var selectionAnchorCoordinate: AxialCoordinate? {
        touchSelection.anchorCoordinate
    }

    func applyConfiguration(_ requestedConfiguration: HexaKeyboardConfiguration) {
        releaseAllTouches()
        keyboardPan = .zero

        var requested = requestedConfiguration
        requested.radius = 24
        requested.rotationDegrees = 12
        let normalized = requested.normalized()
        configuration = normalized
        layout = HexaKeyboardLayoutEngine.build(configuration: normalized)
        touchSelection = touchSelection.retainingCoordinates(
            Set(layout.cells.map(\.coordinate)),
            fallbackCoordinate: layout.defaultSelection?.coordinate
        )
        rebuildPlaybackTimeline()
    }

    func panKeyboard(by delta: CGSize) {
        guard delta.width.isFinite, delta.height.isFinite else { return }
        keyboardPan = CGPoint(
            x: keyboardPan.x + delta.width,
            y: keyboardPan.y + delta.height
        )
    }

    func zoomKeyboard(by multiplier: CGFloat) {
        guard multiplier.isFinite, multiplier > 0 else { return }
        keyboardScale = (keyboardScale * multiplier)
            .clamped(to: Self.minimumKeyboardScale...Self.maximumKeyboardScale)
    }

    func updateConstrainedPan(_ pan: CGPoint) {
        guard keyboardPan != pan else { return }
        keyboardPan = pan
    }

    func setTouchSensitivityPercent(_ value: Int) {
        touchSensitivityPercent = value.clamped(to: 100...150)
    }

    func setMIDIProgramNumber(_ value: Int) {
        let next = value.clamped(to: 0...127)
        guard next != midiProgramNumber else { return }
        releaseAllTouches()
        midiProgramNumber = next
    }

    func setPseudoPressureEnabled(_ enabled: Bool) {
        pseudoPressureEnabled = enabled
    }

    func keyDown(
        pointerID: Int,
        key: HexKey,
        velocity: Int,
        eventTimeMilliseconds: Int64
    ) {
        if let previous = touchVoices.removeValue(forKey: pointerID) {
            audioEngine.release(previous)
        }
        touchSelection = touchSelection.pressing(
            pointerID: pointerID,
            coordinate: key.coordinate,
            eventTimeMilliseconds: eventTimeMilliseconds
        )

        guard key.audioPitch.isPlayable else { return }
        do {
            touchVoices[pointerID] = try audioEngine.start(
                pitch: key.audioPitch.midiPitch,
                velocity: velocity,
                program: midiProgramNumber
            )
        } catch {
            // PolyphonicAudioEngine publishes its own localized status.
        }
    }

    func keyPressure(pointerID: Int, expression: Int) {
        guard let token = touchVoices[pointerID] else { return }
        audioEngine.setPressure(token, expression: expression)
    }

    func keyUp(
        pointerID: Int,
        eventTimeMilliseconds: Int64,
        retainForChord: Bool
    ) {
        if let token = touchVoices.removeValue(forKey: pointerID) {
            audioEngine.release(token)
        }
        touchSelection = touchSelection.releasing(
            pointerID: pointerID,
            eventTimeMilliseconds: eventTimeMilliseconds,
            retainForChord: retainForChord
        )
    }

    func releaseAllTouches() {
        for token in touchVoices.values {
            audioEngine.release(token)
        }
        touchVoices.removeAll(keepingCapacity: true)
        touchSelection = touchSelection.releasingAll()
    }

    func beginLoadingScore() {
        releaseAllTouches()
        playbackController.beginLoading()
    }

    func loadScore(from url: URL) {
        beginLoadingScore()
        let parser = scoreParser

        Task { [weak self] in
            guard let self else { return }
            do {
                let (fileName, score) = try await Task.detached(priority: .userInitiated) {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer {
                        if accessing { url.stopAccessingSecurityScopedResource() }
                    }
                    let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey])
                    if let size = resourceValues?.fileSize,
                       size > ScoreContentParser.maximumFileBytes {
                        throw ScoreContentParserError.fileTooLarge(
                            maximumBytes: ScoreContentParser.maximumFileBytes
                        )
                    }
                    let data = try Self.readScoreData(
                        from: url,
                        maximumBytes: ScoreContentParser.maximumFileBytes,
                        expectedSize: resourceValues?.fileSize
                    )
                    let fileName = url.lastPathComponent.isEmpty ? "selected-file" : url.lastPathComponent
                    return (
                        fileName,
                        try parser.parseScore(fileName: fileName, data: data)
                    )
                }.value

                playbackController.load(score, fileName: fileName)
                rebuildPlaybackTimeline()
                showToast("已加载 \(fileName)")
            } catch {
                playbackController.loadingFailed()
                reportFileOpenFailure(error)
            }
        }
    }

    func reportFileOpenFailure(_ error: Error) {
        showToast(
            "文件打开失败：\(error.localizedDescription)",
            durationNanoseconds: 3_500_000_000
        )
    }

    func loadScore(data: Data, fileName: String) async throws {
        beginLoadingScore()
        do {
            let parser = scoreParser
            let score = try await Task.detached(priority: .userInitiated) {
                try parser.parseScore(fileName: fileName, data: data)
            }.value
            playbackController.load(score, fileName: fileName)
            rebuildPlaybackTimeline()
        } catch {
            playbackController.loadingFailed()
            throw error
        }
    }

    func togglePlayPause() {
        playbackController.togglePlayPause()
    }

    func resetPlayback() {
        playbackController.reset()
    }

    func terminatePlayback() {
        playbackController.terminate()
        playbackTimeline = nil
    }

    func activateAudio() {
        audioEngine.activateForForeground()
    }

    func deactivateAudio() {
        playbackController.pause()
        releaseAllTouches()
        audioEngine.deactivateForBackground()
    }

    func close() {
        playbackController.close()
        releaseAllTouches()
        audioEngine.allOff()
    }

    private func rebuildPlaybackTimeline() {
        playbackTimeline = playbackState.score?.snapToKeyboard(layout)
    }

    private func showToast(
        _ message: String,
        durationNanoseconds: UInt64 = 2_000_000_000
    ) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { @MainActor [weak self] in
            do {
                try await Task<Never, Never>.sleep(nanoseconds: durationNanoseconds)
            } catch {
                return
            }
            self?.toastMessage = nil
        }
    }

    nonisolated private static func readScoreData(
        from url: URL,
        maximumBytes: Int,
        expectedSize: Int?
    ) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var data = Data()
        if let expectedSize, expectedSize > 0, expectedSize <= maximumBytes {
            data.reserveCapacity(expectedSize)
        }

        let chunkSize = 64 * 1_024
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            guard data.count <= maximumBytes - chunk.count else {
                throw ScoreContentParserError.fileTooLarge(maximumBytes: maximumBytes)
            }
            data.append(chunk)
        }
        return data
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
