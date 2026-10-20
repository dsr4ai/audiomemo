import AVFoundation

/// 錄音期間由本 App 持續輸出「靜音」。
/// ⚠ 實測：系統完全沒有任何 App 在出聲時，process tap 不會啟動（coreaudiod：「Starting tap after waiting for writers」），
/// 整個聚合裝置（連麥克風）的 IOProc 都不會被呼叫 → 先講話、後開會議的錄音會整段不見。
/// 自己送一路全零的聲音讓輸出裝置一直在跑，tap 就能立刻開始。全零＝聽不到、也不影響其他 App。
final class SilenceKeeper {
    private var engine: AVAudioEngine?

    func start() {
        guard engine == nil else { return }
        let e = AVAudioEngine()
        let format = e.outputNode.inputFormat(forBus: 0)
        let src = AVAudioSourceNode(format: format) { isSilence, _, frameCount, abl in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            for b in list { memset(b.mData, 0, Int(b.mDataByteSize)) }
            isSilence.pointee = false   // 照樣送出，讓裝置維持運轉
            return noErr
        }
        e.attach(src)
        e.connect(src, to: e.mainMixerNode, format: format)
        do {
            try e.start()
            engine = e
        } catch {
            DebugLog.write("silence keeper failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
    }
}
