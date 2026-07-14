import HexaKeyboardCore
import SwiftUI
import UIKit

struct MainToolbar: View {
    let configuration: HexaKeyboardConfiguration
    let playbackMode: Bool
    let isPlaying: Bool
    let isLoading: Bool
    let audioReady: Bool
    let touchSensitivityPercent: Int
    let midiProgramNumber: Int
    let pseudoPressureEnabled: Bool
    @Binding var settingsExpanded: Bool
    let onConfigurationChange: (HexaKeyboardConfiguration) -> Void
    let onOpenScore: () -> Void
    let onPlayPause: () -> Void
    let onPlaybackReset: () -> Void
    let onPlaybackTerminate: () -> Void
    let onKeyboardPan: (CGSize) -> Void
    let onKeyboardZoom: (CGFloat) -> Void
    let onTouchSensitivityChange: (Int) -> Void
    let onMIDIProgramNumberChange: (Int) -> Void
    let onPseudoPressureChange: (Bool) -> Void

    @State private var lastDragTranslation = CGSize.zero
    @State private var lastMagnification: CGFloat = 1

    private let minimumToolbarWidth: CGFloat = 724

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GeometryReader { geometry in
                if geometry.size.width < minimumToolbarWidth {
                    compactToolbarRow(width: geometry.size.width)
                        .simultaneousGesture(toolbarMagnificationGesture)
                } else {
                    regularToolbarRow(width: geometry.size.width)
                        .simultaneousGesture(toolbarDragGesture)
                        .simultaneousGesture(toolbarMagnificationGesture)
                }
            }
            .frame(height: 56)
            .background(AppPalette.surface)
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(AppPalette.line, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            if settingsExpanded {
                settingsPanel
                    .offset(y: 52)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                    .zIndex(20)
            }
        }
        .frame(height: 56)
        .zIndex(settingsExpanded ? 20 : 1)
    }

    private func regularToolbarRow(width: CGFloat) -> some View {
        HStack(spacing: 4) {
            toolbarContent
            Spacer(minLength: 0)
            settingsButton
        }
        .frame(width: max(0, width - 12), height: 44)
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func compactToolbarRow(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                toolbarContent
                    .padding(.leading, 6)
                    .padding(.trailing, 4)
            }
            .scrollDismissesKeyboard(.immediately)
            .simultaneousGesture(
                TapGesture().onEnded {
                    settingsExpanded = false
                }
            )

            compactPanHandle
                .padding(.leading, 2)

            settingsButton
                .padding(.horizontal, 6)
        }
        .frame(width: max(0, width), height: 56)
        .contentShape(Rectangle())
    }

    private var toolbarContent: some View {
        HStack(spacing: 4) {
            transportControls

            NumberParameter(
                title: "列数",
                value: configuration.columns,
                range: 4...64,
                onInteraction: collapseSettings
            ) { onConfigurationChange(configuration.with(columns: $0)) }

            NumberParameter(
                title: "行数",
                value: configuration.rows,
                range: 3...32,
                onInteraction: collapseSettings
            ) { onConfigurationChange(configuration.with(rows: $0)) }

            NumberParameter(
                title: "EDO",
                value: configuration.period,
                range: 2...200,
                onInteraction: collapseSettings
            ) { onConfigurationChange(configuration.with(period: $0)) }

            NumberParameter(
                title: "q 轴音程",
                value: configuration.stepQ,
                range: -200...200,
                onInteraction: collapseSettings
            ) { onConfigurationChange(configuration.with(stepQ: $0)) }

            NumberParameter(
                title: "r 轴音程",
                value: configuration.stepR,
                range: -200...200,
                onInteraction: collapseSettings
            ) { onConfigurationChange(configuration.with(stepR: $0)) }
        }
        .frame(height: 44)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var settingsButton: some View {
        Button {
            dismissKeyboard()
            withAnimation(.easeOut(duration: 0.14)) {
                settingsExpanded.toggle()
            }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(settingsExpanded ? AppPalette.accent : AppPalette.secondaryText)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(settingsExpanded ? "收起设置" : "展开设置")
    }

    private var compactPanHandle: some View {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(AppPalette.secondaryText)
            .frame(width: 36, height: 44)
            .background(AppPalette.raisedSurface.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .gesture(toolbarDragGesture)
            .accessibilityElement()
            .accessibilityLabel("拖动平移键盘")
            .accessibilityHint("仅在窄屏工具栏中使用")
    }

    private var transportControls: some View {
        HStack(spacing: 0) {
            TransportButton(
                icon: .folder,
                accessibilityLabel: "打开 MIDI 或 MuseScore 文件",
                enabled: !isPlaying && !isLoading,
                action: {
                    collapseSettings()
                    onOpenScore()
                }
            )
            ToolbarDivider()
            TransportButton(
                icon: isPlaying ? .pause : .play,
                accessibilityLabel: isPlaying ? "暂停" : "播放",
                active: isPlaying,
                enabled: playbackMode && !isLoading && audioReady,
                action: {
                    collapseSettings()
                    onPlayPause()
                }
            )
            TransportButton(
                icon: .reset,
                accessibilityLabel: "复位到开头",
                enabled: playbackMode && !isLoading,
                action: {
                    collapseSettings()
                    onPlaybackReset()
                }
            )
            TransportButton(
                icon: .terminate,
                accessibilityLabel: "终止并关闭文件",
                enabled: playbackMode && !isLoading,
                action: {
                    collapseSettings()
                    onPlaybackTerminate()
                }
            )
            ToolbarDivider()
        }
    }

    private var settingsPanel: some View {
        VStack(spacing: 4) {
            SliderSettingRow(
                title: "触摸灵敏度",
                value: touchSensitivityPercent,
                range: 100...150,
                valueText: "\(touchSensitivityPercent)%",
                onValueChange: onTouchSensitivityChange
            )
            SliderSettingRow(
                title: "MIDI Program Number",
                value: midiProgramNumber,
                range: 0...127,
                valueText: String(midiProgramNumber),
                onValueChange: onMIDIProgramNumberChange
            )
            HStack {
                Text("伪压感")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppPalette.primaryText)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { pseudoPressureEnabled },
                    set: { onPseudoPressureChange($0) }
                ))
                .labelsHidden()
                .tint(AppPalette.accent)
                .frame(width: 52, alignment: .trailing)
            }
            .padding(.horizontal, 2)
            .frame(height: 58)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 264)
        .background(AppPalette.raisedSurface)
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(AppPalette.line, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.42), radius: 14, x: 0, y: 7)
    }

    private var toolbarDragGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                if lastDragTranslation == .zero, value.translation != .zero {
                    dismissKeyboard()
                    collapseSettings()
                }
                let delta = CGSize(
                    width: value.translation.width - lastDragTranslation.width,
                    height: -(value.translation.height - lastDragTranslation.height)
                )
                lastDragTranslation = value.translation
                guard delta != .zero else { return }
                onKeyboardPan(delta)
            }
            .onEnded { _ in
                lastDragTranslation = .zero
            }
    }

    private var toolbarMagnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard value.isFinite, value > 0, lastMagnification > 0 else { return }
                if lastMagnification == 1, value != 1 {
                    dismissKeyboard()
                    collapseSettings()
                }
                let delta = value / lastMagnification
                lastMagnification = value
                if delta.isFinite, delta > 0 {
                    onKeyboardZoom(delta)
                }
            }
            .onEnded { _ in
                lastMagnification = 1
            }
    }

    private func collapseSettings() {
        guard settingsExpanded else { return }
        withAnimation(.easeOut(duration: 0.14)) {
            settingsExpanded = false
        }
    }
}

private struct TransportButton: View {
    let icon: TransportIcon
    let accessibilityLabel: String
    var active = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button {
            guard enabled else { return }
            dismissKeyboard()
            action()
        } label: {
            AndroidTransportIconShape(icon: icon)
                .fill(enabled ? Color.white : AppPalette.playbackMuted)
                .frame(width: 22, height: 22)
                .frame(width: 48, height: 44)
                .background(
                    enabled
                        ? (active ? AppPalette.playbackActive : AppPalette.playbackButton)
                        : AppPalette.playbackPanel
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .allowsHitTesting(enabled)
        .padding(.trailing, 6)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(enabled ? "" : "不可用")
    }
}

private enum TransportIcon {
    case folder
    case play
    case pause
    case reset
    case terminate
}

private struct AndroidTransportIconShape: Shape {
    let icon: TransportIcon

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let offsetX = rect.midX - 12 * scale
        let offsetY = rect.midY - 12 * scale
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: offsetX + x * scale, y: offsetY + y * scale)
        }
        func scaledRect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(
                x: offsetX + x * scale,
                y: offsetY + y * scale,
                width: width * scale,
                height: height * scale
            )
        }

        var path = Path()
        switch icon {
        case .folder:
            path.move(to: point(10, 4))
            path.addLine(to: point(4, 4))
            path.addCurve(to: point(2, 6), control1: point(2.9, 4), control2: point(2, 4.9))
            path.addLine(to: point(2, 18))
            path.addCurve(to: point(4, 20), control1: point(2, 19.1), control2: point(2.9, 20))
            path.addLine(to: point(20, 20))
            path.addCurve(to: point(22, 18), control1: point(21.1, 20), control2: point(22, 19.1))
            path.addLine(to: point(22, 8))
            path.addCurve(to: point(20, 6), control1: point(22, 6.9), control2: point(21.1, 6))
            path.addLine(to: point(12, 6))
            path.closeSubpath()
        case .play:
            path.move(to: point(8, 5))
            path.addLine(to: point(8, 19))
            path.addLine(to: point(19, 12))
            path.closeSubpath()
        case .pause:
            path.addRect(scaledRect(7, 5, 3, 14))
            path.addRect(scaledRect(14, 5, 3, 14))
        case .reset:
            path.move(to: point(12, 5))
            path.addLine(to: point(12, 2))
            path.addLine(to: point(7, 7))
            path.addLine(to: point(12, 12))
            path.addLine(to: point(12, 9))
            path.addCurve(to: point(17, 14), control1: point(14.76, 9), control2: point(17, 11.24))
            path.addCurve(to: point(12, 19), control1: point(17, 16.76), control2: point(14.76, 19))
            path.addCurve(to: point(7, 14), control1: point(9.24, 19), control2: point(7, 16.76))
            path.addLine(to: point(5, 14))
            path.addCurve(to: point(12, 21), control1: point(5, 17.87), control2: point(8.13, 21))
            path.addCurve(to: point(19, 14), control1: point(15.87, 21), control2: point(19, 17.87))
            path.addCurve(to: point(12, 7), control1: point(19, 10.13), control2: point(15.87, 7))
            path.addLine(to: point(12, 5))
            path.closeSubpath()
        case .terminate:
            path.addRect(scaledRect(7, 7, 10, 10))
        }
        return path
    }
}

private struct ToolbarDivider: View {
    var body: some View {
        AppPalette.playbackDivider
            .frame(width: 1, height: 38)
            .clipShape(Capsule())
            .padding(.leading, 4)
            .padding(.trailing, 10)
    }
}

private struct NumberParameter: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    let onInteraction: () -> Void
    let onValueChange: (Int) -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(
        title: String,
        value: Int,
        range: ClosedRange<Int>,
        onInteraction: @escaping () -> Void = {},
        onValueChange: @escaping (Int) -> Void
    ) {
        self.title = title
        self.value = value
        self.range = range
        self.onInteraction = onInteraction
        self.onValueChange = onValueChange
        _text = State(initialValue: String(value))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                stepButton("−", nextValue: value - 1, enabled: value > range.lowerBound)

                TextField("", text: $text)
                    .focused($focused)
                    .keyboardType(.numbersAndPunctuation)
                    .submitLabel(.done)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppPalette.primaryText)
                    .tint(AppPalette.accent)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .simultaneousGesture(
                        TapGesture().onEnded(onInteraction)
                    )
                    .onSubmit(commitInput)
                    .onChange(of: text) { candidate in
                        guard candidate.count <= 4,
                              candidate.range(of: "^-?\\d*$", options: .regularExpression) != nil
                        else {
                            text = String(value)
                            return
                        }
                        if let parsed = Int(candidate), range.contains(parsed), parsed != value {
                            onValueChange(parsed)
                        }
                    }

                stepButton("+", nextValue: value + 1, enabled: value < range.upperBound)
            }
            .padding(.top, 4)
            .frame(width: 80, height: 36)
            .background(AppPalette.surface)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(AppPalette.line, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .frame(maxHeight: .infinity, alignment: .bottom)

            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppPalette.secondaryText)
                .lineLimit(1)
                .padding(.horizontal, 2)
                .background(AppPalette.surface)
                .padding(.leading, 6)
        }
        .frame(width: 80, height: 42)
        .onChange(of: value) { nextValue in
            if Int(text) != nextValue {
                text = String(nextValue)
            }
        }
        .onChange(of: focused) { isFocused in
            if !isFocused { commitInput() }
        }
    }

    private func stepButton(_ label: String, nextValue: Int, enabled: Bool) -> some View {
        Button {
            dismissKeyboard()
            onInteraction()
            onValueChange(nextValue)
        } label: {
            Text(label)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(enabled ? AppPalette.accent : AppPalette.primaryText.opacity(0.38))
                .frame(width: 22, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func commitInput() {
        let confirmed = (Int(text) ?? value).clamped(to: range)
        text = String(confirmed)
        if confirmed != value {
            onValueChange(confirmed)
        }
    }
}

private struct SliderSettingRow: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    let valueText: String
    let onValueChange: (Int) -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppPalette.primaryText)
                Spacer(minLength: 8)
                Text(valueText)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppPalette.accent)
            }
            CompactIntegerSlider(value: value, range: range, onValueChange: onValueChange)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
        .frame(height: 58)
    }
}

private struct CompactIntegerSlider: View {
    let value: Int
    let range: ClosedRange<Int>
    let onValueChange: (Int) -> Void

    var body: some View {
        GeometryReader { geometry in
            let progress = CGFloat(value - range.lowerBound)
                / CGFloat(max(1, range.upperBound - range.lowerBound))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppPalette.accent.opacity(0.24))
                    .frame(height: 2)
                Capsule()
                    .fill(AppPalette.accent)
                    .frame(width: geometry.size.width * progress.clamped(to: 0...1), height: 2)
                Circle()
                    .fill(AppPalette.accent)
                    .frame(width: 12, height: 12)
                    .offset(x: max(0, geometry.size.width * progress.clamped(to: 0...1) - 6))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let fraction = (gesture.location.x / max(1, geometry.size.width))
                            .clamped(to: 0...1)
                        let raw = CGFloat(range.lowerBound)
                            + fraction * CGFloat(range.upperBound - range.lowerBound)
                        onValueChange(Int(raw.rounded()))
                    }
            )
        }
        .frame(height: 20)
    }
}

private extension HexaKeyboardConfiguration {
    func with(
        columns: Int? = nil,
        rows: Int? = nil,
        period: Int? = nil,
        stepQ: Int? = nil,
        stepR: Int? = nil
    ) -> HexaKeyboardConfiguration {
        HexaKeyboardConfiguration(
            columns: columns ?? self.columns,
            rows: rows ?? self.rows,
            period: period ?? self.period,
            stepQ: stepQ ?? self.stepQ,
            stepR: stepR ?? self.stepR,
            radius: 24,
            rotationDegrees: 12,
            frameAcuteAngleDegrees: frameAcuteAngleDegrees
        )
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

@MainActor
private func dismissKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil,
        from: nil,
        for: nil
    )
}
