import HexaKeyboardCore
import SwiftUI

struct ContentView: View {
    @StateObject private var model = KeyboardViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 14) {
                header
                ControlPanel(model: model)
                StatusGrid(model: model)
                keyboard
            }
            .padding(16)
            .frame(maxWidth: 1_620)
            .frame(maxWidth: .infinity)
        }
        .background(AppPalette.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
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
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("HEX AXIAL KEYBOARD")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
                Text("六边形密铺键盘坐标系")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(AppPalette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Spacer(minLength: 12)

            Text("pitch = (q × gq + r × gr) mod N")
                .font(.subheadline.monospaced().weight(.semibold))
                .foregroundStyle(AppPalette.secondaryText)
                .padding(.horizontal, 13)
                .frame(height: 40)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(AppPalette.line, lineWidth: 1)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Button(action: model.reset) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .background(AppPalette.raisedSurface)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(AppPalette.line, lineWidth: 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppPalette.accent)
            .help("恢复默认参数")
            .accessibilityLabel("恢复默认参数")
        }
    }

    private var keyboard: some View {
        let geometry = KeyboardCanvasGeometry(layout: model.layout)
        return HexKeyboardSurface(
            layout: model.layout,
            displayMode: model.displayMode,
            selectedCoordinate: model.selectedCoordinate,
            onKeyDown: model.keyDown,
            onKeyUp: model.keyUp
        )
        .frame(height: geometry.size.height)
        .background(AppPalette.background)
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(AppPalette.line, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityLabel("六边形微分音键盘")
    }
}

#Preview {
    ContentView()
}
