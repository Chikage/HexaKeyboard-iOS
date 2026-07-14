import HexaKeyboardCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = KeyboardViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingScoreImporter = false
    @State private var settingsExpanded = false
    @State private var requestedAutonomousSingleAppMode = false

    var body: some View {
        ZStack {
            AppPalette.background.ignoresSafeArea()

            VStack(spacing: 8) {
                MainToolbar(
                    configuration: model.configuration,
                    playbackMode: model.playbackState.playbackMode,
                    isPlaying: model.playbackState.playing,
                    isLoading: model.playbackState.loading,
                    audioReady: model.audioReady,
                    touchSensitivityPercent: model.touchSensitivityPercent,
                    midiProgramNumber: model.midiProgramNumber,
                    pseudoPressureEnabled: model.pseudoPressureEnabled,
                    settingsExpanded: $settingsExpanded,
                    onConfigurationChange: model.applyConfiguration,
                    onBack: leaveApplication,
                    onOpenScore: { showingScoreImporter = true },
                    onPlayPause: model.togglePlayPause,
                    onPlaybackReset: model.resetPlayback,
                    onPlaybackTerminate: model.terminatePlayback,
                    onKeyboardPan: model.panKeyboard,
                    onKeyboardZoom: model.zoomKeyboard,
                    onTouchSensitivityChange: model.setTouchSensitivityPercent,
                    onMIDIProgramNumberChange: model.setMIDIProgramNumber,
                    onPseudoPressureChange: model.setPseudoPressureEnabled
                )
                .zIndex(20)

                ZStack {
                    HexKeyboardSurface(
                        layout: model.layout,
                        scale: model.keyboardScale,
                        pan: model.keyboardPan,
                        touchSensitivity: Double(model.touchSensitivityPercent) / 100,
                        pseudoPressureEnabled: model.pseudoPressureEnabled,
                        selectedCoordinates: model.playbackState.playbackMode
                            ? []
                            : model.selectedCoordinates,
                        selectionAnchorCoordinate: model.playbackState.playbackMode
                            ? nil
                            : model.selectionAnchorCoordinate,
                        playbackTimeline: model.playbackTimeline,
                        playbackPositionSeconds: model.playbackState.playheadSeconds,
                        activePlaybackNoteIndices: model.playbackState.activeScoreIndices,
                        onConstrainedPan: model.updateConstrainedPan,
                        onKeyDown: model.keyDown,
                        onKeyPressure: model.keyPressure,
                        onKeyUp: model.keyUp
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppPalette.background)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(AppPalette.line, lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("六边形微分音键盘")

                    if settingsExpanded {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(perform: dismissSettings)
                            .accessibilityLabel("关闭设置")
                            .accessibilityAddTraits(.isButton)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(8)

            if let toast = model.toastMessage {
                Text(toast)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppPalette.primaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: 620)
                    .background(AppPalette.raisedSurface.opacity(0.96))
                    .overlay {
                        Capsule().stroke(AppPalette.line, lineWidth: 1)
                    }
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 18)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: Self.isIPad ? .all : [])
        .onAppear {
            model.activateAudio()
            requestAutonomousSingleAppModeIfAvailable()
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                model.activateAudio()
            case .inactive, .background:
                model.deactivateAudio()
            @unknown default:
                model.deactivateAudio()
            }
        }
        .fileImporter(
            isPresented: $showingScoreImporter,
            allowedContentTypes: Self.scoreContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                if let url = urls.first {
                    model.loadScore(from: url)
                }
            case let .failure(error):
                model.reportFileOpenFailure(error)
            }
        }
    }

    private func dismissSettings() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        withAnimation(.easeOut(duration: 0.14)) {
            settingsExpanded = false
        }
    }

    private func requestAutonomousSingleAppModeIfAvailable() {
        guard Self.isIPad, !requestedAutonomousSingleAppMode else { return }
        requestedAutonomousSingleAppMode = true
        guard !UIAccessibility.isGuidedAccessEnabled else { return }

        UIAccessibility.requestGuidedAccessSession(enabled: true) { _ in }
    }

    private func leaveApplication() {
        dismissSettings()
        if UIAccessibility.isGuidedAccessEnabled {
            UIAccessibility.requestGuidedAccessSession(enabled: false) { _ in
                Task { @MainActor in
                    Self.closeForegroundScene()
                }
            }
        } else {
            Self.closeForegroundScene()
        }
    }

    @MainActor
    private static func closeForegroundScene() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }

        UIApplication.shared.requestSceneSessionDestruction(
            scene.session,
            options: nil,
            errorHandler: nil
        )
    }

    private static var isIPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private static let scoreContentTypes: [UTType] = {
        let extensions = ["mid", "midi", "midix", "midx", "midi2", "mscz", "mscx"]
        let resolved = extensions.compactMap { UTType(filenameExtension: $0) }
        return resolved.isEmpty ? [.data] : resolved + [.data]
    }()
}

#Preview {
    ContentView()
}
