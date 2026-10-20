import AppKit
import SwiftUI

/// 色彩／字級／圓角：照 design/tokens.json（跨平台共用）。
/// ⛔ 元件不寫死色值，只用這裡的 token；淺色／深色各一組，跟系統外觀切換。
enum Theme {
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    private static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255, alpha: a)
    }
    private static func white(_ a: CGFloat) -> NSColor { NSColor(white: 1, alpha: a) }
    private static func black(_ a: CGFloat) -> NSColor { NSColor(white: 0, alpha: a) }

    // 主色階（品牌蔚藍 #81BDD6 = p300，只當強調色；互動色用 p500）
    static let p100 = dynamic(hex(0xE8F5FA), hex(0x18242E))
    static let p200 = dynamic(hex(0xCBE6F3), hex(0x22323F))
    static let p300 = dynamic(hex(0x81BDD6), hex(0x81BDD6))
    static let p500 = dynamic(hex(0x1479B8), hex(0x7FC4E6))
    static let p700 = dynamic(hex(0x0B4D83), hex(0xA9D6E8))
    static let onP500 = dynamic(hex(0xFFFFFF), hex(0x062033))

    // 錄音紅：唯一例外色，只用在錄音狀態
    static let rec = dynamic(hex(0xE53935), hex(0xFF6B67))
    static let recBg = dynamic(hex(0xE53935, 0.13), hex(0xFF6B67, 0.16))
    static let danger = dynamic(hex(0xCC3333), hex(0xFF8A80))
    static let warn = dynamic(hex(0xC77700), hex(0xF0A63C))   // 琥珀：已暫停

    // 中性色：透明度分級
    static let ink = dynamic(black(0.87), white(0.90))
    static let ink2 = dynamic(black(0.60), white(0.68))
    static let ink3 = dynamic(black(0.45), white(0.50))
    static let line = dynamic(black(0.12), white(0.14))
    static let lineSoft = dynamic(black(0.07), white(0.08))
    static let bg = dynamic(hex(0xF5F5F5), hex(0x10161C))
    static let surface = dynamic(hex(0xFFFFFF), hex(0x171F27))

    // 圓角
    static let rCard: CGFloat = 15
    static let rBtn: CGFloat = 8
    static let rPill: CGFloat = 999

    // 字級（tokens：display 32／title 22／body 16／caption 15／small 13）
    static let fsTitle: CGFloat = 22
    static let fsBody: CGFloat = 15
    static let fsCaption: CGFloat = 13
    static let fsSmall: CGFloat = 12
    static let fsTimer: CGFloat = 56

    /// 紅色錄音圖示（選單列用，非 template，才會保持紅色）。
    static func menuBarImage(recording: Bool) -> NSImage {
        let name = recording ? "record.circle.fill" : "waveform.circle"
        let base = NSImage(systemSymbolName: name, accessibilityDescription: "AudioMemo") ?? NSImage()
        guard recording else {
            base.isTemplate = true
            return base
        }
        let config = NSImage.SymbolConfiguration(paletteColors: [hex(0xE53935)])
        let img = base.withSymbolConfiguration(config) ?? base
        img.isTemplate = false
        return img
    }
}

extension View {
    func card() -> some View {
        self
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.rCard, style: .continuous).stroke(Theme.lineSoft))
            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }
}

/// 主要按鈕（p500 底、on-p500 字）。
struct FilledButtonStyle: ButtonStyle {
    var tint: Color = Theme.p500
    var foreground: Color = Theme.onP500
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Theme.fsBody, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(tint.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.rBtn, style: .continuous))
    }
}

/// 次要按鈕（外框）。
struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Theme.fsBody, weight: .medium))
            .foregroundStyle(Theme.p500)
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(Theme.p100.opacity(configuration.isPressed ? 1 : 0))
            .overlay(RoundedRectangle(cornerRadius: Theme.rBtn, style: .continuous).stroke(Theme.line))
            .contentShape(Rectangle())
    }
}
