import AVFoundation
import AppKit
import Combine
import Foundation

/// 錄音狀態（給 UI 與選單列共用）。
@MainActor
final class RecordingController: ObservableObject {
    /// starting＝裝置啟動中（音訊還沒進來），計時不走、不顯示錄音紅；saving＝停止後收尾寫檔。
    enum Phase: Equatable { case idle, starting, recording, paused, saving }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var sysLevel: Float = 0
    @Published private(set) var micMuted = false
    @Published private(set) var sysMuted = false
    @Published var errorMessage: String? {
        didSet { if let e = errorMessage, e != oldValue { AppModel.shared.notices.post(.message(e)) } }
    }
    /// 錄音中寫入的暫存檔（隱藏檔，列表看不到）。
    @Published private(set) var currentURL: URL?
    /// 每次停止錄音後遞增，讓檔案列表重新整理。
    @Published private(set) var finishedCount = 0
    /// 最近一次存好的檔案。
    private(set) var lastSavedURL: URL?

    private let engine = CaptureEngine()
    private let silence = SilenceKeeper()
    private var timer: Timer?
    private var startDate = Date()
    private var startingSince = Date()
    private var retried = false
    /// engine.start() 已經回來（成功）；在那之前不能 stop／判定逾時。
    private var engineStarted = false
    private var stopRequested = false

    /// 錄音中麥克風換了（MicrophoneManager 通知）：不斷錄，背景重建裝置，中間寫靜音。
    func microphoneChanged(to device: InputDevice, notice: Notice?) {
        guard phase != .idle, phase != .saving, engineStarted else { return }
        let engine = self.engine
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try engine.switchMicrophone(to: device.uid)
                DispatchQueue.main.async { if let notice { AppModel.shared.notices.post(notice) } else { AppModel.shared.notices.post(.switchedDevice(device: device.name)) } }
            } catch {
                DebugLog.write("switch mic failed: \(error.localizedDescription)")
                DispatchQueue.main.async { AppModel.shared.notices.post(.message(String(format: L("error.switchFailed"), device.name))) }
            }
        }
    }

    /// 短於這個長度就不存檔（快速按開始又停止）。
    static let minimumSeconds: TimeInterval = 1.0
    /// 啟動後這麼久還沒有音訊進來 → 視為卡住，自動重試一次。
    static let startTimeout: TimeInterval = 8

    var isActive: Bool { phase != .idle }

    func toggle() { isActive ? stop() : start() }

    func start() {
        guard phase == .idle else { return }
        errorMessage = nil
        retried = false
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginCapture()
        case .notDetermined:
            phase = .starting
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    self.phase = .idle
                    if granted { self.beginCapture() } else { self.errorMessage = L("error.micDenied") }
                }
            }
        default:
            errorMessage = L("error.micDenied")
        }
    }

    private func beginCapture() {
        guard phase == .idle || phase == .starting else { return }
        AppModel.shared.player.stop()   // 錄音前先停掉 App 內播放（不然播放的聲音會被錄進去）
        let tempURL: URL
        do { tempURL = try FileStore.newTempURL() } catch {
            errorMessage = String(format: L("error.startFailed"), error.localizedDescription)
            phase = .idle
            return
        }
        let mics = AppModel.shared.mics
        mics.refresh(reason: "start")
        let uid = mics.active?.uid
        phase = .starting
        micMuted = false; sysMuted = false          // 每次新錄音都回到兩軌全開
        engine.setMuted(mic: false, system: false)
        engineStarted = false
        stopRequested = false
        startingSince = Date()
        startDate = Date()
        currentURL = tempURL
        elapsed = 0
        startTimer()
        // 在背景執行：第一次跳「系統錄音」權限視窗時，啟動會卡到使用者按下為止，不能卡住畫面
        if !UserDefaults.standard.bool(forKey: "noSilenceKeeper") { silence.start() }
        let engine = self.engine
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try engine.start(micUID: uid, outputURL: tempURL) }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    DebugLog.write("start \(tempURL.lastPathComponent)")
                    self.engineStarted = true
                    self.updateEchoCancellation(force: true)
                    self.startingSince = Date()
                    if self.stopRequested { self.stopNow() }
                case .failure(let error):
                    DebugLog.write("start failed: \(error.localizedDescription)")
                    self.finishFailedStart(tempURL)
                    self.errorMessage = String(format: L("error.startFailed"), error.localizedDescription)
                }
            }
        }
    }

    private func finishFailedStart(_ url: URL) {
        timer?.invalidate(); timer = nil
        silence.stop()
        try? FileManager.default.removeItem(at: url)
        phase = .idle
        currentURL = nil
    }

    /// 只給自我截圖用：讓畫面顯示某個狀態（例如一閃即過的「儲存中」）。
    func debugShowPhase(_ p: Phase) { phase = p }

    func toggleMicMute() { micMuted.toggle(); engine.setMuted(mic: micMuted, system: sysMuted) }
    func toggleSysMute() { sysMuted.toggle(); engine.setMuted(mic: micMuted, system: sysMuted) }

    func pauseResume() {
        switch phase {
        case .recording: engine.setPaused(true); phase = .paused
        case .paused: engine.setPaused(false); phase = .recording
        case .idle, .starting, .saving: break
        }
    }

    /// 停止：先切到「儲存中」，在背景把檔案收尾（寫出 moov）再改名。
    func stop() {
        guard phase != .idle, phase != .saving, currentURL != nil else { return }
        guard engineStarted else { stopRequested = true; return }   // 還在啟動（可能卡在權限視窗），啟動完成後再停
        phase = .saving
        timer?.invalidate(); timer = nil
        micLevel = 0; sysLevel = 0
        let engine = self.engine
        DispatchQueue.global(qos: .userInitiated).async {
            let frames = engine.stop()
            DispatchQueue.main.async { self.finalize(frames: frames) }
        }
    }

    /// 同步停止（結束 App、自動測試用）。
    func stopNow() {
        guard phase != .idle, phase != .saving, currentURL != nil, engineStarted else { return }
        timer?.invalidate(); timer = nil
        finalize(frames: engine.stop())
    }

    private func finalize(frames: Int64) {
        guard let temp = currentURL else { return }
        silence.stop()
        let seconds = Double(frames) / engine.fileRate
        echoActive = false
        DebugLog.write("stop \(temp.lastPathComponent) seconds=\(seconds)")
        phase = .idle
        currentURL = nil
        micLevel = 0; sysLevel = 0
        elapsed = 0
        if seconds < Self.minimumSeconds {
            // 太短（或還沒開始收音就停了）：不存檔，避免留下 0 秒或壞檔
            try? FileManager.default.removeItem(at: temp)
            AppModel.shared.notices.post(.tooShort)
        } else {
            do {
                var dest = try FileStore.newRecordingURL(date: startDate)
                if UserDefaults.standard.bool(forKey: "rawCapture") { dest = dest.deletingPathExtension().appendingPathExtension("caf") }
                try FileManager.default.moveItem(at: temp, to: dest)
                lastSavedURL = dest
                DebugLog.write("saved \(dest.lastPathComponent)")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        finishedCount += 1
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 回音消除：依設定與目前輸出裝置決定開關；錄音中輸出換了就跟著切（不斷錄）。約每秒檢查一次。
    @Published private(set) var echoActive = false
    private var echoBusy = false
    private var lastEchoCheck = Date.distantPast

    private func updateEchoCancellation(force: Bool = false) {
        guard engineStarted, phase != .idle, phase != .saving, !echoBusy else { return }
        guard force || Date().timeIntervalSince(lastEchoCheck) > 1 else { return }
        lastEchoCheck = Date()
        let out = EchoPolicy.currentOutput()
        let want = EchoPolicy.shouldEnable(output: out)
        guard want != engine.echoCancellationOn else { return }
        echoBusy = true
        let engine = self.engine
        let wasOn = echoActive
        let useVPIO = UserDefaults.standard.bool(forKey: "useVPIO")   // 隱藏除錯選項：改用 Apple VPIO（會壓低其他 App）
        DispatchQueue.global(qos: .userInitiated).async {
            if useVPIO { engine.setEchoCancellation(want) } else { engine.setAEC(want) }
            let now = engine.echoCancellationOn
            DispatchQueue.main.async {
                self.echoBusy = false
                self.echoActive = now
                DebugLog.write("echo policy=\(EchoPolicy.current.rawValue) output=\(out.name) transport=\(String(format: "%08x", out.transport)) loudspeaker=\(EchoPolicy.isLoudspeaker(out)) -> \(now)")
                if !force && now != wasOn {
                    AppModel.shared.notices.post(.message(now ? L("notice.echoOn") : L("notice.echoOff")))
                }
            }
        }
    }

    private func tick() {
        updateEchoCancellation()
        if phase == .starting {
            if engine.hasAudio {
                phase = .recording
                DebugLog.write("audio flowing after \(Date().timeIntervalSince(startingSince))s")
            } else if engineStarted, Date().timeIntervalSince(startingSince) > Self.startTimeout {
                // 少數情況聚合裝置建好了卻一直沒有音訊進來：收掉重來一次
                DebugLog.write("no audio after \(Self.startTimeout)s, retried=\(retried)")
                let temp = currentURL
                engine.stop()
                if let temp { finishFailedStart(temp) }
                if !retried {
                    retried = true
                    beginCapture()
                } else {
                    errorMessage = L("error.noAudio")
                }
                return
            }
        }
        elapsed = engine.elapsed + DemoMode.elapsedOffset
        // 顯示的是實際寫進檔案的 RMS（自動平衡、靜音之後），dBFS 對數刻度 -60～0
        let l = engine.takeLevels()
        if let d = DemoMode.levels(at: elapsed) {           // 示範截圖：只改畫面上的電平，不影響錄進檔案的聲音
            micLevel = Self.smooth(micLevel, d.mic); sysLevel = Self.smooth(sysLevel, d.sys); return
        }
        micLevel = Self.smooth(micLevel, Self.meter(l.mic))
        sysLevel = Self.smooth(sysLevel, Self.meter(l.sys))
    }

    /// 上升快（約 50 ms）、下降慢（約 300 ms），條不會亂跳。
    private static func smooth(_ old: Float, _ new: Float) -> Float {
        new > old ? old + (new - old) * 0.6 : old + (new - old) * 0.15
    }

    /// RMS → 0…1：-60 dBFS 以下＝空、0 dBFS＝滿。講話（約 -17 dBFS）約在 70%，安靜底噪在 20% 以下。
    static func meter(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return max(0, min(1, (db + 60) / 60))
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    // MARK: - 自動測試

    /// 測試用：`open AudioMemo.app --args -autotestSeconds 10`，等到真的開始收音後錄 N 秒，停止並結束 App；
    /// 存好的檔案路徑寫到 ~/Library/Logs/AudioMemo/autotest.txt。
    /// `-autotestMicSound <檔案>`：開始收音 1 秒後由 App 自己播放這個檔案——App 自己的聲音不進系統聲道，
    /// 只會經由喇叭→麥克風被錄到，用來單獨驗證麥克風那一軌。
    func runAutotestIfRequested() {
        let seconds = UserDefaults.standard.double(forKey: "autotestSeconds")
        guard seconds > 0 else { return }
        let resultURL = DebugLog.url.deletingLastPathComponent().appendingPathComponent(
            UserDefaults.standard.string(forKey: "debugLogFile") == nil ? "autotest.txt" : "autotest-result.txt")
        try? FileManager.default.removeItem(at: resultURL)
        DebugLog.write("autotest: mic auth=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3=authorized 2=denied 0=notDetermined)")
        let micSound = UserDefaults.standard.string(forKey: "autotestMicSound")
        var player: AVAudioPlayer?
        start()
        var waited = 0.0
        func finish() {
            let saved = lastSavedURL
            stopNow()
            let path = (lastSavedURL != saved ? lastSavedURL?.path : nil) ?? "ERROR: \(errorMessage ?? "too short or not recording")"
            DebugLog.write("autotest: done \(path)")
            try? (path + "\n").write(to: resultURL, atomically: true, encoding: .utf8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        }
        func waitThenRecord() {
            if phase == .recording {
                DebugLog.write("autotest: recording started after \(waited)s")
                if let micSound {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: micSound))
                        player?.play()
                        DebugLog.write("autotest: app-played mic sound \(player != nil)")
                    }
                }
                // -autotestMute "mic:16-21,sys:21-26"：錄音開始後第幾秒到第幾秒把哪一軌靜音
                for item in (UserDefaults.standard.string(forKey: "autotestMute") ?? "").split(separator: ",") {
                    let parts = item.split(separator: ":"); guard parts.count == 2 else { continue }
                    let range = parts[1].split(separator: "-").compactMap { Double($0) }; guard range.count == 2 else { continue }
                    let isMic = parts[0] == "mic"
                    DispatchQueue.main.asyncAfter(deadline: .now() + range[0]) { isMic ? self.toggleMicMute() : self.toggleSysMute() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + range[1]) { isMic ? self.toggleMicMute() : self.toggleSysMute() }
                }
                // 每 0.5 秒記一次畫面上的音量條數值（0…1），讓測試腳本核對刻度
                let t0 = Date()
                let meterTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                    Task { @MainActor in
                        DebugLog.write(String(format: "meter t=%.1f mic=%.2f sys=%.2f micMuted=%d sysMuted=%d",
                                              Date().timeIntervalSince(t0), self.micLevel, self.sysLevel,
                                              self.micMuted ? 1 : 0, self.sysMuted ? 1 : 0))
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { _ = player; meterTimer.invalidate(); finish() }
            } else if waited > 120 || (phase == .idle && errorMessage != nil) {
                finish()
            } else {
                waited += 0.25
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { waitThenRecord() }
            }
        }
        waitThenRecord()
    }
}
