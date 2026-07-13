import Combine
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
    @Published private(set) var configuration: HexaKeyboardConfiguration
    @Published private(set) var layout: HexaKeyboardLayout
    @Published var displayMode: KeyboardDisplayMode = .pitch
    @Published private(set) var selectedCoordinate: AxialCoordinate?

    let audioEngine = PolyphonicAudioEngine()

    private var touchVoices: [Int: PolyphonicAudioEngine.VoiceToken] = [:]

    init(configuration: HexaKeyboardConfiguration = .default) {
        let normalized = configuration.normalized()
        self.configuration = normalized
        layout = HexaKeyboardLayoutEngine.build(configuration: normalized)
        selectedCoordinate = layout.defaultSelection?.coordinate
    }

    var selectedKey: HexKey? {
        guard let selectedCoordinate else { return nil }
        return layout.cell(at: selectedCoordinate)
    }

    func value(_ keyPath: KeyPath<HexaKeyboardConfiguration, Int>) -> Int {
        configuration[keyPath: keyPath]
    }

    func update(
        _ keyPath: WritableKeyPath<HexaKeyboardConfiguration, Int>,
        to value: Int
    ) {
        var next = configuration
        next[keyPath: keyPath] = value
        apply(next)
    }

    func reset() {
        apply(.default)
        displayMode = .pitch
    }

    func keyDown(touchID: Int, key: HexKey) {
        keyUp(touchID: touchID)
        selectedCoordinate = key.coordinate

        guard key.audioPitch.isPlayable else { return }
        do {
            touchVoices[touchID] = try audioEngine.start(
                pitch: key.audioPitch.midiPitch,
                velocity: 104
            )
        } catch {
            // The audio engine publishes the localized failure for the status card.
        }
    }

    func keyUp(touchID: Int) {
        guard let token = touchVoices.removeValue(forKey: touchID) else { return }
        audioEngine.release(token)
    }

    func activateAudio() {
        audioEngine.activateForForeground()
    }

    func deactivateAudio() {
        touchVoices.removeAll()
        audioEngine.deactivateForBackground()
    }

    private func apply(_ requested: HexaKeyboardConfiguration) {
        stopAllTouches()
        let normalized = requested.normalized()
        configuration = normalized
        layout = HexaKeyboardLayoutEngine.build(configuration: normalized)

        if let selectedCoordinate, layout.cell(at: selectedCoordinate) != nil {
            self.selectedCoordinate = selectedCoordinate
        } else {
            selectedCoordinate = layout.defaultSelection?.coordinate
        }
    }

    private func stopAllTouches() {
        touchVoices.removeAll()
        audioEngine.allOff()
    }
}
