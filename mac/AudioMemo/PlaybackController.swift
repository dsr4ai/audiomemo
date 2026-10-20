import AVFoundation
import Foundation

/// App 內播放（一次只播一個）。錄音中不能播放。
@MainActor
final class PlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var currentURL: URL?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    /// 即時位置（直接讀 AVAudioPlayer，不經過 0.1 秒的計時器）：給進度條每一個畫面更新用，移動才會平滑。
    var livePosition: TimeInterval { player?.currentTime ?? currentTime }

    /// 除錯：`-logProgress YES` 時記錄進度條每一幀畫出的位置，停止時寫進 debug.log（驗證是否平滑）。
    private let logProgress = UserDefaults.standard.bool(forKey: "logProgress")
    private var frames: [(Double, Double)] = []
    func recordFrame(_ value: Double) {
        guard logProgress, isPlaying else { return }
        frames.append((Date().timeIntervalSinceReferenceDate, value))
    }
    private func flushFrames() {
        guard logProgress, frames.count > 2 else { frames = []; return }
        var steps: [Double] = []
        for i in 1..<frames.count where frames[i].1 != frames[i - 1].1 { steps.append(frames[i].1 - frames[i - 1].1) }
        let dts = (1..<frames.count).map { frames[$0].0 - frames[$0 - 1].0 }
        let maxStep = steps.max() ?? 0, avgStep = steps.isEmpty ? 0 : steps.reduce(0, +) / Double(steps.count)
        let fps = Double(frames.count - 1) / max(frames.last!.0 - frames.first!.0, 0.001)
        DebugLog.write(String(format: "progress frames=%d fps=%.1f steps=%d avgStep=%.4fs maxStep=%.4fs maxFrameGap=%.3fs",
                              frames.count, fps, steps.count, avgStep, maxStep, dts.max() ?? 0))
        frames = []
    }

    /// 有東西載入（播放中或暫停中）。
    var isActive: Bool { currentURL != nil }

    func isCurrent(_ url: URL) -> Bool { currentURL?.standardizedFileURL == url.standardizedFileURL }

    /// 這一列的播放鈕：沒在播就從頭播；正在播就暫停；暫停中就繼續。
    func toggle(_ url: URL) {
        if isCurrent(url), let player {
            if player.isPlaying { player.pause(); isPlaying = false; stopTimer() }
            else { player.play(); isPlaying = true; startTimer() }
            return
        }
        play(url)
    }

    func play(_ url: URL) {
        stop()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            p.play()
            player = p
            currentURL = url
            duration = p.duration
            currentTime = 0
            isPlaying = true
            startTimer()
            DebugLog.write("play \(url.lastPathComponent)")
        } catch {
            DebugLog.write("play failed: \(error.localizedDescription)")
        }
    }

    /// 截圖用：載入後先暫停（畫面停在播放中那一列，但不出聲）。
    func pauseIfPlaying() { if let player, player.isPlaying { player.pause(); isPlaying = false } }

    func seek(to t: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(t, duration))
        currentTime = player.currentTime
    }

    func stop() {
        flushFrames()
        player?.stop()
        player = nil
        stopTimer()
        currentURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player else { return }
                self.currentTime = p.currentTime
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }   // 播完回待機
    }
}
