import AppKit
import SwiftUI

/// 除錯用：`open AudioMemo.app --args -renderPreviews <資料夾>` 把每個錄音狀態（淺色／深色）畫成 PNG 後結束。
/// 不需要螢幕錄影權限（離屏繪製）。呼吸燈畫成靜態。
@MainActor
enum PreviewRenderer {
    static func runIfRequested() -> Bool {
        guard let dir = UserDefaults.standard.string(forKey: "renderPreviews") else { return false }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                let view = VStack(alignment: .leading, spacing: 18) {
                    ForEach(RecorderStatus.allCases, id: \.self) { st in
                        HStack(spacing: 24) {
                            StatusIndicator(status: st, forceStill: true)
                                .frame(width: 150, alignment: .leading)
                            Text(String(describing: st)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ink3)
                        }
                    }
                }
                .padding(24)
                .background(Theme.surface)
                .environment(\.colorScheme, name == "dark" ? .dark : .light)
                save(view, url.appendingPathComponent("status-\(name).png"))
                let panel = RecordingPanel()
                    .environmentObject(AppModel.shared.recorder)
                    .environmentObject(AppModel.shared.player)
                    .frame(width: 560)
                    .padding(16)
                    .background(Theme.bg)
                    .environment(\.colorScheme, name == "dark" ? .dark : .light)
                save(panel, url.appendingPathComponent("panel-\(name).png"))
            }
        }
        NSApp.terminate(nil)
        return true
    }

    private static func save<V: View>(_ view: V, _ file: URL) {
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: file)
        }
    }
}
