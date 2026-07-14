import SwiftUI
import UIKit

enum AppPalette {
    static let background = Color(hex: 0x0E1313)
    static let surface = Color(hex: 0x161D1C)
    static let raisedSurface = Color(hex: 0x1B2221)
    static let line = Color(hex: 0x384A47)
    static let primaryText = Color(hex: 0xEDF5F2)
    static let secondaryText = Color(hex: 0x9BAEAA)
    static let accent = Color(hex: 0x40C7CC)
    static let selection = Color(hex: 0xFF9C45)
    static let outline = Color(hex: 0xAEABFF)

    static let playbackButton = Color(hex: 0x262B34).opacity(0.42)
    static let playbackPanel = Color(hex: 0x20252D).opacity(0.32)
    static let playbackActive = Color(hex: 0x1B6672).opacity(0.74)
    static let playbackDivider = Color(hex: 0x58606E).opacity(0.34)
    static let playbackMuted = Color(hex: 0xA6B0BE)

    static let uiBackground = UIColor(hex: 0x0E1313)
    static let uiSurface = UIColor(hex: 0x161D1C)
    static let uiRaisedSurface = UIColor(hex: 0x1B2221)
    static let uiLine = UIColor(hex: 0x384A47)
    static let uiPrimaryText = UIColor(hex: 0xEDF5F2)
    static let uiSecondaryText = UIColor(hex: 0x9BAEAA)
    static let uiAccent = UIColor(hex: 0x40C7CC)
    static let uiSelection = UIColor(hex: 0xFF9C45)
    static let uiOutline = UIColor(hex: 0xAEABFF)
}

private extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

private extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension View {
    func toolSurface() -> some View {
        background(AppPalette.surface)
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(AppPalette.line, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
