import HexaKeyboardCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = KeyboardViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingScoreImporter = false

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
                    onConfigurationChange: model.applyConfiguration,
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
            }
            .padding(8)

            if let toast = model.toastMessage {
                Text(toast)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppPalette.primaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
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
        .onAppear(perform: model.activateAudio)
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
                model.errorMessage = "文件打开失败：\(error.localizedDescription)"
            }
        }
        .alert(
            "Hexa Key",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            actions: {
                Button("好") { model.errorMessage = nil }
            },
            message: {
                Text(model.errorMessage ?? "未知错误")
            }
        )
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
