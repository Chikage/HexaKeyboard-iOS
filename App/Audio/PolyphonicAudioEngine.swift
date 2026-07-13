import AVFoundation
import Combine
import Foundation

/// A small SoundFont-backed engine for independently tuned multitouch notes.
///
/// Pitch is expressed as a floating-point MIDI note. Each active touch owns a
/// melodic MIDI channel so that its pitch bend cannot retune another voice.
@MainActor
final class PolyphonicAudioEngine: NSObject, ObservableObject {
    struct VoiceToken: Hashable, Sendable {
        fileprivate let rawValue: UInt64
    }

    @Published private(set) var statusText = "音频未启动"
    @Published private(set) var isReady = false
    @Published private(set) var activeVoiceCount = 0

    private struct ActiveVoice {
        let token: VoiceToken
        let channel: UInt8
        let noteNumber: UInt8
        let order: UInt64
        let startedAt: TimeInterval
    }

    private enum AudioEngineError: LocalizedError {
        case invalidPitch
        case missingSoundFont
        case soundFontLoadFailed(String)
        case noPlaybackChannel

        var errorDescription: String? {
            switch self {
            case .invalidPitch:
                return "音高必须能映射到 0...127 之间的 MIDI 键。"
            case .missingSoundFont:
                return "找不到 DefaultSoundFont.sf2。请确认资源已加入 App target。"
            case let .soundFontLoadFailed(message):
                return "SoundFont 加载失败：\(message)"
            case .noPlaybackChannel:
                return "没有可用的 MIDI 播放通道。"
            }
        }
    }

    private static let soundFontName = "DefaultSoundFont"
    private static let centerPitchBend = UInt16(8_192)
    private static let pitchBendRangeCents = 200.0
    private static let minimumTapDuration: TimeInterval = 0.22
    private static let melodicChannels: [UInt8] = (0..<16)
        .filter { $0 != 9 }
        .map(UInt8.init)

    private let audioSession = AVAudioSession.sharedInstance()
    private var engine = AVAudioEngine()
    private var sampler = AVAudioUnitSampler()
    private var earlyReflectionDelay = AVAudioUnitDelay()
    private var reverb = AVAudioUnitReverb()
    private var graphIsConfigured = false
    private var sessionIsConfigured = false
    private var channelsAreConfigured = false
    private var wantsAudioActive = false
    private var wasRunningBeforeInterruption = false

    private var activeVoices: [VoiceToken: ActiveVoice] = [:]
    private var channelOwners: [UInt8: VoiceToken] = [:]
    private var pendingReleaseTasks: [VoiceToken: Task<Void, Never>] = [:]
    private var nextTokenValue: UInt64 = 1
    private var nextVoiceOrder: UInt64 = 1

    override init() {
        super.init()

        let notifications = NotificationCenter.default
        notifications.addObserver(
            self,
            selector: #selector(audioSessionInterrupted(_:)),
            name: AVAudioSession.interruptionNotification,
            object: audioSession
        )
        notifications.addObserver(
            self,
            selector: #selector(audioRouteChanged(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: audioSession
        )
        notifications.addObserver(
            self,
            selector: #selector(audioMediaServicesWereReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: audioSession
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Prepares the session, graph, and bundled SoundFont before the first touch.
    func prepare() throws {
        wantsAudioActive = true

        do {
            try configureAudioSessionIfNeeded()
            try configureGraphIfNeeded()

            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }

            configureChannelsIfNeeded()
            isReady = true
            updateRunningStatus()
        } catch {
            publishFailure(error)
            throw error
        }
    }

    /// Starts one independently tuned voice and returns the token needed to release it.
    ///
    /// - Parameter pitch: MIDI pitch in semitones; fractional values are microtonal.
    @discardableResult
    func start(pitch: Double, velocity: Int = 100) throws -> VoiceToken {
        let roundedNote = pitch.isFinite ? Int(floor(pitch + 0.5)) : -1
        guard pitch.isFinite, (0...127).contains(roundedNote) else {
            let error = AudioEngineError.invalidPitch
            publishFailure(error)
            throw error
        }

        try prepare()

        let token = makeToken()
        let channel = try allocateChannel(for: token)
        let noteNumber = UInt8(roundedNote)
        let cents = (pitch - Double(noteNumber)) * 100.0
        let pitchBend = Self.pitchBendValue(forCents: cents)

        sampler.sendPitchBend(pitchBend, onChannel: channel)
        sampler.startNote(
            noteNumber,
            withVelocity: UInt8(clamping: max(1, min(velocity, 127))),
            onChannel: channel
        )

        let voice = ActiveVoice(
            token: token,
            channel: channel,
            noteNumber: noteNumber,
            order: nextVoiceOrder,
            startedAt: ProcessInfo.processInfo.systemUptime
        )
        nextVoiceOrder = incrementing(nextVoiceOrder)
        activeVoices[token] = voice
        channelOwners[channel] = token
        updateRunningStatus()
        return token
    }

    /// Releases exactly the voice represented by `token`.
    func release(_ token: VoiceToken) {
        guard let voice = activeVoices[token], pendingReleaseTasks[token] == nil else {
            return
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - voice.startedAt
        let remaining = Self.minimumTapDuration - elapsed
        guard remaining > 0 else {
            finishRelease(token)
            return
        }

        let nanoseconds = UInt64((remaining * 1_000_000_000).rounded(.up))
        pendingReleaseTasks[token] = Task { @MainActor [weak self] in
            do {
                try await Task<Never, Never>.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            self?.finishRelease(token)
        }
    }

    /// Stops every touch voice immediately, including delayed short-tap releases.
    func allOff() {
        stopAllVoices()
        updateRunningStatus()
    }

    /// Call when the app returns to an active foreground scene.
    func activateForForeground() {
        wantsAudioActive = true
        do {
            try prepare()
        } catch {
            // `prepare()` has already published the localized failure.
        }
    }

    /// Call when the app leaves the active scene if background audio is not desired.
    func deactivateForBackground() {
        wantsAudioActive = false
        stopAllVoices()
        engine.pause()

        do {
            try audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            publishFailure(error)
            return
        }

        sessionIsConfigured = false
        isReady = false
        statusText = "音频已暂停"
    }

    private func configureAudioSessionIfNeeded() throws {
        guard !sessionIsConfigured else {
            return
        }

        try audioSession.setCategory(.playback, mode: .default, options: [])
        try audioSession.setPreferredSampleRate(48_000)
        try audioSession.setPreferredIOBufferDuration(0.0058)
        try audioSession.setActive(true)
        sessionIsConfigured = true
    }

    private func configureGraphIfNeeded() throws {
        guard !graphIsConfigured else {
            return
        }

        let soundFontURL = try bundledSoundFontURL()
        try loadDefaultInstrument(from: soundFontURL)

        earlyReflectionDelay.delayTime = 0.018
        earlyReflectionDelay.wetDryMix = 4.5
        earlyReflectionDelay.feedback = 3
        earlyReflectionDelay.lowPassCutoff = 7_800
        reverb.loadFactoryPreset(.largeHall)
        reverb.wetDryMix = 36.7

        engine.attach(sampler)
        engine.attach(earlyReflectionDelay)
        engine.attach(reverb)
        engine.connect(sampler, to: earlyReflectionDelay, format: nil)
        engine.connect(earlyReflectionDelay, to: reverb, format: nil)
        engine.connect(reverb, to: engine.mainMixerNode, format: nil)
        graphIsConfigured = true
    }

    private func loadDefaultInstrument(from url: URL) throws {
        let candidateBanks: [UInt8] = [0x79, 0x00]
        var lastError: Error?

        for bankMSB in candidateBanks {
            do {
                try sampler.loadSoundBankInstrument(
                    at: url,
                    program: 0,
                    bankMSB: bankMSB,
                    bankLSB: 0
                )
                sampler.volume = 1.0
                return
            } catch {
                lastError = error
            }
        }

        throw AudioEngineError.soundFontLoadFailed(
            lastError?.localizedDescription ?? "未知错误"
        )
    }

    private func bundledSoundFontURL() throws -> URL {
        if let url = Bundle.main.url(
            forResource: Self.soundFontName,
            withExtension: "sf2"
        ) {
            return url
        }

        let subdirectories = ["Audio", "Resources/Audio", "App/Resources/Audio"]
        for subdirectory in subdirectories {
            if let url = Bundle.main.url(
                forResource: Self.soundFontName,
                withExtension: "sf2",
                subdirectory: subdirectory
            ) {
                return url
            }
        }

        throw AudioEngineError.missingSoundFont
    }

    private func configureChannelsIfNeeded() {
        guard !channelsAreConfigured else {
            return
        }

        for channel in Self.melodicChannels {
            // RPN 0,0: pitch bend sensitivity = two semitones, zero cents.
            sampler.sendController(101, withValue: 0, onChannel: channel)
            sampler.sendController(100, withValue: 0, onChannel: channel)
            sampler.sendController(6, withValue: 2, onChannel: channel)
            sampler.sendController(38, withValue: 0, onChannel: channel)
            sampler.sendController(101, withValue: 127, onChannel: channel)
            sampler.sendController(100, withValue: 127, onChannel: channel)
            sampler.sendPitchBend(Self.centerPitchBend, onChannel: channel)
        }

        channelsAreConfigured = true
    }

    private func allocateChannel(for token: VoiceToken) throws -> UInt8 {
        if let freeChannel = Self.melodicChannels.first(where: { channelOwners[$0] == nil }) {
            return freeChannel
        }

        guard let oldest = activeVoices.values.min(by: { $0.order < $1.order }) else {
            throw AudioEngineError.noPlaybackChannel
        }

        activeVoices.removeValue(forKey: oldest.token)
        channelOwners.removeValue(forKey: oldest.channel)
        pendingReleaseTasks.removeValue(forKey: oldest.token)?.cancel()
        stop(oldest)
        return oldest.channel
    }

    private func finishRelease(_ token: VoiceToken) {
        pendingReleaseTasks.removeValue(forKey: token)
        guard let voice = activeVoices.removeValue(forKey: token) else { return }
        stop(voice)
        channelOwners.removeValue(forKey: voice.channel)
        updateRunningStatus()
    }

    private func stop(_ voice: ActiveVoice) {
        sampler.stopNote(voice.noteNumber, onChannel: voice.channel)
    }

    private func stopAllVoices() {
        for task in pendingReleaseTasks.values {
            task.cancel()
        }
        pendingReleaseTasks.removeAll(keepingCapacity: true)
        for voice in activeVoices.values {
            stop(voice)
        }
        activeVoices.removeAll(keepingCapacity: true)
        channelOwners.removeAll(keepingCapacity: true)
        activeVoiceCount = 0
    }

    private func makeToken() -> VoiceToken {
        let token = VoiceToken(rawValue: nextTokenValue)
        nextTokenValue = incrementing(nextTokenValue)
        return token
    }

    private func incrementing(_ value: UInt64) -> UInt64 {
        value == UInt64.max ? 1 : value + 1
    }

    private func updateRunningStatus() {
        activeVoiceCount = activeVoices.count
        if isReady {
            statusText = activeVoiceCount == 0
                ? "音频已就绪"
                : "正在发声（\(activeVoiceCount) 音）"
        }
    }

    private func publishFailure(_ error: Error) {
        isReady = false
        statusText = "音频错误：\(error.localizedDescription)"
    }

    private func handleInterruption(typeRawValue: UInt, optionsRawValue: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: typeRawValue) else {
            return
        }

        switch type {
        case .began:
            wasRunningBeforeInterruption = wantsAudioActive && engine.isRunning
            stopAllVoices()
            engine.pause()
            sessionIsConfigured = false
            isReady = false
            statusText = "音频已中断"

        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRawValue)
            guard wasRunningBeforeInterruption, options.contains(.shouldResume) else {
                statusText = "音频等待恢复"
                return
            }

            do {
                try prepare()
            } catch {
                // `prepare()` has already published the localized failure.
            }

        @unknown default:
            break
        }
    }

    private func recoverAfterRouteChange() {
        guard wantsAudioActive, !engine.isRunning else {
            return
        }

        sessionIsConfigured = false
        do {
            try prepare()
        } catch {
            // `prepare()` has already published the localized failure.
        }
    }

    private func rebuildAfterMediaServicesReset() {
        let shouldRestart = wantsAudioActive
        stopAllVoices()
        engine.stop()

        engine = AVAudioEngine()
        sampler = AVAudioUnitSampler()
        earlyReflectionDelay = AVAudioUnitDelay()
        reverb = AVAudioUnitReverb()
        graphIsConfigured = false
        sessionIsConfigured = false
        channelsAreConfigured = false
        isReady = false
        statusText = "正在恢复音频"

        guard shouldRestart else {
            statusText = "音频已暂停"
            return
        }

        do {
            try prepare()
        } catch {
            // `prepare()` has already published the localized failure.
        }
    }

    @objc nonisolated private func audioSessionInterrupted(_ notification: Notification) {
        let typeRawValue = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
        let optionsRawValue = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
        guard let typeRawValue else {
            return
        }

        Task { @MainActor [weak self] in
            self?.handleInterruption(
                typeRawValue: typeRawValue,
                optionsRawValue: optionsRawValue
            )
        }
    }

    @objc nonisolated private func audioRouteChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.recoverAfterRouteChange()
        }
    }

    @objc nonisolated private func audioMediaServicesWereReset(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.rebuildAfterMediaServicesReset()
        }
    }

    private static func pitchBendValue(forCents cents: Double) -> UInt16 {
        let normalized = max(-1.0, min(1.0, cents / pitchBendRangeCents))
        let value = Int(centerPitchBend) + Int((normalized * 8_191.0).rounded())
        return UInt16(clamping: value)
    }
}
