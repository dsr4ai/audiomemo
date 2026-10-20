import AppKit
import SwiftUI

/// 除錯／測試用的自我截圖：`open AudioMemo.app --args -storageFolder <測試資料夾> -snapshotStates <輸出資料夾>`
/// App 依序把自己切到各狀態，用 NSView.cacheDisplay 把自己的視窗畫成 PNG（不需要螢幕錄影權限），淺色＋深色各一套，做完結束。
/// ⛔ 一定要搭配 -storageFolder，錄音只寫到測試資料夾。「儲存中」一閃即過，截圖時是模擬顯示。
@MainActor
enum SnapshotRunner {
    static func runIfRequested() {
        guard let out = UserDefaults.standard.string(forKey: "snapshotStates") else { return }
        guard UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["storageFolder"] != nil else {
            DebugLog.write("snapshot: refused, -storageFolder is required"); NSApp.terminate(nil); return
        }
        let dir = URL(fileURLWithPath: (out as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if UserDefaults.standard.string(forKey: "snapshotSet") == "upload" {
            Task { await runUpload(dir, prefix: UserDefaults.standard.string(forKey: "snapshotPrefix") ?? "x") }
        } else if UserDefaults.standard.string(forKey: "snapshotSet") == "transcribe" {
            Task { await runTranscribe(dir, prefix: UserDefaults.standard.string(forKey: "snapshotPrefix") ?? "x") }
        } else if UserDefaults.standard.string(forKey: "snapshotSet") == "list" {
            Task { await runList(dir, prefix: UserDefaults.standard.string(forKey: "snapshotPrefix") ?? "x") }
        } else if UserDefaults.standard.string(forKey: "snapshotSet") == "i18n" {
            Task { await runI18n(dir, prefix: UserDefaults.standard.string(forKey: "snapshotPrefix") ?? "x") }
        } else {
            Task { await run(dir) }
        }
    }

    /// 一鍵上傳到 Osmi：上傳中（按鈕＋右上提示區）、失敗（重試）。用 -osmiBaseURL 指向測試伺服器（可限速）。
    private static func runUpload(_ dir: URL, prefix: String) async {
        await sleep(1.5)
        guard let r = AppModel.shared.store.recordings.first else { NSApp.terminate(nil); return }
        let up = AppModel.shared.uploader
        for (theme, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: name)
            up.start(r)
            for _ in 0..<100 { if case .uploading(let p) = up.phase, p > 0.3 { break }; await sleep(0.1) }
            await sleep(0.4)
            capture("\(prefix)-\(theme)-upload-progress", dir)
            up.cancel()
            await sleep(0.6)
        }
        NSApp.terminate(nil)
    }

    /// 「轉成逐字稿」按鈕 hover 前後（淺／深色）。
    private static func runTranscribe(_ dir: URL, prefix: String) async {
        await sleep(1.5)
        guard let r = AppModel.shared.store.recordings.first else { NSApp.terminate(nil); return }
        for (theme, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: name)
            await sleep(0.6)
            capture("\(prefix)-\(theme)-transcribe-normal", dir)
            NotificationCenter.default.post(name: TranscribeButton.debugExpand, object: r.url, userInfo: ["on": true])
            await sleep(0.7)
            capture("\(prefix)-\(theme)-transcribe-hover", dir)
            NotificationCenter.default.post(name: TranscribeButton.debugExpand, object: r.url, userInfo: ["on": false])
            await sleep(0.5)
            // 播放中那一列
            AppModel.shared.player.play(r.url); AppModel.shared.player.pauseIfPlaying()
            await sleep(0.4)
            capture("\(prefix)-\(theme)-transcribe-playing-normal", dir)
            NotificationCenter.default.post(name: TranscribeButton.debugExpand, object: r.url, userInfo: ["on": true])
            await sleep(0.7)
            capture("\(prefix)-\(theme)-transcribe-playing-hover", dir)
            NotificationCenter.default.post(name: TranscribeButton.debugExpand, object: r.url, userInfo: ["on": false])
            AppModel.shared.player.stop()
            await sleep(0.5)
        }
        NSApp.terminate(nil)
    }

    /// 檔案列表：視窗最窄＋播放中、行內改名中。
    private static func runList(_ dir: URL, prefix: String) async {
        NSApp.appearance = NSAppearance(named: .aqua)
        await sleep(1.5)
        guard let win = mainWindow else { NSApp.terminate(nil); return }
        var f = win.frame; f.size.width = 600; win.setFrame(f, display: true)   // 最小寬度
        await sleep(0.6)
        let store = AppModel.shared.store
        if let r = store.recordings.first {
            AppModel.shared.player.play(r.url)
            await sleep(1.2)
            capture("\(prefix)-list-narrow-playing", dir)
            AppModel.shared.player.stop()
            await sleep(0.3)
            NotificationCenter.default.post(name: RecordingRow.startRenameNotification, object: r.url)
            await sleep(0.6)
            capture("\(prefix)-list-rename-inline", dir)
            // 改名規則測試（只在 -renameTest YES 時，測試資料夾）
            if UserDefaults.standard.bool(forKey: "renameTest"), store.recordings.count >= 2 {
                let a = store.recordings[0], b = store.recordings[1]
                store.renameInline(a, to: b.name)          // 重名 → 自動加序號
                await sleep(0.5)
                if let c = store.recordings.first(where: { $0.name.hasPrefix(b.name + " (") }) {
                    DebugLog.write("renameTest duplicate -> \(c.name)")
                    store.renameInline(c, to: "   ")       // 空白 → 恢復原名
                    store.renameInline(c, to: "a/b")       // 非法字元 → 恢復原名
                    await sleep(0.3)
                    DebugLog.write("renameTest after empty/illegal still exists: \(FileManager.default.fileExists(atPath: c.url.path))")
                    store.renameInline(c, to: a.name)      // 改回原名
                }
            }
        }
        NSApp.terminate(nil)
    }

    /// 多語排版檢查：淺色一套（待機、錄音中、翻牌中、提示、播放中、設定、轉檔選單）。
    private static func runI18n(_ dir: URL, prefix: String) async {
        let rec = AppModel.shared.recorder, player = AppModel.shared.player
        NSApp.appearance = NSAppearance(named: .aqua)
        await sleep(1.5)
        capture("\(prefix)-1-ready", dir)
        rec.start()
        for _ in 0..<60 where rec.phase != .recording { await sleep(0.25) }
        await sleep(1.2)
        capture("\(prefix)-2-recording", dir)
        // 翻牌連拍（正常速度）：每 0.05 秒一格，共 8 格
        if !UserDefaults.standard.bool(forKey: "slowFlap") {
            AppModel.shared.notices.post(.switchedDevice(device: "USB Microphone"))
            for k in 0..<8 { captureLayer("\(prefix)-flapburst-\(k)", dir); await sleep(0.05) }
            AppModel.shared.notices.dismiss()
            await sleep(0.5)
        }
        // 翻牌：-slowFlap YES 時一次翻牌約 2.2 秒，取中間兩格
        AppModel.shared.notices.post(.followedApp(app: "Zoom", device: "MacBook Pro Microphone"))
        await sleep(FlapText.half * 0.5); captureLayer("\(prefix)-3-flap-a", dir)
        await sleep(FlapText.half * 0.9); captureLayer("\(prefix)-3-flap-b", dir)
        await sleep(FlapText.half * 1.2); capture("\(prefix)-3-flap-done", dir)
        rec.stopNow()
        AppModel.shared.notices.dismiss()
        await sleep(0.4)
        if let url = rec.lastSavedURL {
            player.play(url); await sleep(1.2)
            capture("\(prefix)-4-playing", dir)
            player.stop()
        }
        AppModel.shared.notices.post(.bluetoothWarning(device: "AirPods Pro"))
        await sleep(FlapText.half * 2 + 0.4)
        capture("\(prefix)-5-sticky-notice", dir)
        AppModel.shared.notices.dismiss()
        // 設定視窗
        // 設定畫面：放進離屏視窗的 NSHostingView 再畫（不靠系統的設定視窗）
        do {
            let host = NSHostingView(rootView: SettingsView().environment(\.layoutDirection, appLayoutDirection))
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
            win.contentView = host
            win.appearance = NSAppearance(named: .aqua)
            host.layoutSubtreeIfNeeded()
            await sleep(0.8)
            host.display()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(prefix)-6-settings.png"))
            }
        }
        // 轉檔選單（NSMenu 是獨立視窗、無法自我截圖 → 用同樣的字串畫一份樣張）
        let mock = MenuMock(items: [L("action.play"), L("action.transcribe"), L("action.revealInFinder"), "-",
                                    L("action.rename"), L("action.delete"), L("action.convert") + "  ›"],
                            sub: ExportFormat.allCases.map(\.title))
        let r = ImageRenderer(content: mock.environment(\.layoutDirection, NSApp.userInterfaceLayoutDirection == .rightToLeft ? .rightToLeft : .leftToRight))
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("\(prefix)-7-convert-menu.png"))
        }
        await sleep(0.3)
        NSApp.terminate(nil)
    }

    /// 動畫中的畫格：用 CALayer 的 presentation 樹來畫（cacheDisplay 只畫模型值，看不到動畫中途）。
    private static func captureLayer(_ name: String, _ dir: URL) {
        guard let win = mainWindow, let view = win.contentView, let layer = view.layer else { return }
        let scale = win.backingScaleFactor
        let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: scale, y: -scale)
        (layer.presentation() ?? layer).render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        DebugLog.write("snapshot(layer): \(name).png")
    }

    private static func captureWindow(_ win: NSWindow, _ name: String, _ dir: URL) {
        guard let view = win.contentView?.superview ?? win.contentView else { return }
        let scale = win.backingScaleFactor
        let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
        guard let layer = view.layer,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(NSColor.windowBackgroundColor.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: scale, y: -scale)
        layer.render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }

    /// 主視窗（用 SwiftUI 的 window id 找，不靠標題：偽語系會改標題）。
    static var mainWindow: NSWindow? {
        NSApp.windows.first { ($0.identifier?.rawValue ?? "").hasPrefix("main") }
    }

    private static func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    private static func capture(_ name: String, _ dir: URL) {
        guard let win = mainWindow,
              let content = win.contentView else { DebugLog.write("snapshot: no window for \(name)"); return }
        let view = content.superview ?? content   // 含標題列
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = dir.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        DebugLog.write("snapshot: \(url.lastPathComponent)")
    }

    private static func run(_ dir: URL) async {
        let rec = AppModel.shared.recorder
        let player = AppModel.shared.player
        await sleep(1.5)
        for (theme, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: name)
            await sleep(0.8)
            capture("\(theme)-1-ready", dir)

            rec.start()
            for _ in 0..<60 where rec.phase != .recording { await sleep(0.25) }
            await sleep(1.6)
            capture("\(theme)-2-recording", dir)

            rec.toggleMicMute(); rec.toggleSysMute()
            await sleep(1.0)
            capture("\(theme)-3-both-muted", dir)
            rec.toggleMicMute(); rec.toggleSysMute()

            rec.pauseResume()
            await sleep(0.8)
            capture("\(theme)-4-paused", dir)
            rec.pauseResume()
            await sleep(0.6)

            rec.stopNow()
            rec.debugShowPhase(.saving)
            await sleep(0.5)
            capture("\(theme)-5-saving", dir)
            rec.debugShowPhase(.idle)

            if let url = rec.lastSavedURL {
                player.play(url)
                // 連拍 3 張（每 0.25 秒）：看進度條是不是連續小步移動
                for k in 1...3 { await sleep(0.25); capture("\(theme)-6-playing-burst\(k)", dir) }
                await sleep(0.75)
                capture("\(theme)-6-playing", dir)
                player.stop()
            }

            rec.errorMessage = L("error.micDenied")
            await sleep(0.5)
            capture("\(theme)-7-error", dir)
            rec.errorMessage = nil
            AppModel.shared.notices.dismiss()
        }
        await sleep(0.3)
        NSApp.terminate(nil)
    }
}

/// 選單樣張（只用來檢查字串長度與 RTL 對齊，不是真正的 NSMenu）。
private struct MenuMock: View {
    let items: [String]
    let sub: [String]
    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            box(items)
            box(sub)
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    private func box(_ list: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(list.enumerated()), id: \.offset) { _, t in
                if t == "-" { Divider().padding(.vertical, 3) } else {
                    Text(t).font(.system(size: 13)).padding(.horizontal, 10).padding(.vertical, 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 5)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)).shadow(radius: 3))
    }
}
