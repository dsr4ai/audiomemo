import AppKit
import SwiftUI

/// 介面字串一律從字典檔（Localizable.xcstrings）取。
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}

/// 介面方向：介面語言是由右往左（ar、he）或系統強制 RTL（偽語系）時整個鏡像。
let appLayoutDirection: LayoutDirection = {
    let lang = Bundle.main.preferredLocalizations.first ?? "en"
    let rtl = Locale.Language(identifier: lang).characterDirection == .rightToLeft
        || NSApplication.shared.userInterfaceLayoutDirection == .rightToLeft
    return rtl ? .rightToLeft : .leftToRight
}()

@main
struct AudioMemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var recorder = AppModel.shared.recorder
    @ObservedObject private var store = AppModel.shared.store

    var body: some Scene {
        Window("AudioMemo", id: "main") {
            MainView()
                .environment(\.layoutDirection, appLayoutDirection)
                .environmentObject(recorder)
                .environmentObject(store)
                .environmentObject(AppModel.shared.player)
                .environmentObject(AppModel.shared.exporter)
                .environmentObject(AppModel.shared.notices)
                .environmentObject(AppModel.shared.uploader)
                .environmentObject(AppModel.shared.mics)
        }
        .defaultSize(width: 620, height: 720)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(\.layoutDirection, appLayoutDirection)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(\.layoutDirection, appLayoutDirection)
                .environmentObject(recorder)
        } label: {
            MenuBarLabel(recorder: recorder)
        }
    }
}

@MainActor
final class AppModel {
    static let shared = AppModel()
    let recorder = RecordingController()
    let store = FileStore()
    let player = PlaybackController()
    let exporter = Exporter()
    let notices = NoticeCenter()
    let uploader = OsmiUploader()
    lazy var mics: MicrophoneManager = {
        let m = MicrophoneManager()
        m.onChange = { [unowned self] dev, notice in self.recorder.microphoneChanged(to: dev, notice: notice) }
        return m
    }()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if PreviewRenderer.runIfRequested() { return }
            if VPIOSelfTest.runIfRequested() { return }
            if UserDefaults.standard.string(forKey: "holdMic") != nil { HoldMicSelfTest.runIfRequested(); return }
            AppModel.shared.store.refresh()
            _ = AppModel.shared.mics
            AppModel.shared.recorder.runAutotestIfRequested()
            SnapshotRunner.runIfRequested()
            ExportSelfTest.runIfRequested()
            UploadSelfTest.runIfRequested()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        // 結束 App 前把正在錄的檔案收尾，避免檔案壞掉
        MainActor.assumeIsolated { AppModel.shared.recorder.stopNow() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.store.refresh(excluding: AppModel.shared.recorder.currentURL)
        }
    }
}

// MARK: - 選單列

struct MenuBarLabel: View {
    @ObservedObject var recorder: RecordingController
    var body: some View {
        if recorder.phase == .recording || recorder.phase == .paused {
            HStack(spacing: 4) {
                Image(nsImage: Theme.menuBarImage(recording: recorder.phase == .recording))
                Text(RecordingController.format(recorder.elapsed)).monospacedDigit()
            }
        } else {
            Image(nsImage: Theme.menuBarImage(recording: false))
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var recorder: RecordingController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch recorder.phase {
        case .idle:
            Button(L("action.startRecording")) { recorder.start() }
        case .starting, .recording, .paused, .saving:
            Text(statusLine)
            Button(recorder.phase == .paused ? L("action.resume") : L("action.pause")) { recorder.pauseResume() }
                .disabled(recorder.phase == .starting || recorder.phase == .saving)
            Button(L("action.stopRecording")) { recorder.stop() }
                .disabled(recorder.phase == .saving)
        }
        if let err = recorder.errorMessage {
            Text(err)
        }
        Divider()
        Button(L("action.openWindow")) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(L("action.openFolder")) {
            try? FileStore.ensureFolder()
            NSWorkspace.shared.open(FileStore.folder)
        }
        Divider()
        Button(L("action.quit")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        let s = RecorderStatus(phase: recorder.phase, hasError: false).title
        return "\(s)  \(RecordingController.format(recorder.elapsed))"
    }
}
