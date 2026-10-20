import AVFoundation
import AudioToolbox
import CoreAudio
import os

/// 單聲道 Float 環形緩衝：VPIO 的回呼（寫）→ 聚合裝置的 IOProc（讀）。
final class MonoRing: @unchecked Sendable {
    private let cap: Int
    private let buf: UnsafeMutablePointer<Float>
    private struct Idx { var r = 0; var w = 0; var primed = false }
    private let idx = OSAllocatedUnfairLock(initialState: Idx())

    init(capacity: Int) {
        cap = capacity
        buf = .allocate(capacity: capacity)
        buf.initialize(repeating: 0, count: capacity)
    }
    deinit { buf.deallocate() }

    func reset() { idx.withLock { $0 = Idx() } }

    func write(_ p: UnsafePointer<Float>, _ n: Int) {
        idx.withLockUnchecked { s in
            for i in 0..<n { buf[(s.w + i) % cap] = p[i] }
            s.w += n
            if s.w - s.r > cap { s.r = s.w - cap }   // 溢位：丟掉最舊的
        }
    }

    /// 讀 n 個樣本。延遲維持在 target 附近：太多就丟掉最舊的（防止延遲越積越大），不夠就補 0。
    /// 回傳實際有資料的樣本數。
    func read(_ out: UnsafeMutablePointer<Float>, _ n: Int, target: Int) -> Int {
        idx.withLockUnchecked { s in
            var avail = s.w - s.r
            if !s.primed {
                guard avail >= target + n else { for i in 0..<n { out[i] = 0 }; return 0 }
                s.primed = true
            }
            if avail > target * 3 + n { s.r = s.w - (target + n); avail = target + n }
            let k = min(n, avail)
            for i in 0..<k { out[i] = buf[(s.r + i) % cap] }
            for i in k..<n { out[i] = 0 }
            s.r += k
            return k
        }
    }
}

/// 回音消除的麥克風路徑：Apple Voice Processing I/O（AUVoiceIO，跟 FaceTime 同一套）。
/// 只處理麥克風；系統聲音照舊由 process tap 錄。處理後的麥克風（單聲道、已是聚合裝置的取樣率）寫進 MonoRing，
/// 聚合裝置的 IOProc 每個區塊從這裡拿麥克風樣本，取代聚合裝置裡的原始麥克風。
/// 兩路同步：VPIO 用的是同一支麥克風（同一個硬體時鐘），不會漂移；固定延遲用環形緩衝的目標水位（約 20 ms）吸收，
/// 水位超過就丟掉最舊的樣本，延遲不會越積越大。
/// ⚠ 不用 AVAudioEngine 的 setVoiceProcessingEnabled：這台機器上 engine 啟動時輸出節點初始化失敗（-10875，
/// 內建喇叭 96 kHz、麥克風 48 kHz），直接用 AUVoiceIO 則正常。
final class VoiceProcessingMic {
    let ring = MonoRing(capacity: 48000 * 4)
    private var unit: AudioUnit?
    private let targetRate: Double
    private(set) var running = false
    fileprivate var renderBuf = UnsafeMutablePointer<Float>.allocate(capacity: 8192)

    init(targetRate: Double) { self.targetRate = targetRate }
    deinit { stop(); renderBuf.deallocate() }

    private static func check(_ st: OSStatus, _ step: String) throws {
        guard st == noErr else { throw CaptureEngine.Failure(step: "VPIO \(step)", status: st) }
    }

    func start(micDevice: AudioObjectID) throws {
        stop()
        ring.reset()
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_VoiceProcessingIO,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw CaptureEngine.Failure(step: "VPIO find", status: -1) }
        var au: AudioUnit?
        try Self.check(AudioComponentInstanceNew(comp, &au), "new")
        guard let au else { return }
        unit = au
        var one: UInt32 = 1, zero: UInt32 = 0
        try Self.check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "enable input")
        // 指定麥克風（跟聚合裝置同一支）
        var dev = micDevice
        let devSt = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 1, &dev, 4)
        if devSt != noErr { DebugLog.write("vpio: set input device failed \(devSt) (uses system default input)") }
        // 我們要的格式：Float32、單聲道、聚合裝置的取樣率
        var fmt = AudioStreamBasicDescription(mSampleRate: targetRate, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                              mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                              mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        let fsz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Self.check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, fsz), "input format")
        try Self.check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, fsz), "output format")
        // 自己的 AGC 關掉（交給我們的自動音量平衡）；其他 App 的聲音只壓到最小
        AudioUnitSetProperty(au, kAUVoiceIOProperty_VoiceProcessingEnableAGC, kAudioUnitScope_Global, 0, &zero, 4)
        var duck = AUVoiceIOOtherAudioDuckingConfiguration(mEnableAdvancedDucking: false, mDuckingLevel: .min)
        let dst = AudioUnitSetProperty(au, kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, 0,
                                       &duck, UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size))
        if dst != noErr { DebugLog.write("vpio: ducking config failed \(dst)") }

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        var inCB = AURenderCallbackStruct(inputProc: vpioInputCallback, inputProcRefCon: ctx)
        try Self.check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1,
                                            &inCB, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "input callback")
        var outCB = AURenderCallbackStruct(inputProc: vpioSilenceCallback, inputProcRefCon: ctx)
        try Self.check(AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                            &outCB, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "render callback")
        try Self.check(AudioUnitInitialize(au), "initialize")
        // 舊的「壓低非語音聲音」開關（已標為過時，但 macOS 仍讀）：關掉，盡量不壓其他 App
        var noDuck: UInt32 = 0
        let nd = AudioUnitSetProperty(au, AudioUnitPropertyID(2102 /* kAUVoiceIOProperty_DuckNonVoiceAudio */), kAudioUnitScope_Global, 0, &noDuck, 4)
        DebugLog.write("vpio: DuckNonVoiceAudio=0 -> \(nd)")
        // ducking 設定在 initialize 之後再設一次（之前設的可能被初始化重設）
        var duck2 = AUVoiceIOOtherAudioDuckingConfiguration(mEnableAdvancedDucking: false, mDuckingLevel: .min)
        let d2 = AudioUnitSetProperty(au, kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, 0,
                                      &duck2, UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size))
        var readBack = AUVoiceIOOtherAudioDuckingConfiguration(mEnableAdvancedDucking: true, mDuckingLevel: .max)
        var rsz = UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size)
        AudioUnitGetProperty(au, kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, 0, &readBack, &rsz)
        DebugLog.write("vpio: ducking set=\(d2) readback advanced=\(readBack.mEnableAdvancedDucking) level=\(readBack.mDuckingLevel.rawValue)")
        try Self.check(AudioOutputUnitStart(au), "start")
        running = true
        DebugLog.write("vpio: started on device \(micDevice) at \(targetRate) Hz")
    }

    fileprivate func pull(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ ts: UnsafePointer<AudioTimeStamp>, _ frames: UInt32) -> OSStatus {
        guard let unit, frames <= 8192 else { return noErr }
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4,
                                                                             mData: UnsafeMutableRawPointer(renderBuf)))
        let st = AudioUnitRender(unit, flags, ts, 1, frames, &list)
        if st == noErr { ring.write(renderBuf, Int(frames)) }
        return st
    }

    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        running = false
    }

    /// 系統目前回報的麥克風模式（語音隔離／寬頻／標準），用來確認 VPIO 開著時控制中心的模式有套用。
    static var activeMicrophoneModeName: String {
        switch AVCaptureDevice.activeMicrophoneMode {
        case .standard: "standard"
        case .wideSpectrum: "wideSpectrum"
        case .voiceIsolation: "voiceIsolation"
        @unknown default: "unknown"
        }
    }
}

private func vpioInputCallback(_ ref: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                               _ ts: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                               _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<VoiceProcessingMic>.fromOpaque(ref).takeUnretainedValue().pull(flags, ts, frames)
}

private func vpioSilenceCallback(_ ref: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                 _ ts: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                                 _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    if let data { for b in UnsafeMutableAudioBufferListPointer(data) { memset(b.mData, 0, Int(b.mDataByteSize)) } }
    flags.pointee.insert(.unitRenderAction_OutputIsSilence)
    return noErr
}

/// 回音消除的開關判斷（自動模式）：外放（內建喇叭、外接喇叭）開、耳機關。
enum EchoPolicy: String, CaseIterable, Identifiable {
    case auto, on, off
    var id: String { rawValue }
    static let key = "echoCancellation"

    static var current: EchoPolicy {
        EchoPolicy(rawValue: UserDefaults.standard.string(forKey: key) ?? "off") ?? .off   // 預設關：自做回音消除尚未全部達標（見 docs/TESTING.md），使用者可在設定改「自動」
    }

    struct OutputInfo { let name: String; let transport: UInt32; let dataSource: UInt32? }

    static func currentOutput() -> OutputInfo {
        let dev = AudioHAL.defaultDevice(input: false)
        let transport: UInt32 = AudioHAL.get(dev, AudioHAL.address(kAudioDevicePropertyTransportType), default: 0)
        var ds: UInt32 = 0
        var addr = AudioHAL.address(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let hasDS = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &ds) == noErr
        return OutputInfo(name: AudioHAL.string(dev, kAudioObjectPropertyName) ?? "?", transport: transport, dataSource: hasDS ? ds : nil)
    }

    /// 這個輸出是「外放喇叭」嗎？
    /// - 內建：資料來源是 'ispk'（喇叭）才算；插了有線耳機會變 'hdpn'（耳機）→ 不算
    /// - 藍牙：一律當耳機（AirPods、藍牙耳機最常見；藍牙喇叭請在設定選「永遠開」）
    /// - USB、HDMI、DisplayPort、Thunderbolt、AirPlay：當外接喇叭
    static func isLoudspeaker(_ o: OutputInfo) -> Bool {
        switch o.transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return o.dataSource.map { $0 == fourCC("ispk") } ?? true
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return false
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort,
             kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeAirPlay:
            return true
        default:
            return false
        }
    }

    static func shouldEnable(_ policy: EchoPolicy = current, output: OutputInfo = currentOutput()) -> Bool {
        switch policy {
        case .on: true
        case .off: false
        case .auto: isLoudspeaker(output)
        }
    }

    static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
}
