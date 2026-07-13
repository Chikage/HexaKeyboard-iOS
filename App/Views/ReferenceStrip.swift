import SwiftUI

struct ReferenceStrip: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                coordinateReference
                Divider().overlay(AppPalette.line)
                neighborReference
                Divider().overlay(AppPalette.line)
                periodReference
            }
            VStack(alignment: .leading, spacing: 16) {
                coordinateReference
                neighborReference
                periodReference
            }
        }
        .padding(15)
        .toolSurface()
    }

    private var coordinateReference: some View {
        referenceColumn(title: "位置坐标") {
            Text("轴坐标 (q, r)，第三轴 s = -q-r")
        }
    }

    private var neighborReference: some View {
        referenceColumn(title: "六个邻居") {
            Text("E (1,0)   NE (1,-1)   NW (0,-1)\nW (-1,0)   SW (-1,1)   SE (0,1)")
        }
    }

    private var periodReference: some View {
        referenceColumn(title: "周期定义") {
            Text("dq×gq + dr×gr ≡ 0  (mod N)")
        }
    }

    private func referenceColumn<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppPalette.primaryText)
            content()
                .font(.caption.monospaced())
                .foregroundStyle(AppPalette.secondaryText)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
    }
}
