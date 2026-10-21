import AppKit
import CoreAudio
import AVFoundation

/// 測試用：`open AudioMemo.app --args -storageFolder <測試資料夾> -exportTest <測試資料夾裡的 m4a>`
/// 依序轉成每一種格式，寫進 debug.log 後結束。⛔ 來源檔必須在 -storageFolder 裡。
@MainActor
enum ExportSelfTest {
    static func runIfRequested() {
        guard let src = UserDefaults.standard.string(forKey: "exportTest"),
              let test = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["storageFolder"] as? String,
              src.hasPrefix((test as NSString).expandingTildeInPath) else { return }
        Task {
            let ex = AppModel.shared.exporter
            for f in ExportFormat.allCases {
                ex.export(URL(fileURLWithPath: src), to: f)
                while ex.isBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
                DebugLog.write("exportTest \(f.ext): \(ex.resultMessage ?? "ok")")
            }
            NSApp.terminate(nil)
        }
    }
}

/// 測試用：模擬「其他 App 正在用某支麥克風」。`-holdMic <裝置 UID> -holdSeconds 6`：
/// 直接在那支裝置上開 IOProc（不建聚合裝置、不寫檔）N 秒後結束。用另一個 AudioMemo 程序跑（不同 pid＝別的 App）。
@MainActor
enum HoldMicSelfTest {
    static func runIfRequested() {
        guard let uid = UserDefaults.standard.string(forKey: "holdMic"), let dev = AudioHAL.device(forUID: uid) else { return }
        let secs = max(1, UserDefaults.standard.double(forKey: "holdSeconds"))
        var proc: AudioDeviceIOProcID?
        var callbacks = 0
        let st = AudioDeviceCreateIOProcIDWithBlock(&proc, dev, nil) { _, _, _, _, _ in callbacks += 1 }
        let st2 = proc.map { AudioDeviceStart(dev, $0) } ?? -1
        DebugLog.write("holdMic \(uid) create=\(st) start=\(st2)")
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
            if let proc { AudioDeviceStop(dev, proc); AudioDeviceDestroyIOProcID(dev, proc) }
            DebugLog.write("holdMic done callbacks=\(callbacks)")
            NSApp.terminate(nil)
        }
    }
}

/// 測試用：`-vpioTest YES`：試幾種 VPIO 啟動方式，結果寫 debug.log 後結束（不錄檔）。
@MainActor
enum VPIOSelfTest {
    static func runIfRequested() -> Bool {
        guard UserDefaults.standard.bool(forKey: "vpioTest") else { return false }
        func attempt(_ name: String, setDevice: Int, tap: Bool) {
            let e = AVAudioEngine()
            let input = e.inputNode
            func setDev() {
                guard let au = input.audioUnit else { return }
                var dev = AudioHAL.defaultDevice(input: true)
                let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, 4)
                DebugLog.write("vpioTest \(name): setDevice st=\(st)")
            }
            do {
                if setDevice == 1 { setDev() }
                do { try input.setVoiceProcessingEnabled(true) } catch { DebugLog.write("vpioTest \(name): setVP failed \(error)"); throw error }
                if setDevice == 2 { setDev() }
                let fmt = input.outputFormat(forBus: 0)
                _ = e.mainMixerNode
                var frames = 0
                if tap { input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { b, _ in frames += Int(b.frameLength) } }
                e.prepare()
                do { try e.start() } catch { DebugLog.write("vpioTest \(name): start failed \(error)"); throw error }
                RunLoop.main.run(until: Date().addingTimeInterval(1.5))
                DebugLog.write("vpioTest \(name): OK fmt=\(fmt) frames=\(frames) mode=\(VoiceProcessingMic.activeMicrophoneModeName)")
                e.stop()
            } catch {
                DebugLog.write("vpioTest \(name): FAIL \(error.localizedDescription)")
            }
            try? input.setVoiceProcessingEnabled(false)
        }
        attempt("A-noDevice-tap", setDevice: 0, tap: true)
        attempt("B-deviceBefore-tap", setDevice: 1, tap: true)
        attempt("C-deviceAfter-tap", setDevice: 2, tap: true)
        attempt("D-noDevice-noTap", setDevice: 0, tap: false)
        // E：直接用 AUVoiceIO
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_VoiceProcessingIO,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        if let comp = AudioComponentFindNext(nil, &desc) {
            var au: AudioUnit?
            var st = AudioComponentInstanceNew(comp, &au)
            DebugLog.write("vpioTest E new=\(st)")
            if let au {
                var one: UInt32 = 1
                st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4)
                DebugLog.write("vpioTest E enableIO=\(st)")
                st = AudioUnitInitialize(au)
                DebugLog.write("vpioTest E init=\(st)")
                st = AudioOutputUnitStart(au)
                DebugLog.write("vpioTest E start=\(st)")
                AudioOutputUnitStop(au); AudioUnitUninitialize(au); AudioComponentInstanceDispose(au)
            }
        }
        NSApp.terminate(nil)
        return true
    }
}

/// 測試用：`-uploadTest <檔案> -osmiBaseURL <網址> -osmiNoOpen YES`：走一次「讓Osmi聽寫逐字稿」上傳流程，結果寫進 debug.log 後結束。
@MainActor
enum UploadSelfTest {
    static func runIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "uploadTest") else { return }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let rec = Recording(url: url, created: Date(), size: size, duration: 12.3)
        let up = AppModel.shared.uploader
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "uploadTestSession") {
        case "fake": OsmiAuth.debugStoreFakeSession()
        case "none": up.auth.signOut()
        default: break
        }
        #endif
        up.start(rec)
        Task {
            var last = ""
            while true {
                try? await Task.sleep(nanoseconds: 50_000_000)
                let s = "\(up.phase)"
                if s != last { DebugLog.write("uploadTest phase: \(s)"); last = s }
                if case .failed = up.phase { break }
                if up.phase == .idle { break }
            }
            DebugLog.write("uploadTest end: showLogin=\(up.showLogin) hasSession=\(up.auth.hasSession)")
            NSApp.terminate(nil)
        }
    }
}
