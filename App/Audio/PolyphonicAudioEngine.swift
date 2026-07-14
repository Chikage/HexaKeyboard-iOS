import AVFoundation
import Combine
import Dispatch
import Foundation

private struct ScheduledMIDICommand: @unchecked Sendable {
    let perform: () -> Void
}

/// Runs future MIDI starts independently of the main actor.
///
/// Every command is serialized on the same high-priority queue. Cancelling a
/// token synchronously removes its future start before sending Note Off, so an
/// address can be safely reused as soon as cancellation returns.
private final class ScheduledMIDIExecutor: @unchecked Sendable {
    private struct Entry {
        let generation: UInt64
        var started: Bool
    }

    private let queue = DispatchQueue(
        label: "icu.ringona.hexakeyboard.midi-scheduler",
        qos: .userInteractive
    )
    private var entries: [UInt64: Entry] = [:]
    private var nextGeneration: UInt64 = 1

    func scheduleDelayedStart(
        token: UInt64,
        startAfter delaySeconds: TimeInterval,
        stopAfter automaticStopSeconds: TimeInterval?,
        start: ScheduledMIDICommand,
        stop: ScheduledMIDICommand
    ) {
        let startDeadline = Self.deadline(after: delaySeconds)
        let stopDeadline = automaticStopSeconds.map { Self.deadline(after: $0) }

        queue.sync {
            let generation = makeGeneration()
            entries[token] = Entry(generation: generation, started: false)

            queue.asyncAfter(deadline: startDeadline) { [weak self] in
                guard let self,
                      var entry = self.entries[token],
                      entry.generation == generation else {
                    return
                }

                // If the scheduler itself was delayed past the note end, do
                // not emit a stale Note On followed by a catch-up Note Off.
                if let stopDeadline, DispatchTime.now() >= stopDeadline {
                    self.entries.removeValue(forKey: token)
                    return
                }

                entry.started = true
                self.entries[token] = entry
                start.perform()
            }

            if let stopDeadline {
                queue.asyncAfter(deadline: stopDeadline) { [weak self] in
                    guard let self,
                          let entry = self.entries[token],
                          entry.generation == generation else {
                        return
                    }
                    self.entries.removeValue(forKey: token)
                    if entry.started {
                        stop.perform()
                    }
                }
            }
        }
    }

    func registerStartedVoice(
        token: UInt64,
        stopAfter automaticStopSeconds: TimeInterval,
        stop: ScheduledMIDICommand
    ) {
        scheduleStop(
            token: token,
            after: automaticStopSeconds,
            stop: stop,
            completion: nil
        )
    }

    func scheduleStop(
        token: UInt64,
        after delaySeconds: TimeInterval,
        stop: ScheduledMIDICommand,
        completion: ScheduledMIDICommand?
    ) {
        let stopDeadline = Self.deadline(after: delaySeconds)
        queue.sync {
            let generation = makeGeneration()
            entries[token] = Entry(generation: generation, started: true)
            queue.asyncAfter(deadline: stopDeadline) { [weak self] in
                guard let self,
                      let entry = self.entries[token],
                      entry.generation == generation else {
                    return
                }
                self.entries.removeValue(forKey: token)
                stop.perform()
                completion?.perform()
            }
        }
    }

    func cancelAndStop(token: UInt64, stop: ScheduledMIDICommand) {
        queue.sync {
            entries.removeValue(forKey: token)
            stop.perform()
        }
    }

    func performSynchronously(_ command: ScheduledMIDICommand) {
        queue.sync {
            command.perform()
        }
    }

    func cancelAllAndStop(_ stops: [ScheduledMIDICommand]) {
        queue.sync {
            entries.removeAll(keepingCapacity: true)
            for stop in stops {
                stop.perform()
            }
        }
    }

#if DEBUG
    func runReleaseRaceSelfTest() {
        let cancelledStop = DispatchSemaphore(value: 0)
        let cancelledCompletion = DispatchSemaphore(value: 0)
        scheduleStop(
            token: 1,
            after: 0.02,
            stop: ScheduledMIDICommand { cancelledStop.signal() },
            completion: ScheduledMIDICommand { cancelledCompletion.signal() }
        )
        cancelAndStop(token: 1, stop: ScheduledMIDICommand {})
        precondition(cancelledStop.wait(timeout: .now() + 0.06) == .timedOut)
        precondition(cancelledCompletion.wait(timeout: .now()) == .timedOut)

        let oldCompletion = DispatchSemaphore(value: 0)
        let newStop = DispatchSemaphore(value: 0)
        let newCompletion = DispatchSemaphore(value: 0)
        scheduleStop(
            token: 2,
            after: 0.05,
            stop: ScheduledMIDICommand {},
            completion: ScheduledMIDICommand { oldCompletion.signal() }
        )
        scheduleStop(
            token: 2,
            after: 0.01,
            stop: ScheduledMIDICommand { newStop.signal() },
            completion: ScheduledMIDICommand { newCompletion.signal() }
        )
        precondition(newStop.wait(timeout: .now() + 0.2) == .success)
        precondition(newCompletion.wait(timeout: .now() + 0.2) == .success)
        precondition(oldCompletion.wait(timeout: .now() + 0.08) == .timedOut)
        print("HEX_AUDIO_RELEASE_RACE_SELF_TEST_PASSED")
    }
#endif

    private func makeGeneration() -> UInt64 {
        let generation = nextGeneration
        nextGeneration = nextGeneration == UInt64.max ? 1 : nextGeneration + 1
        return generation
    }

    private static func deadline(after seconds: TimeInterval) -> DispatchTime {
        let safeSeconds = seconds.isFinite ? max(0, seconds) : 0
        let maximumSeconds = Double(UInt64.max) / 1_000_000_000
        let nanoseconds = safeSeconds >= maximumSeconds
            ? UInt64.max
            : UInt64((safeSeconds * 1_000_000_000).rounded(.up))
        let now = DispatchTime.now().uptimeNanoseconds
        let (sum, overflowed) = now.addingReportingOverflow(nanoseconds)
        return DispatchTime(uptimeNanoseconds: overflowed ? UInt64.max : sum)
    }
}

/// A SoundFont-backed engine for independently tuned multitouch notes.
///
/// Pitch is expressed as a floating-point MIDI note. Each active touch owns one
/// melodic MIDI channel in a four-sampler pool so that its pitch bend cannot
/// retune another voice. This provides 60 independent tuning addresses.
@MainActor
final class PolyphonicAudioEngine: NSObject, ObservableObject {
    struct VoiceToken: Hashable, Sendable {
        fileprivate let rawValue: UInt64
    }

    @Published private(set) var statusText = "音频未启动"
    @Published private(set) var isReady = false
    @Published private(set) var activeVoiceCount = 0

    private struct VoiceAddress: Hashable {
        let samplerIndex: Int
        let channel: UInt8
    }

    private struct ActiveVoice {
        let token: VoiceToken
        let address: VoiceAddress
        let noteNumber: UInt8
        let velocity: UInt8
        let order: UInt64
        let releaseDelay: TimeInterval
        let scheduledStartUptimeNanoseconds: UInt64
        var startedAt: TimeInterval?
        var expression: UInt8
        var releaseGeneration: UInt64?
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
    private static let samplerPoolSize = 4
    private static let melodicChannels: [UInt8] = (0..<16)
        .filter { $0 != 9 }
        .map(UInt8.init)

    private let audioSession = AVAudioSession.sharedInstance()
    private var engine = AVAudioEngine()
    private var samplers = (0..<samplerPoolSize).map { _ in AVAudioUnitSampler() }
    private var samplerMixer = AVAudioMixerNode()
    private var earlyReflectionDelay = AVAudioUnitDelay()
    private var reverb = AVAudioUnitReverb()
    private var graphIsConfigured = false
    private var sessionIsConfigured = false
    private var channelsAreConfigured = false
    private var defaultBankMSB: UInt8 = 0x79
    private var wantsAudioActive = false
    private var wasRunningBeforeInterruption = false

    private var activeVoices: [VoiceToken: ActiveVoice] = [:]
    private var channelOwners: [VoiceAddress: VoiceToken] = [:]
    private let scheduledMIDIExecutor = ScheduledMIDIExecutor()
    private var nextTokenValue: UInt64 = 1
    private var nextVoiceOrder: UInt64 = 1
    private var nextReleaseGeneration: UInt64 = 1

    override init() {
        super.init()

#if DEBUG
        if ProcessInfo.processInfo.environment["HEX_AUDIO_RELEASE_SELF_TEST"] == "1" {
            scheduledMIDIExecutor.runReleaseRaceSelfTest()
        }
#endif

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
    func start(
        pitch: Double,
        velocity: Int = 100,
        program: Int = 0,
        sourceChannel: Int = 0,
        bankMSB: Int = 0,
        bankLSB: Int = 0,
        delaySeconds: TimeInterval = 0,
        automaticStopAfterSeconds: TimeInterval? = nil
    ) throws -> VoiceToken {
        let roundedNote = pitch.isFinite ? Int(floor(pitch + 0.5)) : -1
        guard pitch.isFinite, (0...127).contains(roundedNote) else {
            let error = AudioEngineError.invalidPitch
            publishFailure(error)
            throw error
        }

        try prepare()

        let token = makeToken()
        let address = try allocateAddress(for: token)
        let targetSampler = samplers[address.samplerIndex]
        let noteNumber = UInt8(roundedNote)
        let cents = (pitch - Double(noteNumber)) * 100.0
        let pitchBend = Self.pitchBendValue(forCents: cents)
        let safeVelocity = UInt8(clamping: max(1, min(velocity, 127)))
        let safeProgram = UInt8(clamping: max(0, min(program, 127)))
        let safeSourceChannel = max(0, min(sourceChannel, 15))
        let requestedBankMSB = UInt8(clamping: max(0, min(bankMSB, 127)))
        let requestedBankLSB = UInt8(clamping: max(0, min(bankLSB, 127)))
        let resolvedBankMSB: UInt8
        let resolvedBankLSB: UInt8
        if safeSourceChannel == 9, requestedBankMSB == 0, requestedBankLSB == 0 {
            resolvedBankMSB = 0x78
            resolvedBankLSB = 0
        } else if requestedBankMSB == 0, requestedBankLSB == 0 {
            resolvedBankMSB = defaultBankMSB
            resolvedBankLSB = 0
        } else {
            resolvedBankMSB = requestedBankMSB
            resolvedBankLSB = requestedBankLSB
        }

        scheduledMIDIExecutor.performSynchronously(ScheduledMIDICommand {
            targetSampler.sendProgramChange(
                safeProgram,
                bankMSB: resolvedBankMSB,
                bankLSB: resolvedBankLSB,
                onChannel: address.channel
            )
            targetSampler.sendPitchBend(pitchBend, onChannel: address.channel)
            targetSampler.sendController(11, withValue: 127, onChannel: address.channel)
        })

        let safeDelay = delaySeconds.isFinite ? max(0, delaySeconds) : 0
        let safeAutomaticStop = automaticStopAfterSeconds.flatMap { seconds in
            seconds.isFinite && seconds > 0 ? seconds : nil
        }
        let voice = ActiveVoice(
            token: token,
            address: address,
            noteNumber: noteNumber,
            velocity: safeVelocity,
            order: nextVoiceOrder,
            releaseDelay: Self.releaseDelay(
                sourceChannel: safeSourceChannel,
                bankMSB: Int(requestedBankMSB),
                bankLSB: Int(requestedBankLSB),
                program: Int(safeProgram)
            ),
            scheduledStartUptimeNanoseconds: Self.uptimeDeadline(after: safeDelay),
            startedAt: nil,
            expression: 127,
            releaseGeneration: nil
        )
        nextVoiceOrder = incrementing(nextVoiceOrder)
        activeVoices[token] = voice
        channelOwners[address] = token

        if safeDelay <= 0 {
            beginVoice(token)
            if let safeAutomaticStop {
                scheduledMIDIExecutor.registerStartedVoice(
                    token: token.rawValue,
                    stopAfter: safeAutomaticStop,
                    stop: stopCommand(for: voice)
                )
            }
        } else {
            let startCommand = ScheduledMIDICommand {
                targetSampler.sendController(
                    11,
                    withValue: voice.expression,
                    onChannel: address.channel
                )
                targetSampler.startNote(
                    noteNumber,
                    withVelocity: safeVelocity,
                    onChannel: address.channel
                )
            }
            scheduledMIDIExecutor.scheduleDelayedStart(
                token: token.rawValue,
                startAfter: safeDelay,
                stopAfter: safeAutomaticStop,
                start: startCommand,
                stop: stopCommand(for: voice)
            )
        }
        updateRunningStatus()
        return token
    }

    /// Releases exactly the voice represented by `token`.
    func release(_ token: VoiceToken) {
        release(token, immediate: false)
    }

    func release(_ token: VoiceToken, immediate: Bool) {
        guard var voice = activeVoices[token], voice.releaseGeneration == nil else {
            return
        }

        if voice.startedAt == nil,
           DispatchTime.now().uptimeNanoseconds < voice.scheduledStartUptimeNanoseconds {
            stop(voice)
            activeVoices.removeValue(forKey: token)
            channelOwners.removeValue(forKey: voice.address)
            updateRunningStatus()
            return
        }

        if immediate {
            finishRelease(token)
            return
        }

        guard voice.releaseDelay > 0 else {
            finishRelease(token)
            return
        }

        let releaseGeneration = makeReleaseGeneration()
        voice.releaseGeneration = releaseGeneration
        activeVoices[token] = voice
        scheduledMIDIExecutor.scheduleStop(
            token: token.rawValue,
            after: voice.releaseDelay,
            stop: stopCommand(for: voice),
            completion: scheduledReleaseCompletion(
                token: token,
                releaseGeneration: releaseGeneration
            )
        )
    }

    func setPressure(_ token: VoiceToken, expression: Int) {
        guard var voice = activeVoices[token] else { return }
        let value = UInt8(clamping: max(0, min(expression, 127)))
        guard voice.expression != value else { return }
        voice.expression = value
        activeVoices[token] = voice
        guard voice.startedAt != nil
                || DispatchTime.now().uptimeNanoseconds >= voice.scheduledStartUptimeNanoseconds else {
            return
        }
        let targetSampler = samplers[voice.address.samplerIndex]
        scheduledMIDIExecutor.performSynchronously(ScheduledMIDICommand {
            targetSampler.sendPressure(
                forKey: voice.noteNumber,
                withValue: value,
                onChannel: voice.address.channel
            )
            targetSampler.sendController(11, withValue: value, onChannel: voice.address.channel)
        })
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
        try loadDefaultInstruments(from: soundFontURL)

        earlyReflectionDelay.delayTime = 0.018
        earlyReflectionDelay.wetDryMix = 4.5
        earlyReflectionDelay.feedback = 3
        earlyReflectionDelay.lowPassCutoff = 7_800
        reverb.loadFactoryPreset(.largeHall)
        reverb.wetDryMix = 36.7

        for sampler in samplers {
            engine.attach(sampler)
        }
        engine.attach(samplerMixer)
        engine.attach(earlyReflectionDelay)
        engine.attach(reverb)
        for sampler in samplers {
            engine.connect(sampler, to: samplerMixer, format: nil)
        }
        engine.connect(samplerMixer, to: earlyReflectionDelay, format: nil)
        engine.connect(earlyReflectionDelay, to: reverb, format: nil)
        engine.connect(reverb, to: engine.mainMixerNode, format: nil)
        graphIsConfigured = true
    }

    private func loadDefaultInstruments(from url: URL) throws {
        let candidateBanks: [UInt8] = [0x79, 0x00]
        var lastError: Error?
        var selectedBankMSB: UInt8?

        for bankMSB in candidateBanks {
            do {
                try samplers[0].loadSoundBankInstrument(
                    at: url,
                    program: 0,
                    bankMSB: bankMSB,
                    bankLSB: 0
                )
                selectedBankMSB = bankMSB
                break
            } catch {
                lastError = error
            }
        }

        guard let selectedBankMSB else {
            throw AudioEngineError.soundFontLoadFailed(
                lastError?.localizedDescription ?? "未知错误"
            )
        }

        do {
            for sampler in samplers.dropFirst() {
                try sampler.loadSoundBankInstrument(
                    at: url,
                    program: 0,
                    bankMSB: selectedBankMSB,
                    bankLSB: 0
                )
            }
        } catch {
            throw AudioEngineError.soundFontLoadFailed(error.localizedDescription)
        }

        defaultBankMSB = selectedBankMSB
        for sampler in samplers {
            sampler.volume = 1.0
        }
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

        let configuredSamplers = samplers
        let melodicChannels = Self.melodicChannels
        scheduledMIDIExecutor.performSynchronously(ScheduledMIDICommand {
            for sampler in configuredSamplers {
                for channel in melodicChannels {
                    // RPN 0,0: pitch bend sensitivity = two semitones, zero cents.
                    sampler.sendController(101, withValue: 0, onChannel: channel)
                    sampler.sendController(100, withValue: 0, onChannel: channel)
                    sampler.sendController(6, withValue: 2, onChannel: channel)
                    sampler.sendController(38, withValue: 0, onChannel: channel)
                    sampler.sendController(101, withValue: 127, onChannel: channel)
                    sampler.sendController(100, withValue: 127, onChannel: channel)
                    sampler.sendPitchBend(Self.centerPitchBend, onChannel: channel)
                }
            }
        })

        channelsAreConfigured = true
    }

    private func allocateAddress(for token: VoiceToken) throws -> VoiceAddress {
        for samplerIndex in samplers.indices {
            if let channel = Self.melodicChannels.first(where: {
                channelOwners[VoiceAddress(samplerIndex: samplerIndex, channel: $0)] == nil
            }) {
                return VoiceAddress(samplerIndex: samplerIndex, channel: channel)
            }
        }

        guard let oldest = activeVoices.values.min(by: { $0.order < $1.order }) else {
            throw AudioEngineError.noPlaybackChannel
        }

        activeVoices.removeValue(forKey: oldest.token)
        channelOwners.removeValue(forKey: oldest.address)
        stop(oldest)
        return oldest.address
    }

    private func beginVoice(_ token: VoiceToken) {
        guard var voice = activeVoices[token], voice.startedAt == nil else { return }
        let targetSampler = samplers[voice.address.samplerIndex]
        scheduledMIDIExecutor.performSynchronously(ScheduledMIDICommand {
            targetSampler.sendController(
                11,
                withValue: voice.expression,
                onChannel: voice.address.channel
            )
            targetSampler.startNote(
                voice.noteNumber,
                withVelocity: voice.velocity,
                onChannel: voice.address.channel
            )
        })
        voice.startedAt = ProcessInfo.processInfo.systemUptime
        activeVoices[token] = voice
    }

    private func finishRelease(_ token: VoiceToken) {
        guard let voice = activeVoices.removeValue(forKey: token) else { return }
        stop(voice)
        channelOwners.removeValue(forKey: voice.address)
        updateRunningStatus()
    }

    private func scheduledReleaseCompletion(
        token: VoiceToken,
        releaseGeneration: UInt64
    ) -> ScheduledMIDICommand {
        ScheduledMIDICommand { [weak self] in
            Task { @MainActor [weak self] in
                self?.completeScheduledRelease(
                    token,
                    releaseGeneration: releaseGeneration
                )
            }
        }
    }

    private func completeScheduledRelease(
        _ token: VoiceToken,
        releaseGeneration: UInt64
    ) {
        guard let voice = activeVoices[token],
              voice.releaseGeneration == releaseGeneration else {
            return
        }
        activeVoices.removeValue(forKey: token)
        channelOwners.removeValue(forKey: voice.address)
        updateRunningStatus()
    }

    private func stop(_ voice: ActiveVoice) {
        scheduledMIDIExecutor.cancelAndStop(
            token: voice.token.rawValue,
            stop: stopCommand(for: voice)
        )
    }

    private func stopCommand(for voice: ActiveVoice) -> ScheduledMIDICommand {
        let targetSampler = samplers[voice.address.samplerIndex]
        return ScheduledMIDICommand {
            targetSampler.stopNote(voice.noteNumber, onChannel: voice.address.channel)
        }
    }

    private func stopAllVoices() {
        let stops = activeVoices.values.map(stopCommand(for:))
        scheduledMIDIExecutor.cancelAllAndStop(stops)
        activeVoices.removeAll(keepingCapacity: true)
        channelOwners.removeAll(keepingCapacity: true)
        activeVoiceCount = 0
    }

    private func makeToken() -> VoiceToken {
        let token = VoiceToken(rawValue: nextTokenValue)
        nextTokenValue = incrementing(nextTokenValue)
        return token
    }

    private func makeReleaseGeneration() -> UInt64 {
        let generation = nextReleaseGeneration
        nextReleaseGeneration = incrementing(nextReleaseGeneration)
        return generation
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
        samplers = (0..<Self.samplerPoolSize).map { _ in AVAudioUnitSampler() }
        samplerMixer = AVAudioMixerNode()
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

    private static func uptimeDeadline(after seconds: TimeInterval) -> UInt64 {
        let safeSeconds = seconds.isFinite ? max(0, seconds) : 0
        let maximumSeconds = Double(UInt64.max) / 1_000_000_000
        let nanoseconds = safeSeconds >= maximumSeconds
            ? UInt64.max
            : UInt64((safeSeconds * 1_000_000_000).rounded(.up))
        let now = DispatchTime.now().uptimeNanoseconds
        let (sum, overflowed) = now.addingReportingOverflow(nanoseconds)
        return overflowed ? UInt64.max : sum
    }

    private static func releaseDelay(
        sourceChannel: Int,
        bankMSB: Int,
        bankLSB: Int,
        program: Int
    ) -> TimeInterval {
        let bank = bankMSB * 128 + bankLSB
        if sourceChannel == 9 || bank == 128 || program >= 112 {
            return 0
        }
        if (0...7).contains(program) {
            return 0.68
        }
        if (16...23).contains(program)
            || (40...79).contains(program)
            || (88...95).contains(program)
            || (80...87).contains(program) {
            return 0
        }
        return 0.035
    }
}
