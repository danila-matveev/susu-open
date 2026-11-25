// Design tokens: colors. Source of truth is docs/design/prototype/tokens.css (v2, «Тёплый мак»).
// Values are precomputed sRGB from the oklch originals (noted in each doc comment).
// Colors are dynamic: they follow the window appearance, so `.preferredColorScheme` switches them live.
import SwiftUI
import AppKit

extension Color {
    /// A color that resolves to `light` or `dark` hex (0xRRGGBB) by the current appearance.
    init(light: UInt32, lightAlpha: Double = 1, dark: UInt32, darkAlpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            let alpha = isDark ? darkAlpha : lightAlpha
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
        })
    }
}

/// Susu palette. Usage: `Palette.bg`, `Palette.ink2`, `.foregroundStyle(Palette.accent)`.
public enum Palette {
    /// light oklch(0.968 0.005 80); dark oklch(0.195 0.005 70)
    public static let bg = Color(light: 0xF6F4F1, dark: 0x161513)
    /// light oklch(1 0 0); dark oklch(0.235 0.006 70)
    public static let bgCard = Color(light: 0xFFFFFF, dark: 0x201E1B)
    /// light oklch(0.958 0.005 80); dark oklch(0.27 0.006 70)
    public static let bgGroup = Color(light: 0xF3F1ED, dark: 0x282623)
    /// light oklch(0.925 0.006 80); dark oklch(0.31 0.006 70)
    public static let bgFill = Color(light: 0xE8E6E2, dark: 0x32302D)
    /// light oklch(0.25 0.01 70) α0.05; dark oklch(1 0 0) α0.06
    public static let bgHover = Color(light: 0x25211D, lightAlpha: 0.05, dark: 0xFFFFFF, darkAlpha: 0.06)
    /// light oklch(0.9 0.006 80); dark oklch(0.29 0.006 70)
    public static let bgSelected = Color(light: 0xE0DEDA, dark: 0x2D2B28)
    /// light oklch(0.25 0.01 70) α0.09; dark oklch(1 0 0) α0.08
    public static let line = Color(light: 0x25211D, lightAlpha: 0.09, dark: 0xFFFFFF, darkAlpha: 0.08)
    /// light oklch(0.25 0.01 70) α0.16; dark oklch(1 0 0) α0.15
    public static let lineStrong = Color(light: 0x25211D, lightAlpha: 0.16, dark: 0xFFFFFF, darkAlpha: 0.15)
    /// light oklch(0.21 0.008 70); dark oklch(0.95 0.004 80)
    public static let ink = Color(light: 0x1B1814, dark: 0xF0EEEB)
    /// light oklch(0.45 0.008 70); dark oklch(0.76 0.006 80)
    public static let ink2 = Color(light: 0x585551, dark: 0xB3B1AD)
    /// light oklch(0.52 0.008 70); dark oklch(0.65 0.006 80)
    public static let ink3 = Color(light: 0x6C6864, dark: 0x918F8B)
    /// light oklch(0.43 0.11 258); dark oklch(0.74 0.1 255)
    public static let accent = Color(light: 0x264F8B, dark: 0x7FAEE9)
    /// light oklch(0.94 0.025 250); dark oklch(0.32 0.045 255)
    public static let accentSoft = Color(light: 0xDFEDFC, dark: 0x23344A)
    /// light oklch(0.43 0.11 258); dark oklch(0.8 0.09 255)
    public static let accentInk = Color(light: 0x264F8B, dark: 0x97C1F7)
    /// light oklch(0.99 0 0); dark oklch(0.17 0.02 258)
    public static let onAccent = Color(light: 0xFCFCFC, dark: 0x0A1018)
    /// light oklch(0.74 0.14 70); dark oklch(0.8 0.13 75)
    public static let call = Color(light: 0xE29936, dark: 0xEEB154)
    /// light oklch(0.95 0.04 80); dark oklch(0.33 0.05 75)
    public static let callSoft = Color(light: 0xFDECD1, dark: 0x443116)
    /// light oklch(0.5 0.11 65); dark oklch(0.85 0.12 75)
    public static let callInk = Color(light: 0x8D5406, dark: 0xFCC270)
    /// light oklch(0.49 0.11 150); dark oklch(0.76 0.12 150)
    public static let ok = Color(light: 0x27713D, dark: 0x76C788)
    /// light oklch(0.94 0.035 150); dark oklch(0.32 0.05 150)
    public static let okSoft = Color(light: 0xDCF2DF, dark: 0x1F3A25)
    /// light oklch(0.53 0.13 35); dark oklch(0.73 0.12 40)
    public static let error = Color(light: 0xA94B34, dark: 0xE78C6D)
    /// light oklch(0.95 0.025 35); dark oklch(0.32 0.05 40)
    public static let errorSoft = Color(light: 0xFFE9E3, dark: 0x492A1F)
    /// light oklch(0.55 0.13 258) α0.45; dark oklch(0.74 0.1 255) α0.55
    public static let focus = Color(light: 0x3E71BC, lightAlpha: 0.45, dark: 0x7FAEE9, darkAlpha: 0.55)
    /// light oklch(0.18 0.006 70) α0.95; dark oklch(0.14 0.005 70) α0.95
    public static let hud = Color(light: 0x13110F, lightAlpha: 0.95, dark: 0x0A0907, darkAlpha: 0.95)
    /// light oklch(0.98 0 0); dark oklch(0.98 0 0)
    public static let hudInk = Color(light: 0xF8F8F8, dark: 0xF8F8F8)
    /// light oklch(0.98 0 0) α0.62; dark oklch(0.98 0 0) α0.62
    public static let hudInk2 = Color(light: 0xF8F8F8, lightAlpha: 0.62, dark: 0xF8F8F8, darkAlpha: 0.62)
    /// light oklch(1 0 0) α0.14; dark oklch(1 0 0) α0.14
    public static let hudLine = Color(light: 0xFFFFFF, lightAlpha: 0.14, dark: 0xFFFFFF, darkAlpha: 0.14)
    /// light oklch(0.25 0.01 70) α0.08; dark oklch(1 0 0) α0.07
    public static let shadowRing = Color(light: 0x25211D, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.07)
}
