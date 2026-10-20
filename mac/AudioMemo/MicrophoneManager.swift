import CoreAudio
import Foundation

/// 決定要用哪支麥克風，並在錄音中跟著換（不斷錄）。
/// - 預設「跟隨系統」：用 macOS 目前的預設輸入；若有其他 App（例如 Zoom）正在用另一支麥克風，就跟上那一支
///   （多支同時被用時以最近開始用的為準）。
/// - 使用者在設定手動選了某支：就固定用那支，不自動切；那支不見了才暫時改用系統預設。
@MainActor
final class MicrophoneManager: ObservableObject {
    static let selectionKey = "micSelection"      // "" ＝跟隨系統；其他＝裝置 UID

    @Published private(set) var active: InputDevice?
    @Published private(set) var devices: [InputDevice] = []

    /// 錄音中要換裝置時呼叫（由 RecordingController 設定）。
    var onChange: ((InputDevice, Notice?) -> Void)?

    private var firstSeen: [AudioObjectID: Date] = [:]
    private var poll: Timer?
    private var dismissedBluetooth: Set<String> = []
    /// 防抖：自動判斷出的新裝置要連續 2 次輪詢（約 2 秒）都一樣才換，避免「使用中」忽開忽關時來回切。
    private var pending: (uid: String, count: Int)?

    var selection: String { UserDefaults.standard.string(forKey: Self.selectionKey) ?? "" }
    var followsSystem: Bool { selection.isEmpty }

    init() {
        installListeners()
        refresh(reason: "init")
        poll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(reason: "poll") }
        }
    }

    func select(_ uid: String) {
        UserDefaults.standard.set(uid, forKey: Self.selectionKey)
        refresh(reason: "user")
    }

    func dismissBluetoothWarning() {
        if let a = active { dismissedBluetooth.insert(a.uid) }
        AppModel.shared.notices.dismiss()
    }

    private func installListeners() {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        for sel in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var addr = AudioHAL.address(sel)
            AudioObjectAddPropertyListenerBlock(sys, &addr, DispatchQueue.main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh(reason: sel == kAudioHardwarePropertyDevices ? "devices" : "default") }
            }
        }
    }

    /// 重新判斷該用哪支麥克風；變了就通知（錄音中由 RecordingController 換裝置）。
    func refresh(reason: String) {
        let all = AudioHAL.inputDevices()
        devices = all
        var notice: Notice?
        var chosen: InputDevice?

        if !followsSystem {
            if let d = all.first(where: { $0.uid == selection }) {
                chosen = d
            } else {
                chosen = AudioHAL.systemDefaultInput() ?? all.first
                let lostName = UserDefaults.standard.string(forKey: Self.selectionKey + "Name") ?? selection
                if active?.uid == selection || active == nil { notice = .deviceLost(device: lostName) }
            }
        } else {
            // 其他 App 正在用的輸入裝置（排除本 App）；以最近開始使用的為準
            let usages = AudioHAL.inputsInUseByOtherApps().filter { u in all.contains { $0.id == u.deviceID } }
            let now = Date()
            for u in usages where firstSeen[u.deviceID] == nil { firstSeen[u.deviceID] = now }
            firstSeen = firstSeen.filter { k, _ in usages.contains { $0.deviceID == k } }
            if let latest = usages.max(by: { (firstSeen[$0.deviceID] ?? now) < (firstSeen[$1.deviceID] ?? now) }),
               let dev = all.first(where: { $0.id == latest.deviceID }) {
                chosen = dev
                if dev.uid != active?.uid {
                    notice = AudioHAL.appName(pid: latest.pid, bundleID: latest.bundleID).map { .followedApp(app: $0, device: dev.name) }
                        ?? .followedInUse(device: dev.name)
                }
            } else {
                chosen = AudioHAL.systemDefaultInput() ?? all.first
                if let c = chosen, active != nil, c.uid != active?.uid { notice = .switchedDevice(device: c.name) }
            }
        }

        guard let chosen else { active = nil; return }
        if chosen.uid != active?.uid {
            let activeStillExists = active.map { a in all.contains { $0.uid == a.uid } } ?? false
            let immediate = reason != "poll" || active == nil || !activeStillExists
            if !immediate {
                if pending?.uid == chosen.uid { pending!.count += 1 } else { pending = (chosen.uid, 1) }
                guard pending!.count >= 2 else { return }
            }
            pending = nil
            DebugLog.write("mic -> \(chosen.name) [\(chosen.uid)] reason=\(reason) follow=\(followsSystem)")
            active = chosen
            onChange?(chosen, notice)
            // 藍牙麥克風提醒（使用者可略過）
            if chosen.isBluetooth, !dismissedBluetooth.contains(chosen.uid) {
                AppModel.shared.notices.post(.bluetoothWarning(device: chosen.name))
            } else if !chosen.isBluetooth {
                AppModel.shared.notices.clearSticky()
            }
        } else {
            pending = nil
        }
    }
}
