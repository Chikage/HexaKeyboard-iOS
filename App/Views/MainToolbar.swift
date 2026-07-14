import HexaKeyboardCore
import SwiftUI

struct MainToolbar: View {
    let configuration: HexaKeyboardConfiguration
    let playbackMode: Bool
    let isPlaying: Bool
    let isLoading: Bool
    let audioReady: Bool
    let touchSensitivityPercent: Int
    let midiProgramNumber: Int
    let pseudoPressureEnabled: Bool
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

    @State private var settingsExpanded = false
    @State private var lastDragTranslation = CGSize.zero
    @State private var lastMagnification: CGFloat = 1

    private let minimumToolbarWidth: CGFloat = 738

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GeometryReader { geometry in
                if geometry.size.width < minimumToolbarWidth {
                    ScrollView(.horizontal, showsIndicators: false) {
                        toolbarRow
                            .frame(width: minimumToolbarWidth - 12, height: 44)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 6)
                    }
                } else {
                    toolbarRow
                        .frame(width: max(0, geometry.size.width - 12), height: 44)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                }
            }
            .frame(height: 56)
            .background(AppPalette.surface)
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(AppPalette.line, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .simultaneousGesture(toolbarDragGesture)
            .simultaneousGesture(toolbarMagnificationGesture)

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

    private var toolbarRow: some View {
        HStack(spacing: 4) {
            transportControls

            NumberParameter(
                title: "列数",
                value: configuration.columns,
                range: 4...64
            ) { onConfigurationChange(configuration.with(columns: $0)) }

            NumberParameter(
                title: "行数",
                value: configuration.rows,
                range: 3...32
            ) { onConfigurationChange(configuration.with(rows: $0)) }

            NumberParameter(
                title: "EDO",
                value: configuration.period,
                range: 2...200
            ) { onConfigurationChange(configuration.with(period: $0)) }

            NumberParameter(
                title: "q 轴音程",
                value: configuration.stepQ,
                range: -200...200
            ) { onConfigurationChange(configuration.with(stepQ: $0)) }

            NumberParameter(
                title: "r 轴音程",
                value: configuration.stepR,
                range: -200...200
            ) { onConfigurationChange(configuration.with(stepR: $0)) }

            Spacer(minLength: 0)

            Button {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transportControls: some View {
        HStack(spacing: 0) {
            TransportButton(
                systemImage: "folder.fill",
                accessibilityLabel: "打开 MIDI 或 MuseScore 文件",
                enabled: !isPlaying && !isLoading,
                action: onOpenScore
            )
            ToolbarDivider()
            TransportButton(
                systemImage: isPlaying ? "pause.fill" : "play.fill",
                accessibilityLabel: isPlaying ? "暂停" : "播放",
                active: isPlaying,
                enabled: playbackMode && !isLoading && audioReady,
                action: onPlayPause
            )
            TransportButton(
                systemImage: "arrow.counterclockwise",
                accessibilityLabel: "复位到开头",
                enabled: playbackMode && !isLoading,
                action: onPlaybackReset
            )
            TransportButton(
                systemImage: "stop.fill",
                accessibilityLabel: "终止并关闭文件",
                enabled: playbackMode && !isLoading,
                action: onPlaybackTerminate
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
                .scaleEffect(0.78)
                .frame(width: 48)
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
}

private struct TransportButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var active = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(enabled ? Color.white : AppPalette.playbackMuted)
                .frame(width: 48, height: 44)
                .background(
                    active
                        ? AppPalette.playbackActive
                        : enabled ? AppPalette.playbackButton : AppPalette.playbackPanel
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .padding(.trailing, 6)
        .accessibilityLabel(accessibilityLabel)
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
    let onValueChange: (Int) -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(
        title: String,
        value: Int,
        range: ClosedRange<Int>,
        onValueChange: @escaping (Int) -> Void
    ) {
        self.title = title
        self.value = value
        self.range = range
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
