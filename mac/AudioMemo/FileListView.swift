import AppKit
import SwiftUI

struct FileListView: View {
    @EnvironmentObject var store: FileStore
    @EnvironmentObject var recorder: RecordingController
    @EnvironmentObject var player: PlaybackController
    @EnvironmentObject var exporter: Exporter

    @State private var deleting: Recording?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("list.title"))
                    .font(.system(size: Theme.fsBody + 2, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button {
                    try? FileStore.ensureFolder()
                    NSWorkspace.shared.open(FileStore.folder)
                } label: {
                    Label(L("action.openFolder"), systemImage: "folder")
                        .font(.system(size: Theme.fsCaption))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.primaryText)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            if FileStore.customFolderUnavailable {
                Text(L("settings.folderUnavailable"))
                    .font(.system(size: Theme.fsSmall))
                    .foregroundStyle(Theme.warn)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }

            if let p = exporter.progress {
                // 轉檔進度＋取消
                HStack(spacing: 10) {
                    ProgressView(value: p).tint(Theme.p500)
                    Text(exporter.label).font(.system(size: Theme.fsSmall)).foregroundStyle(Theme.ink2).lineLimit(1).truncationMode(.middle)
                    Button(L("action.cancel")) { exporter.cancel() }.controlSize(.small)
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
            }

            Divider().overlay(Theme.lineSoft)

            if store.recordings.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform").font(.system(size: 28)).foregroundStyle(Theme.p300)
                    Text(L("list.empty")).font(.system(size: Theme.fsCaption)).foregroundStyle(Theme.ink3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.recordings) { r in
                            RecordingRow(recording: r,
                                         onDelete: { deleting = r },
                                         onPlayBlocked: { errorText = L("error.playWhileRecording") })
                            Divider().overlay(Theme.lineSoft).padding(.leading, 16)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
        .confirmationDialog(deleting.map { String(format: L("delete.title"), $0.name) } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button(L("action.moveToTrash"), role: .destructive) {
                if let r = deleting {
                    if player.isCurrent(r.url) { player.stop() }
                    errorText = store.delete(r)
                }
                deleting = nil
            }
            Button(L("action.cancel"), role: .cancel) { deleting = nil }
        } message: {
            Text(L("delete.message"))
        }
        .onChange(of: exporter.finishedCount) { _, _ in
            store.refresh(excluding: recorder.currentURL)
            exporter.resultMessage = nil   // 結果已顯示在右上提示區
        }
        .alert(L("error.title"), isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button(L("action.ok")) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }
}

struct RecordingRow: View {
    let recording: Recording
    let onDelete: () -> Void
    let onPlayBlocked: () -> Void
    @EnvironmentObject var player: PlaybackController
    @EnvironmentObject var recorder: RecordingController
    @EnvironmentObject var store: FileStore
    @State private var hover = false
    @State private var scrub: Double?
    // 行內改名
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    static let startRenameNotification = Notification.Name("AudioMemoStartRename")

    private var isCurrent: Bool { player.isCurrent(recording.url) }

    private func togglePlay() {
        // 錄音中不播放（避免播放的聲音被錄進去）
        if recorder.isActive { onPlayBlocked(); return }
        player.toggle(recording.url)
    }

    private func beginRename() {
        draft = recording.name
        editing = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitRename() {
        guard editing else { return }
        editing = false
        if isCurrent { player.stop() }
        store.renameInline(recording, to: draft)
    }

    private func cancelRename() {
        editing = false
        draft = recording.name
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: togglePlay) {
                Image(systemName: isCurrent && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.p500)
            }
            .buttonStyle(.plain)
            .help(isCurrent && player.isPlaying ? L("action.pausePlayback") : L("action.play"))
            .accessibilityLabel(isCurrent && player.isPlaying ? L("action.pausePlayback") : L("action.play"))

            // 左：檔名＋中繼資料／播放進度。空間不夠時這一欄先截斷（尾端省略號），右邊按鈕不動
            VStack(alignment: .leading, spacing: 3) {
                if editing {
                    // 行內改名：Enter 或點別處＝儲存；Esc＝取消
                    TextField(L("rename.placeholder"), text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: Theme.fsBody, weight: .semibold))
                        .focused($nameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand(perform: cancelRename)
                        .onChange(of: nameFocused) { _, f in if !f { commitRename() } }
                } else {
                    Text(recording.name)
                        .font(.system(size: Theme.fsBody, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1).truncationMode(.tail)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: beginRename)
                        .help(L("help.renameInline"))
                }
                if isCurrent {
                    // 播放進度：只在檔名下方、時間文字左邊；可拖曳或點一下跳轉
                    HStack(spacing: 8) {
                        // 每個畫面讀一次即時位置（TimelineView .animation），進度條平滑移動；
                        // 暫停時停在原位；拖曳中顯示拖曳值，放開才跳轉（不閃跳）
                        TimelineView(.animation(minimumInterval: nil, paused: !player.isPlaying || scrub != nil)) { _ in
                            let pos = scrub ?? player.livePosition
                            let _ = player.recordFrame(pos)
                            Slider(value: Binding(get: { pos }, set: { scrub = $0 }),
                                   in: 0...max(player.duration, 0.1)) { editing in
                                if !editing, let t = scrub { player.seek(to: t); scrub = nil }
                            }
                            .controlSize(.mini)
                            .tint(Theme.p500)
                            .accessibilityLabel(L("a11y.playbackPosition"))
                        }
                        .frame(minWidth: 60)
                        Text(String(format: L("player.position"), FileStore.positionText(scrub ?? player.currentTime), FileStore.durationText(player.duration)))
                            .environment(\.layoutDirection, .leftToRight)
                            .font(.system(size: Theme.fsSmall))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink2)
                            .fixedSize()
                    }
                } else {
                    Text(subtitle)
                        .font(.system(size: Theme.fsSmall))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 右：固定大小的按鈕區（播放與否、視窗寬窄都一樣）
            HStack(spacing: 6) {
                TranscribeButton(recording: recording)

                LabeledIcon(title: L("label.share")) {
                    ShareButton(url: recording.url).frame(width: 24, height: 22)
                }

                LabeledIcon(title: L("label.more")) {
                    Menu {
                        rowMenu
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 26, height: 22)
                    .help(L("action.more"))
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(isCurrent ? Theme.p100 : (hover ? Theme.p100.opacity(0.6) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2, perform: togglePlay)
        .contextMenu { rowMenu }
        .onReceive(NotificationCenter.default.publisher(for: Self.startRenameNotification)) { n in
            if (n.object as? URL) == recording.url { beginRename() }
        }
    }

    @ViewBuilder private var rowMenu: some View {
        Button(isCurrent && player.isPlaying ? L("action.pausePlayback") : L("action.play"), action: togglePlay)
        Button(L("action.transcribe")) { AppModel.shared.uploader.start(recording) }
            .disabled(AppModel.shared.uploader.isBusy)
        Button(L("action.revealInFinder")) { FileStore.revealInFinder(recording) }
        Menu(L("action.convert")) {
            ForEach(ExportFormat.allCases) { f in
                Button(f.title) { AppModel.shared.exporter.export(recording.url, to: f) }
            }
        }
        .disabled(AppModel.shared.exporter.isBusy)
        Divider()
        Button(L("action.delete"), role: .destructive) { onDelete() }
    }

    private var subtitle: String {
        [FileStore.dateFormatter.string(from: recording.created),
         FileStore.durationText(recording.duration),
         FileStore.sizeFormatter.string(fromByteCount: recording.size)].joined(separator: "  ·  ")
    }
}

struct SmallFilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Theme.fsCaption, weight: .medium))
            .foregroundStyle(Theme.onP500)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Theme.p500.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.rBtn, style: .continuous))
    }
}

// MARK: - 設定

struct SettingsView: View {
    @ObservedObject private var mics = AppModel.shared.mics
    @State private var selection: String = UserDefaults.standard.string(forKey: MicrophoneManager.selectionKey) ?? ""
    @AppStorage("autoLevel") private var autoLevel = true
    @AppStorage(EchoPolicy.key) private var echoPolicy = EchoPolicy.off.rawValue
    @ObservedObject private var store = AppModel.shared.store

    var body: some View {
        Form {
            Picker(L("settings.microphone"), selection: $selection) {
                Text(L("settings.followSystem")).tag("")
                Divider()
                ForEach(mics.devices) { d in
                    Text(d.isBluetooth ? String(format: L("settings.bluetoothTag"), d.name) : d.name).tag(d.uid)
                }
            }
            Text(L("settings.airpodsNote"))
                .font(.system(size: Theme.fsSmall))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            Picker(L("settings.echo"), selection: $echoPolicy) {
                Text(L("settings.echoAuto")).tag(EchoPolicy.auto.rawValue)
                Text(L("settings.echoOn")).tag(EchoPolicy.on.rawValue)
                Text(L("settings.echoOff")).tag(EchoPolicy.off.rawValue)
            }
            Text(L("settings.echoNote"))
                .font(.system(size: Theme.fsSmall))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(L("settings.autoLevel"), isOn: $autoLevel)
            Text(L("settings.autoLevelNote"))
                .font(.system(size: Theme.fsSmall))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent(L("settings.folder")) {
                HStack(spacing: 8) {
                    Button(DemoMode.folderDisplay ?? FileStore.displayPath(FileStore.folder)) {
                        try? FileStore.ensureFolder()
                        NSWorkspace.shared.open(FileStore.folder)
                    }
                    .buttonStyle(.link)
                    .lineLimit(1).truncationMode(.middle)
                    .help(L("settings.folderOpen"))
                    Button(L("settings.folderChooseShort")) { chooseFolder() }
                        .help(L("settings.folderChoose"))
                        .accessibilityLabel(L("settings.folderChoose"))
                }
            }
            if FileStore.customFolder != nil {
                HStack {
                    if FileStore.customFolderUnavailable {
                        Text(L("settings.folderUnavailable"))
                            .font(.system(size: Theme.fsSmall))
                            .foregroundStyle(Theme.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(L("settings.folderReset")) { store.setCustomFolder(nil) }
                }
            }
            Text(L("settings.folderNote"))
                .font(.system(size: Theme.fsSmall))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 540)
        .navigationTitle(L("settings.title"))
        .onAppear(perform: load)
        .onChange(of: selection) { _, uid in
            if let d = mics.devices.first(where: { $0.uid == uid }) {
                UserDefaults.standard.set(d.name, forKey: MicrophoneManager.selectionKey + "Name")
            }
            mics.select(uid)
        }
    }

    /// 系統選資料夾視窗（可建新資料夾）。
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileStore.folder
        panel.prompt = L("settings.folderChooseButton")
        panel.message = L("settings.folderChooseMessage")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if FileStore.isUsableFolder(url) {
            store.setCustomFolder(url)
        } else {
            let alert = NSAlert()
            alert.messageText = L("settings.folderNoAccess")
            alert.runModal()
        }
    }

    private func load() { mics.refresh(reason: "settings") }
}

/// 圖示按鈕＋下方很小的功能名稱（看不懂圖示的人也知道是什麼）。名稱太長就縮字，不撐開按鈕。
struct LabeledIcon<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: 1) {
            content()
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(Theme.ink3)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: 40)
        }
        .frame(width: 40)
    }
}

/// 「轉成逐字稿」：平常只有 Osmi 標誌（品牌淡藍 #81BDD6、無字、無底色），標誌本身就是按鈕。
/// 滑鼠移上去或鍵盤焦點時：標誌平滑放大、出現深藍底，說明文字從標誌旁往「前方」（LTR 在左、RTL 在右）滑出；
/// 展開的部分浮在上層、不參與排版，不擠壓同一列其他按鈕。系統「減少動態效果」時改淡入。
/// 行為：開 Osmi 網頁＋Finder 選取檔案。
struct TranscribeButton: View {
    let recording: Recording
    @EnvironmentObject var uploader: OsmiUploader
    @State private var hover = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let debugExpand = Notification.Name("AudioMemoDebugExpandTranscribe")
    static let markSize: CGFloat = 22
    /// 展開時的底色：AudioMemo 聲波青深 #299898（淺、深色模式同一色；白字對比 3.48:1）
    static let expandedFill = Color(red: 0x29 / 255, green: 0x98 / 255, blue: 0x98 / 255)

    private var url: URL { recording.url }
    private var mine: Bool { uploader.file?.standardizedFileURL == url.standardizedFileURL }
    /// 這一列正在上傳／失敗：按鈕一直展開，顯示進度或「重試」
    private var active: Bool { mine && uploader.phase != .idle }
    private var expanded: Bool { hover || focused || active }

    private var label: String {
        guard mine else { return L("transcribe.explain") }
        switch uploader.phase {
        case .preparing: return L("upload.preparingShort")
        case .uploading(let p): return p >= 0.999 ? L("upload.finishingShort") : String(format: L("upload.progressShort"), Int(p * 100))
        case .opening: return L("upload.openingShort")
        case .failed: return L("action.retry")
        case .idle: return L("transcribe.explain")
        }
    }

    /// 按一下：沒在傳→開始上傳；正在傳→取消；失敗→重試
    private func action() {
        if mine, case .failed = uploader.phase { uploader.retry(); return }
        if mine, uploader.isBusy { uploader.cancel(); return }
        uploader.start(recording)
    }

    var body: some View {
        Button(action: action) {
            // 展開時說明文字在標誌前方（LTR 左、RTL 右），按鈕往前方長出來，把同一列左側的資訊擠窄（不重疊）
            HStack(spacing: 6) {
                if expanded {
                    Text(label)
                        .monospacedDigit()
                        .font(.system(size: Theme.fsSmall, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.leading, 12)
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
                Image("OsmiMark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    // 收起：Osmi 品牌淡藍；展開：跟說明字一樣淡入成白色（跟展開動畫同一個 transaction）
                    .foregroundStyle(expanded ? Color.white : Theme.osmiBlue)
                    .frame(width: Self.markSize, height: Self.markSize)
                    .scaleEffect(expanded && !reduceMotion ? 1.15 : 1)
                    .frame(width: 34, height: 34)
            }
            .background(Capsule().fill(Self.expandedFill).opacity(expanded ? 1 : 0))
            .contentShape(Capsule())
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { h in withAnimation(anim) { hover = h } }
        .animation(anim, value: focused)
        .disabled(uploader.isBusy && !mine)
        .help(mine && uploader.isBusy ? L("upload.cancelHelp") : L("transcribe.explain"))
        .accessibilityLabel(L("action.transcribe"))
        .accessibilityHint(L("transcribe.explain"))
        .onReceive(NotificationCenter.default.publisher(for: Self.debugExpand)) { n in
            if (n.object as? URL) == url { withAnimation(anim) { hover = (n.userInfo?["on"] as? Bool) ?? true } }
        }
    }

    private var anim: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 0.85) }
}
