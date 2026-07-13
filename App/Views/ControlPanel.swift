import HexaKeyboardCore
import SwiftUI

struct ControlPanel: View {
    @ObservedObject var model: KeyboardViewModel

    private let numericColumns = [
        GridItem(.adaptive(minimum: 116, maximum: 170), spacing: 10),
    ]

    var body: some View {
        VStack(spacing: 14) {
            LazyVGrid(columns: numericColumns, alignment: .leading, spacing: 12) {
                NumericParameterControl(
                    title: "列数",
                    value: model.value(\.columns),
                    range: 4...64,
                    onChange: { model.update(\.columns, to: $0) }
                )
                NumericParameterControl(
                    title: "行数",
                    value: model.value(\.rows),
                    range: 3...32,
                    onChange: { model.update(\.rows, to: $0) }
                )
                NumericParameterControl(
                    title: "周期 N",
                    value: model.value(\.period),
                    range: 2...200,
                    onChange: { model.update(\.period, to: $0) }
                )
                NumericParameterControl(
                    title: "gq",
                    value: model.value(\.stepQ),
                    range: -200...200,
                    onChange: { model.update(\.stepQ, to: $0) }
                )
                NumericParameterControl(
                    title: "gr",
                    value: model.value(\.stepR),
                    range: -200...200,
                    onChange: { model.update(\.stepR, to: $0) }
                )
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    compactSliderControls
                }
                VStack(spacing: 12) {
                    flexibleSliderControls
                }
            }
        }
        .padding(12)
        .toolSurface()
    }

    @ViewBuilder
    private var compactSliderControls: some View {
        IntegerSliderControl(
            title: "键帽大小",
            systemImage: "hexagon",
            value: model.value(\.radius),
            range: 14...34,
            valueText: "\(model.value(\.radius))",
            onChange: { model.update(\.radius, to: $0) }
        )
        .frame(width: 175)

        IntegerSliderControl(
            title: "旋转",
            systemImage: "rotate.right",
            value: model.value(\.rotationDegrees),
            range: -60...60,
            valueText: "\(model.value(\.rotationDegrees))°",
            onChange: { model.update(\.rotationDegrees, to: $0) }
        )
        .frame(width: 205)

        displayPicker
            .frame(width: 210)
    }

    @ViewBuilder
    private var flexibleSliderControls: some View {
        IntegerSliderControl(
            title: "键帽大小",
            systemImage: "hexagon",
            value: model.value(\.radius),
            range: 14...34,
            valueText: "\(model.value(\.radius))",
            onChange: { model.update(\.radius, to: $0) }
        )

        IntegerSliderControl(
            title: "旋转",
            systemImage: "rotate.right",
            value: model.value(\.rotationDegrees),
            range: -60...60,
            valueText: "\(model.value(\.rotationDegrees))°",
            onChange: { model.update(\.rotationDegrees, to: $0) }
        )

        displayPicker
    }

    private var displayPicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("显示")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppPalette.secondaryText)
            Picker("显示", selection: $model.displayMode) {
                ForEach(KeyboardDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

private struct NumericParameterControl: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    let onChange: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppPalette.secondaryText)
            HStack(spacing: 5) {
                stepButton(systemImage: "minus", value: value - 1, disabled: value <= range.lowerBound)
                Text(String(value))
                    .font(.system(.body, design: .monospaced, weight: .semibold))
                    .foregroundStyle(AppPalette.primaryText)
                    .frame(maxWidth: .infinity)
                stepButton(systemImage: "plus", value: value + 1, disabled: value >= range.upperBound)
            }
            .frame(height: 34)
            .background(AppPalette.background)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(AppPalette.line, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }

    private func stepButton(systemImage: String, value: Int, disabled: Bool) -> some View {
        Button {
            onChange(value)
        } label: {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .frame(width: 30, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? AppPalette.secondaryText.opacity(0.35) : AppPalette.accent)
        .disabled(disabled)
        .accessibilityLabel(systemImage == "minus" ? "减小\(title)" : "增大\(title)")
    }
}

private struct IntegerSliderControl: View {
    let title: String
    let systemImage: String
    let value: Int
    let range: ClosedRange<Int>
    let valueText: String
    let onChange: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(AppPalette.accent)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.secondaryText)
                Spacer(minLength: 8)
                Text(valueText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(AppPalette.primaryText)
                    .frame(minWidth: 32, alignment: .trailing)
            }
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { onChange(Int($0.rounded())) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
            .tint(AppPalette.accent)
        }
    }
}
