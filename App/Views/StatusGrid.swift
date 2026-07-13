import HexaKeyboardCore
import Foundation
import SwiftUI

struct StatusGrid: View {
    @ObservedObject var model: KeyboardViewModel

    private let rows = [
        GridItem(.fixed(76), spacing: 10),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: rows, alignment: .center, spacing: 10) {
                MetricCard(title: "键数", value: String(model.layout.cells.count), width: 142)
                MetricCard(
                    title: "生成 / 略过",
                    value: "+\(model.layout.stats.generated) / -\(model.layout.stats.omitted)",
                    width: 158
                )
                MetricCard(title: "选中", value: coordinateText, width: 170)
                MetricCard(
                    title: "音级",
                    value: selectedKey.map { String($0.pitchClass) } ?? "-",
                    width: 128
                )
                MetricCard(title: "频率", value: frequencyText, width: 170)
                MetricCard(title: "微分音", value: tuningText, width: 196)
                AudioMetricCard(engine: model.audioEngine)
                MetricCard(title: "短周期向量", value: vectorText, width: 245)
            }
        }
        .frame(height: 76)
    }

    private var selectedKey: HexKey? { model.selectedKey }

    private var coordinateText: String {
        guard let key = selectedKey else { return "-" }
        return "(\(key.q), \(key.r), \(key.s))"
    }

    private var frequencyText: String {
        guard let pitch = selectedKey?.audioPitch, pitch.isPlayable else { return "超出音域" }
        return String(format: "%.3f Hz", pitch.frequency)
    }

    private var tuningText: String {
        guard let pitch = selectedKey?.audioPitch, let midiKey = pitch.midiKey else { return "不可发声" }
        return String(format: "MIDI %d %+.2f c", midiKey, pitch.cents)
    }

    private var vectorText: String {
        guard !model.layout.periodVectors.isEmpty else { return "未找到" }
        return model.layout.periodVectors.enumerated().map { index, vector in
            "P\(index + 1)=(\(vector.dq),\(vector.dr))"
        }.joined(separator: "  ")
    }
}

private struct AudioMetricCard: View {
    @ObservedObject var engine: PolyphonicAudioEngine

    var body: some View {
        MetricCard(
            title: "音色",
            value: engine.statusText,
            emphasized: engine.isReady,
            width: 190
        )
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    var emphasized = false
    var width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AppPalette.secondaryText)
            Text(value)
                .font(.system(.subheadline, design: .monospaced, weight: .bold))
                .foregroundStyle(emphasized ? AppPalette.accent : AppPalette.primaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.76)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(width: width, height: 76)
        .toolSurface()
    }
}
