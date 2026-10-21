import AppKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject var recorder: RecordingController
    @EnvironmentObject var store: FileStore
    @EnvironmentObject var player: PlaybackController
    @EnvironmentObject var uploader: OsmiUploader

    var body: some View {
        VStack(spacing: 16) {
            RecordingPanel()
            FileListView()
        }
        .padding(16)
        .frame(minWidth: 600, minHeight: 560)   // 最窄時右邊按鈕仍是原尺寸，由檔名先截斷
        .background(Theme.bg)
        .tint(Theme.p500)
        .onChange(of: recorder.finishedCount) { _, _ in store.refresh() }
        .onChange(of: recorder.currentURL) { _, url in store.refresh(excluding: url) }
        .onChange(of: recorder.phase) { _, ph in if ph != .idle { player.stop() } }   // 開始錄音就停掉播放
        .sheet(isPresented: $uploader.showLogin) { OsmiLoginSheet() }
    }
}

/// 第一次按「讓Osmi聽寫逐字稿」（或登入過期）時出現：用 Google 或 Apple 登入，登入後自動上傳剛才那個錄音。
struct OsmiLoginSheet: View {
    @EnvironmentObject var uploader: OsmiUploader

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("osmi.login.title"))
                .font(.system(size: 15, weight: .semibold))
            Text(L("osmi.login.note"))
                .font(.system(size: Theme.fsSmall))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            Button { uploader.signIn(.google) } label: {
                Label(L("osmi.login.google"), systemImage: "g.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            Button { uploader.signIn(.apple) } label: {
                Label(L("osmi.login.apple"), systemImage: "apple.logo")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            if let e = uploader.loginError {
                Text(e)
                    .font(.system(size: Theme.fsSmall))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L("osmi.login.cancel")) { uploader.cancelLogin() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 360)
    }
}

// MARK: - 錄音面板：大計時、兩條音量、暫停／繼續、停止、狀態字

struct RecordingPanel: View {
    @EnvironmentObject var recorder: RecordingController
    @EnvironmentObject var player: PlaybackController
    @EnvironmentObject var notices: NoticeCenter
    @EnvironmentObject var uploader: OsmiUploader
    @EnvironmentObject var mics: MicrophoneManager

    private var recording: Bool { recorder.phase == .recording }

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                StatusIndicator(status: RecorderStatus(phase: recorder.phase, hasError: recorder.errorMessage != nil,
                                                       playing: player.isPlaying))
                Spacer(minLength: 12)
                // 提示區：平常顯示目前的麥克風；有提示時用翻牌換字，約 4 秒後翻回
                FlapText(item: flapItem, onDismiss: dismissNotice, onAction: { id in
                    switch id {
                    case "cancel": uploader.cancel()
                    case "retry": uploader.retry()
                    default: uploader.reset()
                    }
                })
                    .layoutPriority(-1)
            }

            // 播放中：大計時顯示播放位置（品牌藍）；其餘顯示錄音時間（錄音中才用錄音紅）
            let showingPlayback = !recorder.isActive && player.isActive
            Text(RecordingController.format(showingPlayback ? player.currentTime : recorder.elapsed))
                .font(.system(size: Theme.fsTimer, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(recording ? Theme.rec : (showingPlayback ? Theme.p500 : Theme.ink))
                .environment(\.layoutDirection, .leftToRight)   // 計時數字一律由左往右
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityLabel(L("a11y.elapsed"))

            // Grid：兩條的標籤欄寬自動取較長的那個（不寫死寬度，長語系不會被截）
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                LevelMeter(title: L("level.mic"), icon: "mic.fill", mutedIcon: "mic.slash.fill",
                           level: recorder.micLevel, active: recorder.isActive, muted: recorder.micMuted,
                           onToggleMute: recorder.toggleMicMute)
                LevelMeter(title: L("level.system"), icon: "speaker.wave.2.fill", mutedIcon: "speaker.slash.fill",
                           level: recorder.sysLevel, active: recorder.isActive, muted: recorder.sysMuted,
                           onToggleMute: recorder.toggleSysMute)
            }

            HStack(spacing: 12) {
                switch recorder.phase {
                case .idle:
                    Button { recorder.start() } label: {
                        Label(L("action.startRecording"), systemImage: "circle.fill")
                    }
                    .buttonStyle(FilledButtonStyle())
                    .keyboardShortcut("r", modifiers: .command)
                case .starting, .recording, .paused, .saving:
                    Button { recorder.pauseResume() } label: {
                        Label(recorder.phase == .paused ? L("action.resume") : L("action.pause"),
                              systemImage: recorder.phase == .paused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(recorder.phase == .starting || recorder.phase == .saving)
                    .opacity(recorder.phase == .starting || recorder.phase == .saving ? 0.4 : 1)
                    Button { recorder.stop() } label: {
                        Label(L("action.stop"), systemImage: "stop.fill")
                    }
                    .buttonStyle(FilledButtonStyle())
                    .keyboardShortcut(".", modifiers: .command)
                }
            }

            Text(L("hint.whatIsRecorded"))
                .font(.system(size: Theme.fsCaption))
                .foregroundStyle(Theme.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .card()
    }

    /// 提示區目前的內容：有提示就顯示提示，沒有就顯示常駐的「目前麥克風」。
    private var flapItem: FlapItem {
        // 上傳到 Osmi 的進度優先顯示（同一個 key：進度更新不翻牌）
        switch uploader.phase {
        case .preparing:
            return FlapItem(symbol: "arrow.up.circle", text: L("upload.preparing"), color: Theme.primaryText, key: "upload",
                            actions: [FlapAction(id: "cancel", title: L("action.cancel"))])
        case .uploading(let p):
            // 送完最後一個位元組後還要等伺服器回應：顯示「完成中」而不是停在 100%
            return FlapItem(symbol: "arrow.up.circle", text: p >= 0.999 ? L("upload.finishing") : String(format: L("upload.progress"), Int(p * 100)), color: Theme.primaryText,
                            key: "upload", actions: [FlapAction(id: "cancel", title: L("action.cancel"))])
        case .failed(let msg):
            return FlapItem(symbol: "exclamationmark.triangle", text: String(format: L("upload.failed"), msg), color: Theme.warn,
                            key: "upload-failed", actions: [FlapAction(id: "retry", title: L("action.retry")),
                                                             FlapAction(id: "close", title: L("action.dismiss"))])
        case .opening, .idle:
            break
        }
        if let n = notices.current {
            return FlapItem(symbol: n.symbol, text: n.text, color: n.color, dismissible: n.isSticky || isError(n))
        }
        let name = DemoMode.micName ?? mics.active?.name ?? L("settings.noMic")
        let text = mics.followsSystem ? String(format: L("mic.followingSystem"), name) : name
        return FlapItem(symbol: "mic", text: text, color: Theme.ink2)
    }

    private func isError(_ n: Notice) -> Bool { if case .message = n { return true } else { return false } }

    private func dismissNotice() {
        if case .bluetoothWarning = notices.current { mics.dismissBluetoothWarning() } else { notices.dismiss() }
        if let c = notices.current, isError(c) { recorder.errorMessage = nil }
        if recorder.errorMessage != nil { recorder.errorMessage = nil }
    }
}

struct LevelMeter: View {
    let title: String
    let icon: String
    let mutedIcon: String
    let level: Float
    let active: Bool
    let muted: Bool
    let onToggleMute: () -> Void

    var body: some View {
        GridRow {
            // 靜音鈕：按一下該軌寫入靜音，再按一下恢復；錄音中可隨時切換
            Button(action: onToggleMute) {
                Image(systemName: muted ? mutedIcon : icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 22)
                    .foregroundStyle(muted ? Theme.ink3 : Theme.p500)
                    .background(muted ? Theme.lineSoft : Theme.p100)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(muted ? L("action.unmuteTrack") : L("action.muteTrack"))
            .accessibilityLabel(String(format: L("a11y.trackButton"), title, muted ? L("action.unmuteTrack") : L("action.muteTrack")))

            Text(muted ? String(format: L("level.mutedFormat"), title) : title)
                .font(.system(size: Theme.fsCaption))
                .foregroundStyle(muted ? Theme.ink3 : Theme.ink2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 60, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(muted ? Theme.lineSoft : Theme.p100)
                    Capsule().fill(muted ? Theme.ink3 : Theme.p500)
                        .frame(width: max(0, geo.size.width * CGFloat(active && !muted ? level : 0)))
                        .animation(.linear(duration: 0.05), value: level)
                }
            }
            .frame(height: 8)
            .frame(minWidth: 120)
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityValue(muted ? L("level.muted") : (NumberFormatter.localizedString(from: NSNumber(value: Double(level)), number: .percent)))
        }
    }
}

// MARK: - 分享按鈕（NSSharingServicePicker：AirDrop、郵件、訊息…）

struct ShareButton: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: L("action.share"))!
        let b = NSButton(image: image, target: context.coordinator, action: #selector(Coordinator.click(_:)))
        b.isBordered = false
        b.toolTip = L("action.share")
        b.setAccessibilityLabel(L("action.share"))
        b.contentTintColor = NSColor(Theme.p500)
        context.coordinator.url = url
        return b
    }

    func updateNSView(_ nsView: NSButton, context: Context) { context.coordinator.url = url }

    final class Coordinator: NSObject, NSSharingServicePickerDelegate {
        var url: URL?
        @objc func click(_ sender: NSButton) {
            guard let url else { return }
            let picker = NSSharingServicePicker(items: [url])
            picker.delegate = self
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            DebugLog.write("share picker shown \(url.lastPathComponent)")
        }
        func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            DebugLog.write("share chose \(service?.title ?? "none")")
        }
    }
}
