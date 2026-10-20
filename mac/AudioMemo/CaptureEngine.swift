import AudioToolbox
import CoreAudio
import Foundation
import os

/// 錄音核心：Core Audio process tap（系統混音）＋麥克風，放進同一個私有聚合裝置，
/// 一個 IOProc 同時拿到兩邊（同一時鐘，tap 由 HAL 做漂移補償），寫成雙聲道 AAC。
///
/// 為什麼用 process tap 而不是 ScreenCaptureKit：
/// - 只需要「系統錄音」權限，不需要「螢幕錄影」權限（macOS 15 起 SCStream 會定期跳出重新授權提示）。
/// - 抓的是各 App 的混音（不是錄喇叭），跟輸出裝置是 AirPods／有線／藍牙喇叭／內建喇叭無關。
/// - 麥克風跟系統聲音在同一個聚合裝置裡，天然同步，不必自己對時與重取樣。
///
/// 聲道配置（混音）：左＝系統左＋麥克風、右＝系統右＋麥克風。
/// 使用者直接播放時兩耳都聽得到自己與對方；系統聲音保留原本的立體聲。
/// 自動音量平衡（預設開，設定可關）：兩軌各自把有聲段落拉到約 -17 dBFS RMS，靜音／底噪不放大；
/// 最後過立體聲限幅器，峰值不超過 -1 dBFS。
/// （除錯用 `-splitChannels YES`：左＝麥克風、右＝系統，用來量兩軌各自的音量。）
final class CaptureEngine: @unchecked Sendable {
    struct Failure: LocalizedError {
        let step: String
        let status: OSStatus
        var errorDescription: String? { "\(step) (OSStatus \(status))" }
    }

    struct NoMicrophone: LocalizedError {
        var errorDescription: String? { L("error.noMic") }
    }

    // MARK: - 跨執行緒共享的狀態（IOProc 在即時執行緒上讀寫）
    private struct Shared {
        var paused = false
        var writing = false
        var framesWritten: Int64 = 0
        var micSumSq: Float = 0      // 自上次 takeLevels 起，實際寫入（增益＋靜音後）的平方和
        var sysSumSq: Float = 0
        var levelFrames = 0
        var micMuted = false
        var sysMuted = false
        var useVPMic = false            // 麥克風改用 Apple VPIO 那一路（隱藏除錯選項 -useVPIO YES）
        var aecOn = false               // 自己做的回音消除
        var aecNanos: UInt64 = 0        // 回音消除累計 CPU 時間
        var aecFrames: Int64 = 0
        var gapStart: UInt64 = 0        // 換裝置時舊裝置停下的時間；新裝置第一次回呼時補寫這段靜音
        var callbacks = 0
        var micGain: Float = 1
    }
    private let shared = OSAllocatedUnfairLock(initialState: Shared())

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var file: ExtAudioFileRef?
    private var scratch: UnsafeMutablePointer<Float>?
    private let scratchFrames = 16384
    private(set) var sampleRate: Double = 48000   // 目前聚合裝置的取樣率（換麥克風可能改變）
    private(set) var fileRate: Double = 48000     // 寫檔的取樣率（錄音開始時決定，整個檔案不變）
    private var resamplePos: Double = 0
    private var resamplePrev: (Float, Float) = (0, 0)
    private var resampled = UnsafeMutablePointer<Float>.allocate(capacity: 16384 * 2 * 4)
    private var zeros = UnsafeMutablePointer<Float>.allocate(capacity: 4096 * 2)
    private(set) var currentMicUID: String?
    private var vpMic: VoiceProcessingMic?
    private(set) var echoCancellationOn = false
    private var micBufferCount = 0
    private var startedAt: UInt64 = 0

    // 只在即時執行緒上用（不需要鎖）
    private let splitChannels = UserDefaults.standard.bool(forKey: "splitChannels")
    /// 除錯：-compareEcho YES → 左＝原始麥克風、右＝回音消除後的麥克風（都不經自動平衡），同一段聲音直接比較
    private let compareEcho = UserDefaults.standard.bool(forKey: "compareEcho")
    private var rawMic = [Float](repeating: 0, count: 16384)
    private var autoLevel = true
    /// 麥克風：講話時拉到約 -15 dBFS（講話有停頓，整段平均才會跟系統聲相近）；原始低於 -50 dBFS 視為只有底噪。關閉自動平衡時固定 +12 dB（內建麥克風原始約 -30 dBFS）。
    private var micLeveler = am_leveler()
    /// 系統聲音：有聲時拉到 -17 dBFS；低於 -55 dBFS 不放大。關閉時固定 1。
    private var sysLeveler = am_leveler()
    private var limiter = am_limiter()
    // 自己做的回音消除（core/am_aec.c）。系統聲與（關閉時的）麥克風都走同樣長度的延遲線，開關時兩軌不會錯位。
    private var aec: OpaquePointer?
    private var aecLatency = 1024
    private var sysDelayL = [Float](repeating: 0, count: 1024), sysDelayR = [Float](repeating: 0, count: 1024), micDelay = [Float](repeating: 0, count: 1024)
    private var delayPos = 0
    private var refMono = [Float](repeating: 0, count: 16384), aecOut = [Float](repeating: 0, count: 16384)
    /// 除錯：-rawCapture YES → CAF float32，左＝原始麥克風、右＝系統聲參考（給離線回音消除測試用）
    private let rawCapture = UserDefaults.standard.bool(forKey: "rawCapture")
    private var micMuteGain: Float = 1      // 靜音切換時在一個區塊內淡入淡出，避免喀聲
    private var sysMuteGain: Float = 1
    private var micBlock = [Float](repeating: 0, count: 16384)
    private var sysLBlock = [Float](repeating: 0, count: 16384)
    private var sysRBlock = [Float](repeating: 0, count: 16384)

    var isRunning: Bool { procID != nil }
    /// 音訊真的開始流進來了（第一次回呼之後）。聚合裝置啟動約需 2–3 秒。
    var hasAudio: Bool { shared.withLock { $0.callbacks > 0 } }
    var framesWritten: Int64 { shared.withLock { $0.framesWritten } }

    var elapsed: TimeInterval { Double(framesWritten) / fileRate }

    /// 取出自上次讀取以來的峰值（0…1），讀完歸零。麥克風是增益後的值。
    /// 取出自上次讀取以來、實際寫進檔案的兩軌 RMS（線性 0…1），讀完歸零。
    func takeLevels() -> (mic: Float, sys: Float) {
        shared.withLock { s in
            let n = Float(max(s.levelFrames, 1))
            let r = ((s.micSumSq / n).squareRoot(), (s.sysSumSq / n).squareRoot())
            s.micSumSq = 0; s.sysSumSq = 0; s.levelFrames = 0
            return r
        }
    }

    /// 單軌靜音：該軌寫入靜音（其餘照常）。
    func setMuted(mic: Bool, system: Bool) { shared.withLock { $0.micMuted = mic; $0.sysMuted = system } }

    func setPaused(_ paused: Bool) { shared.withLock { $0.paused = paused } }

    // MARK: - 開始／停止

    func start(micUID: String?, outputURL: URL) throws {
        precondition(procID == nil)
        do {
            try createTap()
            try createAggregate(micUID: micUID)
            fileRate = sampleRate
            resamplePos = 0; resamplePrev = (0, 0)
            zeros.initialize(repeating: 0, count: 4096 * 2)
            try openFile(url: outputURL)
            try startIO()
            currentMicUID = micUID
        } catch {
            teardown()
            throw error
        }
    }

    /// 錄音中換麥克風：不關檔，只重建 tap＋聚合裝置；中間空檔在新裝置第一次回呼時補寫靜音。
    /// 在背景執行緒呼叫（建裝置要一點時間）。
    func switchMicrophone(to micUID: String) throws {
        guard procID != nil, micUID != currentMicUID else { return }
        shared.withLock { $0.gapStart = DispatchTime.now().uptimeNanoseconds }
        teardownGraph()
        do {
            try createTap()
            try createAggregate(micUID: micUID)
            try startIO()
            currentMicUID = micUID
            if echoCancellationOn { setEchoCancellation(true) }   // 回音消除跟著換到新麥克風
            DebugLog.write("switched mic -> \(micUID) sr=\(sampleRate) fileRate=\(fileRate)")
        } catch {
            teardownGraph()
            throw error
        }
    }

    /// 自己做的回音消除開／關（即時、不斷錄；只是切換麥克風取哪一路）。
    func setAEC(_ on: Bool) {
        shared.withLock { $0.aecOn = on }
        echoCancellationOn = on
        DebugLog.write("aec \(on ? "ON" : "OFF")")
    }
    var aecStats: am_aec_stats {
        var st = am_aec_stats()
        if let aec { am_aec_get_stats(aec, &st) }
        return st
    }

    /// Apple VPIO 版（隱藏除錯選項 -useVPIO YES；會把其他 App 壓低約 7 dB，所以預設不用）。在背景執行緒呼叫。
    func setEchoCancellation(_ on: Bool) {
        guard procID != nil else { return }
        if on {
            guard let uid = currentMicUID, let dev = AudioHAL.device(forUID: uid) else { return }
            let vp = VoiceProcessingMic(targetRate: sampleRate)
            do {
                try vp.start(micDevice: dev)
                vpMic?.stop()
                vpMic = vp
                shared.withLock { $0.useVPMic = true }
                echoCancellationOn = true
                DebugLog.write("echo cancellation ON (mic mode: \(VoiceProcessingMic.activeMicrophoneModeName))")
            } catch {
                DebugLog.write("echo cancellation failed: \(error.localizedDescription)")
            }
        } else {
            shared.withLock { $0.useVPMic = false }
            vpMic?.stop(); vpMic = nil
            echoCancellationOn = false
            DebugLog.write("echo cancellation OFF")
        }
    }

    /// 只拆音訊裝置（tap＋聚合裝置＋IOProc），檔案不動。
    private func teardownGraph() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// 停止並把檔案收尾寫完（寫出 moov）。回傳實際寫入的影格數。
    @discardableResult
    func stop() -> Int64 { teardown() }

    @discardableResult
    private func teardown() -> Int64 {
        shared.withLock { $0.useVPMic = false }
        vpMic?.stop(); vpMic = nil; echoCancellationOn = false
        let st = shared.withLock { s -> Shared in s.writing = false; return s }
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            let wall = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1e9
            DebugLog.write("io stats: callbacks=\(st.callbacks) frames=\(st.framesWritten) wall=\(wall)s micGain=\(st.micGain) autoLevel=\(autoLevel)")
            if st.aecFrames > 0 {
                let cpu = Double(st.aecNanos) / 1e9 / (Double(st.aecFrames) / sampleRate) * 100
                let s = aecStats
                DebugLog.write(String(format: "aec cpu %.2f%% of one core; erle %.1f dB, est delay %.1f ms, bulk %.1f ms", cpu, s.erle_db, s.est_delay_ms, s.delay_ms))
            }
        }
        procID = nil
        teardownGraph()
        if let file {
            ExtAudioFileDispose(file)   // 會把非同步寫入的尾巴寫完、補好 moov
        }
        file = nil
        currentMicUID = nil
        scratch?.deallocate()
        scratch = nil
        if let a = aec { am_aec_destroy(a); aec = nil }
        return st.framesWritten
    }

    // MARK: - 步驟

    private func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var addr = AudioHAL.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return (st == noErr && obj != kAudioObjectUnknown) ? obj : nil
    }

    private func createTap() throws {
        // 全系統立體聲混音，排除自己（excludesCurrentProcessAudio 的等價做法）
        // ⚠ 不排除自己：本 App 錄音時會送出全零的靜音（SilenceKeeper）讓 tap 能立刻啟動，
        // 被排除的程序不算 tap 的「writer」。本 App 本身不發出任何聲音，所以不排除也不會錄到自己。
        let exclude: [AudioObjectID] = UserDefaults.standard.bool(forKey: "excludeSelf") ? (ownProcessObject().map { [$0] } ?? []) : []
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        desc.uuid = UUID()
        desc.name = "AudioMemo System Audio"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted          // 錄的同時照常從喇叭／耳機播出
        var id = AudioObjectID(kAudioObjectUnknown)
        let st = AudioHardwareCreateProcessTap(desc, &id)
        guard st == noErr else { throw Failure(step: "AudioHardwareCreateProcessTap", status: st) }
        tapID = id
    }

    private func createAggregate(micUID: String?) throws {
        guard let tapUID = AudioHAL.string(tapID, kAudioTapPropertyUID) else {
            throw Failure(step: "kAudioTapPropertyUID", status: -1)
        }
        // 主裝置＝麥克風（也是整個聚合裝置的時鐘）。
        // ⚠ 實測：只有 tap、或拿輸出裝置當主裝置時，IOProc 完全不會被呼叫 → 一定要有麥克風。
        guard let micUID, let micID = AudioHAL.device(forUID: micUID) else {
            throw NoMicrophone()
        }
        micBufferCount = AudioHAL.streamCount(micID, input: true)
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioMemo Recorder",
            kAudioAggregateDeviceUIDKey: "com.bookai.audiomemo.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: micUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: micUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        let st = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &id)
        guard st == noErr else { throw Failure(step: "AudioHardwareCreateAggregateDevice", status: st) }
        aggregateID = id

        let sr: Float64 = AudioHAL.get(id, AudioHAL.address(kAudioDevicePropertyNominalSampleRate), default: 48000)
        sampleRate = sr > 0 ? sr : 48000
        let layout = AudioHAL.inputChannelsPerBuffer(id)
        let micName = AudioHAL.string(micID, kAudioObjectPropertyName) ?? "?"
        DebugLog.write("aggregate sr=\(sampleRate) inputBuffers=\(layout) micBuffers=\(micBufferCount) mic=\(micName) [\(micUID)] split=\(splitChannels)")
        if layout.count <= micBufferCount { micBufferCount = max(0, layout.count - 1) }
    }

    private func openFile(url: URL) throws {
        var aac = AudioStreamBasicDescription()
        aac.mFormatID = kAudioFormatMPEG4AAC
        // AAC 最高 48 kHz；裝置是 88.2／96 kHz 時由 ExtAudioFile 自動轉成 48 kHz
        let standard: [Double] = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]
        aac.mSampleRate = standard.contains(fileRate) ? fileRate : (fileRate > 48000 ? 48000 : 44100)
        aac.mChannelsPerFrame = 2
        var f: ExtAudioFileRef?
        var lpcm = AudioStreamBasicDescription(
            mSampleRate: fileRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var st = rawCapture
            ? ExtAudioFileCreateWithURL(url as CFURL, kAudioFileCAFType, &lpcm, nil, AudioFileFlags.eraseFile.rawValue, &f)
            : ExtAudioFileCreateWithURL(url as CFURL, kAudioFileM4AType, &aac, nil, AudioFileFlags.eraseFile.rawValue, &f)
        guard st == noErr, let f else { throw Failure(step: "ExtAudioFileCreateWithURL", status: st) }
        file = f

        var client = AudioStreamBasicDescription(
            mSampleRate: fileRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        st = ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat,
                                     UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard st == noErr else { throw Failure(step: "ClientDataFormat", status: st) }

        // AAC 256 kbps（透明品質，約每分鐘 1.9 MB）：設定編碼器位元率後要清掉 ConverterConfig 讓設定生效
        var conv: AudioConverterRef?
        var convSize = UInt32(MemoryLayout<AudioConverterRef?>.size)
        if !rawCapture, ExtAudioFileGetProperty(f, kExtAudioFileProperty_AudioConverter, &convSize, &conv) == noErr, let conv {
            var bitrate: UInt32 = 256_000
            let bst = AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitrate)
            var nilConfig: Unmanaged<CFPropertyList>? = nil
            ExtAudioFileSetProperty(f, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size), &nilConfig)
            if bst != noErr { DebugLog.write("set AAC bitrate failed \(bst)") }
        }

        // 先在非即時執行緒初始化非同步寫入的緩衝
        st = ExtAudioFileWriteAsync(f, 0, nil)
        guard st == noErr else { throw Failure(step: "ExtAudioFileWriteAsync(prime)", status: st) }

        scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrames * 2)
        autoLevel = UserDefaults.standard.object(forKey: "autoLevel") == nil ? true : UserDefaults.standard.bool(forKey: "autoLevel")
        // 自動音量平衡（core/am_level.c）：麥克風講話時約 -15 dBFS、系統聲約 -17 dBFS；底噪不放大
        am_leveler_init(&micLeveler, 0.17, 0.0032, 0.5, 16, 4)
        am_leveler_init(&sysLeveler, 0.141, 0.0018, 0.5, 8, 1)
        // 限幅 -3 dBFS（AAC 編碼後過衝約 1 dB，解碼後仍 < -1 dBFS）
        am_limiter_init(&limiter, 0.708, 0.08, fileRate)
        if let a = aec { am_aec_destroy(a) }
        aec = am_aec_create(Int32(sampleRate))
        aecLatency = Int(am_aec_latency(aec))
        sysDelayL = [Float](repeating: 0, count: aecLatency); sysDelayR = sysDelayL; micDelay = sysDelayL; delayPos = 0
        micMuteGain = 1; sysMuteGain = 1
        shared.withLock { $0 = Shared(); $0.writing = true }
    }

    private func startIO() throws {
        var pid: AudioDeviceIOProcID?
        let micBuffers = micBufferCount
        let st = AudioDeviceCreateIOProcIDWithBlock(&pid, aggregateID, nil) { [weak self] _, inInput, _, _, _ in
            self?.process(inInput, micBuffers: micBuffers)
        }
        guard st == noErr, let pid else { throw Failure(step: "AudioDeviceCreateIOProcIDWithBlock", status: st) }
        procID = pid
        startedAt = DispatchTime.now().uptimeNanoseconds
        let st2 = AudioDeviceStart(aggregateID, pid)
        guard st2 == noErr else { throw Failure(step: "AudioDeviceStart", status: st2) }
    }

    // MARK: - 即時執行緒

    private func process(_ input: UnsafePointer<AudioBufferList>, micBuffers: Int) {
        guard let file, let out = scratch else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard abl.count > 0 else { return }

        // 以 tap（最後幾個 buffer）的長度為準
        let tapStart = min(micBuffers, abl.count - 1)
        let ref = abl[tapStart]
        let refCh = max(1, Int(ref.mNumberChannels))
        let frames = min(Int(ref.mDataByteSize) / (4 * refCh), scratchFrames)
        guard frames > 0 else { return }

        // 1) 拆出三路：麥克風（各聲道平均）、系統左、系統右
        var micSq: Float = 0, sysSq: Float = 0
        micBlock.withUnsafeMutableBufferPointer { mic in
        sysLBlock.withUnsafeMutableBufferPointer { sL in
        sysRBlock.withUnsafeMutableBufferPointer { sR in
            for i in 0..<frames {
                var m: Float = 0, mN = 0
                for b in 0..<tapStart {
                    let buf = abl[b]
                    guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let ch = max(1, Int(buf.mNumberChannels))
                    guard i < Int(buf.mDataByteSize) / (4 * ch) else { continue }
                    for c in 0..<ch { m += p[i * ch + c]; mN += 1 }
                }
                mic[i] = mN > 0 ? m / Float(mN) : 0
                var l: Float = 0, r: Float = 0, nL = 0, nR = 0, chIndex = 0
                for b in tapStart..<abl.count {
                    let buf = abl[b]
                    let ch = max(1, Int(buf.mNumberChannels))
                    guard let p = buf.mData?.assumingMemoryBound(to: Float.self),
                          i < Int(buf.mDataByteSize) / (4 * ch) else { chIndex += ch; continue }
                    for c in 0..<ch {
                        if chIndex % 2 == 0 { l += p[i * ch + c]; nL += 1 } else { r += p[i * ch + c]; nR += 1 }
                        chIndex += 1
                    }
                }
                if nL > 0 { l /= Float(nL) }
                r = nR > 0 ? r / Float(nR) : l
                sL[i] = l; sR[i] = r
                micSq += mic[i] * mic[i]
                sysSq += 0.5 * (l * l + r * r)
            }
        }}}

        // 1b) 回音消除開著：麥克風改用 VPIO 處理過的那一路（同一支麥克風、同一個時鐘；固定約 20 ms 緩衝）
        if shared.withLock({ $0.useVPMic }), let vp = vpMic {
            if compareEcho { for i in 0..<frames { rawMic[i] = micBlock[i] } }
            micBlock.withUnsafeMutableBufferPointer { mic in
                _ = vp.ring.read(mic.baseAddress!, frames, target: Int(0.02 * sampleRate))
                micSq = 0
                for i in 0..<frames { micSq += mic[i] * mic[i] }
            }
        }

        // 1c) 回音消除（自己做的，core/am_aec.c）：參考＝系統聲（還沒到喇叭前的數位訊號，同一個時鐘）。
        //     開或關都讓麥克風與系統聲走同樣 aecLatency 的延遲，兩軌永遠對齊，切換時不會錯位。
        if !rawCapture, let aec {
            let on = shared.withLock { $0.aecOn }
            if compareEcho { for i in 0..<frames { rawMic[i] = micBlock[i] } }
            for i in 0..<frames { refMono[i] = 0.5 * (sysLBlock[i] + sysRBlock[i]) }
            let t0 = DispatchTime.now().uptimeNanoseconds
            micBlock.withUnsafeMutableBufferPointer { mic in refMono.withUnsafeBufferPointer { ref in aecOut.withUnsafeMutableBufferPointer { o in
                am_aec_process(aec, mic.baseAddress!, ref.baseAddress!, o.baseAddress!, Int32(frames))
            }}}
            let dt = DispatchTime.now().uptimeNanoseconds - t0
            micSq = 0; sysSq = 0
            for i in 0..<frames {
                let rawDelayed = micDelay[delayPos]; micDelay[delayPos] = micBlock[i]
                let l = sysDelayL[delayPos], r = sysDelayR[delayPos]
                sysDelayL[delayPos] = sysLBlock[i]; sysDelayR[delayPos] = sysRBlock[i]
                delayPos = (delayPos + 1) % aecLatency
                if compareEcho { rawMic[i] = rawDelayed }
                micBlock[i] = on ? aecOut[i] : rawDelayed
                sysLBlock[i] = l; sysRBlock[i] = r
                micSq += micBlock[i] * micBlock[i]
                sysSq += 0.5 * (l * l + r * r)
            }
            shared.withLock { $0.aecNanos += dt; $0.aecFrames += Int64(frames) }
        }

        // 2) 自動音量平衡（兩軌各自）
        let blockSec = Float(Double(frames) / sampleRate)
        var (mg0, mg1): (Float, Float) = (4, 4)
        var (sg0, sg1): (Float, Float) = (1, 1)
        if autoLevel {
            am_leveler_update(&micLeveler, (micSq / Float(frames)).squareRoot(), blockSec, &mg0, &mg1)
            am_leveler_update(&sysLeveler, (sysSq / Float(frames)).squareRoot(), blockSec, &sg0, &sg1)
        }
        let mStep = (mg1 - mg0) / Float(frames), sStep = (sg1 - sg0) / Float(frames)

        // 3) 單軌靜音（區塊內淡出／淡入）
        let mutes = shared.withLock { ($0.micMuted, $0.sysMuted) }
        let mm0 = micMuteGain, mm1: Float = mutes.0 ? 0 : 1
        let sm0 = sysMuteGain, sm1: Float = mutes.1 ? 0 : 1
        micMuteGain = mm1; sysMuteGain = sm1
        let mmStep = (mm1 - mm0) / Float(frames), smStep = (sm1 - sm0) / Float(frames)

        // 4) 混音＋限幅
        var micOutSq: Float = 0, sysOutSq: Float = 0
        for i in 0..<frames {
            let fi = Float(i)
            let m = micBlock[i] * (mg0 + mStep * fi) * (mm0 + mmStep * fi)
            let sg = (sg0 + sStep * fi) * (sm0 + smStep * fi)
            let l = sysLBlock[i] * sg, r = sysRBlock[i] * sg
            micOutSq += m * m
            sysOutSq += 0.5 * (l * l + r * r)
            var outL: Float, outR: Float
            if rawCapture {
                outL = micBlock[i]; outR = 0.5 * (sysLBlock[i] + sysRBlock[i])
            } else if compareEcho {
                outL = rawMic[i]; outR = micBlock[i]
            } else if splitChannels {
                outL = m; outR = (l + r) * 0.5
            } else {
                outL = l + m; outR = r + m
            }
            if !compareEcho && !rawCapture { am_limiter_process(&limiter, &outL, &outR) }
            out[i * 2] = outL
            out[i * 2 + 1] = outR
        }
        let gain = mg1

        // 5) 取樣率跟檔案不同（換到別的麥克風）→ 線性內插轉成檔案取樣率
        var writePtr = out
        var writeFrames = frames
        if sampleRate != fileRate {
            let ratio = sampleRate / fileRate
            var n = 0
            var pos = resamplePos
            while pos < Double(frames - 1) || (pos < Double(frames) && frames == 1) {
                let i = Int(pos.rounded(.down))
                let frac = Float(pos - Double(i))
                let aL = i < 0 ? resamplePrev.0 : out[i * 2], aR = i < 0 ? resamplePrev.1 : out[i * 2 + 1]
                let bL = out[min(i + 1, frames - 1) * 2], bR = out[min(i + 1, frames - 1) * 2 + 1]
                resampled[n * 2] = aL + (bL - aL) * frac
                resampled[n * 2 + 1] = aR + (bR - aR) * frac
                n += 1
                pos += ratio
                if n >= 16384 * 4 - 1 { break }
            }
            resamplePos = pos - Double(frames)
            resamplePrev = (out[(frames - 1) * 2], out[(frames - 1) * 2 + 1])
            writePtr = resampled
            writeFrames = n
        }

        let mq = micOutSq, sq = sysOutSq
        let fr = fileRate
        let wf = writeFrames
        let (shouldWrite, gapFrames) = shared.withLock { s -> (Bool, Int) in
            s.micSumSq += mq
            s.sysSumSq += sq
            s.levelFrames += frames
            s.callbacks += 1
            s.micGain = gain
            var gap = 0
            if s.gapStart > 0 {
                // 換裝置的空檔：補寫靜音（最多 30 秒），時間軸才對得上
                let secs = Double(DispatchTime.now().uptimeNanoseconds - s.gapStart) / 1e9
                gap = Int(min(secs, 30) * fr)
                s.gapStart = 0
            }
            let w = s.writing && !s.paused
            if w { s.framesWritten += Int64(wf + gap) } else { gap = 0 }
            return (w, gap)
        }
        guard shouldWrite else { return }

        var remaining = gapFrames
        while remaining > 0 {
            let n = min(remaining, 4096)
            var z = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(n * 8), mData: UnsafeMutableRawPointer(zeros)))
            ExtAudioFileWriteAsync(file, UInt32(n), &z)
            remaining -= n
        }
        guard writeFrames > 0 else { return }
        var list = AudioBufferList(mNumberBuffers: 1,
                                   mBuffers: AudioBuffer(mNumberChannels: 2,
                                                         mDataByteSize: UInt32(writeFrames * 8),
                                                         mData: UnsafeMutableRawPointer(writePtr)))
        ExtAudioFileWriteAsync(file, UInt32(writeFrames), &list)
    }
}

/// 除錯紀錄：~/Library/Logs/AudioMemo/debug.log（排查裝置／權限問題用）。
enum DebugLog {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AudioMemo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }()

    private static let lock = NSLock()

    static func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) [\(getpid())] \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}
