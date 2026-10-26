import SwiftUI
import UIKit

/// SpendWise's colours: the Android Material 3 scheme (deep green for money and progress, warm
/// amber for highlights), the same hex values in light and dark.
enum Palette {
    static let primary = dynamic(0x0F6D3D, 0x7FDAA0)
    static let onPrimary = dynamic(0xFFFFFF, 0x00391D)
    static let primaryContainer = dynamic(0x9BF7BA, 0x00522C)
    static let onPrimaryContainer = dynamic(0x00210F, 0xC6FFD5)
    static let secondary = dynamic(0x38665D, 0xA0D0C5)
    static let secondaryContainer = dynamic(0xBCECE1, 0x1F4D45)
    static let onSecondaryContainer = dynamic(0x00201B, 0xBCECE1)
    static let tertiary = dynamic(0x7C5800, 0xF6BE48)
    static let onTertiary = dynamic(0xFFFFFF, 0x271900)
    static let tertiaryContainer = dynamic(0xFFDEA6, 0x5E4200)
    static let onTertiaryContainer = dynamic(0x271900, 0xFFDEA6)
    static let error = dynamic(0xBA1A1A, 0xFFB4AB)
    static let errorContainer = dynamic(0xFFDAD6, 0x93000A)
    static let onErrorContainer = dynamic(0x410002, 0xFFDAD6)
    static let surface = dynamic(0xF6FBF4, 0x0F1511)
    static let onSurface = dynamic(0x171D19, 0xDEE4DE)
    static let surfaceVariant = dynamic(0xDCE5DA, 0x404941)
    static let onSurfaceVariant = dynamic(0x404941, 0xC0C9BF)
    static let containerLowest = dynamic(0xFFFFFF, 0x0A0F0C)
    static let containerLow = dynamic(0xF0F5EE, 0x171D19)
    static let container = dynamic(0xEAEFE9, 0x1B211D)
    static let containerHigh = dynamic(0xE4EAE3, 0x252B27)
    static let containerHighest = dynamic(0xDEE4DE, 0x303632)
    static let outline = dynamic(0x707970, 0x8A938A)
    static let outlineVariant = dynamic(0xC0C9BF, 0x404941)

    /// Premium's gold (the theme's amber, brighter): badges, the Upgrade page.
    static let gold = Color(rgb: 0xF2A007)
    static let goldLight = Color(rgb: 0xFFD45C)
    /// Snackbars: dark in both themes, with a light green action.
    static let snackbar = Color(rgb: 0x2C322E)
    static let onSnackbar = Color(rgb: 0xEEF2EC)
    static let snackbarAction = Color(rgb: 0x7FDAA0)

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(rgb: UInt32) { self.init(UIColor(rgb: rgb)) }

    /// An Android colour Int (ARGB, signed).
    init(argb: Int32) {
        let v = UInt32(bitPattern: argb)
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255, opacity: Double((v >> 24) & 0xFF) / 255)
    }

    /// Back to an Android colour Int (opaque).
    var argb: Int32 {
        let c = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        let v = UInt32(0xFF) << 24 | UInt32(max(0, min(255, (r * 255).rounded()))) << 16
            | UInt32(max(0, min(255, (g * 255).rounded()))) << 8 | UInt32(max(0, min(255, (b * 255).rounded())))
        return Int32(bitPattern: v)
    }
}

/// The Android type scale on the system font (proper Arabic glyphs) and Dynamic Type styles.
extension Font {
    static let headlineL = Font.title.weight(.bold)
    static let headlineM = Font.title2.weight(.bold)
    static let headlineS = Font.title3.weight(.semibold)
    static let titleL = Font.title3.weight(.semibold)
    static let titleM = Font.headline
    static let titleS = Font.subheadline.weight(.semibold)
    static let bodyL = Font.body
    static let bodyM = Font.subheadline
    static let bodyS = Font.footnote
    static let labelL = Font.subheadline.weight(.semibold)
    static let labelM = Font.caption.weight(.semibold)
    static let labelS = Font.caption2.weight(.medium)
}

let maxContentWidth: CGFloat = 640

extension View {
    /// Centres content at maxContentWidth on iPad and in landscape.
    func readableWidth() -> some View { frame(maxWidth: maxContentWidth).frame(maxWidth: .infinity) }

    /// A Material card: rounded, on a container colour.
    func card(_ color: Color = Palette.containerLow, radius: CGFloat = 20) -> some View {
        background(color, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Filled buttons (Material's FilledButton).
struct FilledButtonStyle: ButtonStyle {
    var background: Color = Palette.primary
    var foreground: Color = Palette.onPrimary
    var height: CGFloat = 50
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.labelL)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: height)
            .padding(.horizontal, 16)
            .foregroundStyle(foreground)
            .background(background.opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.35), in: Capsule())
    }
}

/// Tonal buttons (Material's FilledTonalButton).
struct TonalButtonStyle: ButtonStyle {
    var height: CGFloat = 44
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.labelL)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(minHeight: height)
            .padding(.horizontal, 18)
            .foregroundStyle(Palette.onSecondaryContainer)
            .background(Palette.secondaryContainer.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4), in: Capsule())
    }
}

/// Outlined buttons.
struct OutlineButtonStyle: ButtonStyle {
    var height: CGFloat = 44
    var color: Color = Palette.primary
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.labelL)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(minHeight: height)
            .padding(.horizontal, 18)
            .foregroundStyle(color)
            .background(configuration.isPressed ? Palette.containerHigh : .clear, in: Capsule())
            .overlay(Capsule().stroke(Palette.outline, lineWidth: 1))
            .opacity(enabled ? 1 : 0.4)
    }
}

/// A rounded text field, like Android's outlined fields.
struct FieldStyle: ViewModifier {
    var error = false
    var focused = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Palette.containerLowest, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(error ? Palette.error : focused ? Palette.primary : Palette.outline,
                                                                lineWidth: error || focused ? 2 : 1))
    }
}

extension View {
    func fieldStyle(error: Bool = false, focused: Bool = false) -> some View { modifier(FieldStyle(error: error, focused: focused)) }
}
