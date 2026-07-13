import SwiftUI
import UIKit

enum AppPalette {
    static let background = Color(red: 0.055, green: 0.075, blue: 0.073)
    static let surface = Color(red: 0.086, green: 0.112, blue: 0.108)
    static let raisedSurface = Color(red: 0.105, green: 0.132, blue: 0.128)
    static let line = Color(red: 0.22, green: 0.29, blue: 0.28)
    static let primaryText = Color(red: 0.93, green: 0.96, blue: 0.95)
    static let secondaryText = Color(red: 0.61, green: 0.68, blue: 0.66)
    static let accent = Color(red: 0.25, green: 0.78, blue: 0.80)
    static let selection = Color(red: 1.00, green: 0.61, blue: 0.27)

    static let uiBackground = UIColor(red: 0.055, green: 0.075, blue: 0.073, alpha: 1)
    static let uiLine = UIColor(red: 0.20, green: 0.27, blue: 0.26, alpha: 1)
    static let uiPrimaryText = UIColor(red: 0.94, green: 0.97, blue: 0.96, alpha: 1)
    static let uiSecondaryText = UIColor(red: 0.66, green: 0.72, blue: 0.70, alpha: 1)
    static let uiAccent = UIColor(red: 0.25, green: 0.78, blue: 0.80, alpha: 1)
    static let uiSelection = UIColor(red: 1.00, green: 0.61, blue: 0.27, alpha: 1)
    static let uiOutline = UIColor(red: 0.68, green: 0.67, blue: 1.00, alpha: 0.90)
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
