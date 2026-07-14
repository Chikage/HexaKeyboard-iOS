import AVFoundation
import Combine
import Dispatch
import Foundation
import HexaKeyboardCore

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

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

/// A SoundFont-backed engine for independently tuned multitouch notes.
///
/// Pitch is expressed as a floating-point MIDI note. Every distinct SoundFont
/// instrument owns its own sampler, and independently tuned voices are assigned
/// compatible MIDI channels within that sampler.
@MainActor
final class PolyphonicAudioEngine: NSObject, ObservableObject {
    struct VoiceToken: Hashable, Sendable {
        fileprivate let rawValue: UInt64
    }

    @Published private(set) var statusText = "音频未启动"
    @Published private(set) var isReady = false
    @Published private(set) var activeVoiceCount = 0

    private struct SamplerBank: Hashable {
        let msb: UInt8
        let lsb: UInt8
    }

    private struct InstrumentKey: Hashable {
        private static let gmMelodicBank = SamplerBank(msb: 0, lsb: 0)
        private static let gmPercussionBank = SamplerBank(msb: 1, lsb: 0)
        private static let samplerDefaultMelodicBank = SamplerBank(msb: 0x79, lsb: 0)
        private static let samplerDefaultPercussionBank = SamplerBank(msb: 0x78, lsb: 0)

        let program: UInt8
        let midiBank: SamplerBank
        let isPercussion: Bool

        init(program: Int, sourceChannel: Int, bankMSB: Int, bankLSB: Int) {
            self.program = UInt8(clamping: program)
            midiBank = SamplerBank(
                msb: UInt8(clamping: bankMSB),
                lsb: UInt8(clamping: bankLSB)
            )
            isPercussion = sourceChannel == 9 || (bankMSB == 1 && bankLSB == 0)
        }

        var loadBanks: [SamplerBank] {
            if isPercussion {
                return [
                    Self.gmPercussionBank,
                    Self.samplerDefaultPercussionBank,
                    midiBank,
                ].uniqued()
            }

            return [
                midiBank,
                Self.gmMelodicBank,
                Self.samplerDefaultMelodicBank,
            ].uniqued()
        }
    }

    private struct VoiceAddress: Hashable {
        let instrument: InstrumentKey
        let channel: UInt8
    }

    private struct ActiveVoice {
        let token: VoiceToken
        let address: VoiceAddress
        let noteNumber: UInt8
        let pitchBend: UInt16
        let velocity: UInt8
        let order: UInt64
        let allowsChannelSharing: Bool
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
    private static let playbackChannels = (0..<16).map(UInt8.init)

    private let audioSession = AVAudioSession.sharedInstance()
    private var engine = AVAudioEngine()
    private var samplers: [InstrumentKey: AVAudioUnitSampler] = [:]
    private var samplerMixer = AVAudioMixerNode()
    private var earlyReflectionDelay = AVAudioUnitDelay()
    private var reverb = AVAudioUnitReverb()
    private var graphIsConfigured = false
    private var sessionIsConfigured = false
    private var wantsAudioActive = false
    private var wasRunningBeforeInterruption = false

    private var activeVoices: [VoiceToken: ActiveVoice] = [:]
    private var channelOwners: [VoiceAddress: Set<VoiceToken>] = [:]
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

            isReady = true
            updateRunningStatus()
        } catch {
            publishFailure(error)
            throw error
        }
    }

    /// Preloads every SoundFont instrument needed by a score before scheduling begins.
    func prepareInstruments(for notes: [PlaybackNote]) throws {
        let instruments = Set(notes.map {
            InstrumentKey(
                program: $0.program,
                sourceChannel: $0.channel,
                bankMSB: $0.bankMsb,
                bankLSB: $0.bankLsb
            )
        })
        guard !instruments.isEmpty else { return }

        do {
            try prepare()
            try prepareSamplers(for: instruments)
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
        automaticStopAfterSeconds: TimeInterval? = nil,
        allowsChannelSharing: Bool = false
    ) throws -> VoiceToken {
        let roundedNote = pitch.isFinite ? Int(floor(pitch + 0.5)) : -1
        guard pitch.isFinite, (0...127).contains(roundedNote) else {
            let error = AudioEngineError.invalidPitch
            publishFailure(error)
            throw error
        }

        let noteNumber = UInt8(roundedNote)
        let cents = (pitch - Double(noteNumber)) * 100.0
        let pitchBend = Self.pitchBendValue(forCents: cents)
        let safeVelocity = UInt8(clamping: max(1, min(velocity, 127)))
        let safeProgram = UInt8(clamping: max(0, min(program, 127)))
        let safeSourceChannel = max(0, min(sourceChannel, 15))
        let requestedBankMSB = UInt8(clamping: max(0, min(bankMSB, 127)))
        let requestedBankLSB = UInt8(clamping: max(0, min(bankLSB, 127)))
        let instrument = InstrumentKey(
            program: Int(safeProgram),
            sourceChannel: safeSourceChannel,
            bankMSB: Int(requestedBankMSB),
            bankLSB: Int(requestedBankLSB)
        )

        do {
            try prepare()
            try prepareSamplers(for: [instrument])
        } catch {
            publishFailure(error)
            throw error
        }
        guard let targetSampler = samplers[instrument] else {
            let error = AudioEngineError.soundFontLoadFailed("未能创建请求的音色")
            publishFailure(error)
            throw error
        }

        let token = makeToken()
        let address = try allocateAddress(
            instrument: instrument,
            noteNumber: noteNumber,
            pitchBend: pitchBend,
            allowsChannelSharing: allowsChannelSharing
        )

        scheduledMIDIExecutor.performSynchronously(ScheduledMIDICommand {
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
            pitchBend: pitchBend,
            velocity: safeVelocity,
            order: nextVoiceOrder,
            allowsChannelSharing: allowsChannelSharing,
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
        channelOwners[address, default: []].insert(token)

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
            removeOwner(voice)
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
        guard let targetSampler = samplers[voice.address.instrument] else { return }
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

        _ = try bundledSoundFontURL()
        earlyReflectionDelay.delayTime = 0.018
        earlyReflectionDelay.wetDryMix = 4.5
        earlyReflectionDelay.feedback = 3
        earlyReflectionDelay.lowPassCutoff = 7_800
        reverb.loadFactoryPreset(.largeHall)
        reverb.wetDryMix = 36.7

        engine.attach(samplerMixer)
        engine.attach(earlyReflectionDelay)
        engine.attach(reverb)
        engine.connect(samplerMixer, to: earlyReflectionDelay, format: nil)
        engine.connect(earlyReflectionDelay, to: reverb, format: nil)
        engine.connect(reverb, to: engine.mainMixerNode, format: nil)
        graphIsConfigured = true
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

    private func prepareSamplers(for instruments: Set<InstrumentKey>) throws {
        let missing = instruments.filter { samplers[$0] == nil }
        guard !missing.isEmpty else { return }

        let soundFontURL = try bundledSoundFontURL()
        let wasRunning = engine.isRunning
        if wasRunning {
            engine.pause()
        }

        do {
            for instrument in missing {
                let sampler = AVAudioUnitSampler()
                try loadInstrument(instrument, into: sampler, from: soundFontURL)
                sampler.volume = 1.0
                engine.attach(sampler)
                engine.connect(
                    sampler,
                    to: samplerMixer,
                    fromBus: 0,
                    toBus: samplerMixer.nextAvailableInputBus,
                    format: nil
                )
                configurePlaybackChannels(of: sampler)
                samplers[instrument] = sampler
            }

            if wasRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            if wasRunning, !engine.isRunning {
                engine.prepare()
                try? engine.start()
            }
            throw error
        }
    }

    private func loadInstrument(
        _ instrument: InstrumentKey,
        into sampler: AVAudioUnitSampler,
        from soundFontURL: URL
    ) throws {
        var lastError: Error?
        for bank in instrument.loadBanks {
            do {
                try sampler.loadSoundBankInstrument(
                    at: soundFontURL,
                    program: instrument.program,
                    bankMSB: bank.msb,
                    bankLSB: bank.lsb
                )
                return
            } catch {
                lastError = error
            }
        }

        throw AudioEngineError.soundFontLoadFailed(
            lastError?.localizedDescription ?? "音色不可用"
        )
    }

    private func configurePlaybackChannels(of sampler: AVAudioUnitSampler) {
        let playbackChannels = Self.playbackChannels
        scheduledMIDIExecutor.performSynchronously(ScheduledMIDICommand {
            for channel in playbackChannels {
                // RPN 0,0: pitch bend sensitivity = two semitones, zero cents.
                sampler.sendController(101, withValue: 0, onChannel: channel)
                sampler.sendController(100, withValue: 0, onChannel: channel)
                sampler.sendController(6, withValue: 2, onChannel: channel)
                sampler.sendController(38, withValue: 0, onChannel: channel)
                sampler.sendController(101, withValue: 127, onChannel: channel)
                sampler.sendController(100, withValue: 127, onChannel: channel)
                sampler.sendPitchBend(Self.centerPitchBend, onChannel: channel)
            }
        })
    }

    private func allocateAddress(
        instrument: InstrumentKey,
        noteNumber: UInt8,
        pitchBend: UInt16,
        allowsChannelSharing: Bool
    ) throws -> VoiceAddress {
        let addresses = Self.playbackChannels.map {
            VoiceAddress(instrument: instrument, channel: $0)
        }

        if allowsChannelSharing,
           let compatible = addresses.first(where: { address in
               guard let owners = channelOwners[address], !owners.isEmpty else { return false }
               return owners.allSatisfy { owner in
                   guard let voice = activeVoices[owner] else { return false }
                   return voice.allowsChannelSharing
                       && voice.pitchBend == pitchBend
                       && voice.noteNumber != noteNumber
               }
           }) {
            return compatible
        }

        if let free = addresses.first(where: { channelOwners[$0]?.isEmpty != false }) {
            return free
        }

        guard let selected = addresses.min(by: { first, second in
            let firstOwners = channelOwners[first] ?? []
            let secondOwners = channelOwners[second] ?? []
            if firstOwners.count != secondOwners.count {
                return firstOwners.count < secondOwners.count
            }
            let firstOrder = firstOwners.compactMap { activeVoices[$0]?.order }.min() ?? UInt64.max
            let secondOrder = secondOwners.compactMap { activeVoices[$0]?.order }.min() ?? UInt64.max
            return firstOrder < secondOrder
        }) else {
            throw AudioEngineError.noPlaybackChannel
        }

        for owner in channelOwners[selected] ?? [] {
            guard let voice = activeVoices.removeValue(forKey: owner) else { continue }
            stop(voice)
        }
        channelOwners.removeValue(forKey: selected)
        return selected
    }

    private func beginVoice(_ token: VoiceToken) {
        guard var voice = activeVoices[token], voice.startedAt == nil else { return }
        guard let targetSampler = samplers[voice.address.instrument] else { return }
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
        removeOwner(voice)
        updateRunningStatus()
    }

    private func removeOwner(_ voice: ActiveVoice) {
        guard var owners = channelOwners[voice.address] else { return }
        owners.remove(voice.token)
        if owners.isEmpty {
            channelOwners.removeValue(forKey: voice.address)
        } else {
            channelOwners[voice.address] = owners
        }
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
        removeOwner(voice)
        updateRunningStatus()
    }

    private func stop(_ voice: ActiveVoice) {
        scheduledMIDIExecutor.cancelAndStop(
            token: voice.token.rawValue,
            stop: stopCommand(for: voice)
        )
    }

    private func stopCommand(for voice: ActiveVoice) -> ScheduledMIDICommand {
        guard let targetSampler = samplers[voice.address.instrument] else {
            return ScheduledMIDICommand {}
        }
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
        samplers.removeAll(keepingCapacity: true)
        samplerMixer = AVAudioMixerNode()
        earlyReflectionDelay = AVAudioUnitDelay()
        reverb = AVAudioUnitReverb()
        graphIsConfigured = false
        sessionIsConfigured = false
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
