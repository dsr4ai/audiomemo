import SwiftUI

/// 錄音面板左上角的狀態機：所有狀態集中在這裡定義（圖示、文字、顏色、底線行為）。
/// ⛔ 錄音紅只用在 .recording。
enum RecorderStatus: CaseIterable {
    case ready        // 待機／就緒
    case starting     // 啟動中（音訊還沒進來）
    case recording    // 錄音中
    case paused       // 已暫停
    case playing      // 播放中（App 內播放錄音檔）
    case saving       // 儲存中（停止後收尾寫檔）
    case error        // 錯誤／權限不足

    enum Underline { case still(opacity: Double), breathe(period: Double) }

    init(phase: RecordingController.Phase, hasError: Bool, playing: Bool = false) {
        switch phase {
        case .idle: self = hasError ? .error : (playing ? .playing : .ready)
        case .starting: self = .starting
        case .recording: self = .recording
        case .paused: self = .paused
        case .saving: self = .saving
        }
    }

    var symbol: String {
        switch self {
        case .ready: "mic"
        case .starting: "circle.dotted"
        case .recording: "record.circle"
        case .paused: "pause.circle"
        case .playing: "play.circle"
        case .saving: "arrow.down.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    var title: String {
        switch self {
        case .ready: L("status.ready")
        case .starting: L("status.starting")
        case .recording: L("status.recording")
        case .paused: L("status.paused")
        case .playing: L("status.playing")
        case .saving: L("status.saving")
        case .error: L("status.error")
        }
    }

    var color: Color {
        switch self {
        case .ready, .saving, .paused: Theme.ink2
        case .starting, .playing: Theme.primaryText
        case .recording: Theme.rec      // ⛔ 唯一用錄音紅的狀態
        case .error: Theme.warn         // 警示色（琥珀），不用紅，免得跟錄音混淆
        }
    }

    var underline: Underline {
        switch self {
        case .ready: .still(opacity: 0.25)
        case .starting: .breathe(period: 1.2)
        case .recording: .breathe(period: 2.0)
        case .paused: .still(opacity: 0.7)
        case .playing: .breathe(period: 3.0)   // 品牌藍慢呼吸
        case .saving: .still(opacity: 0.4)
        case .error: .still(opacity: 0.8)
        }
    }
}

struct StatusIndicator: View {
    let status: RecorderStatus
    var forceStill = false   // 截圖預覽用
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: status.symbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 14, weight: .semibold))
                Text(status.title)
                    .font(.system(size: Theme.fsCaption, weight: .semibold))
            }
            .foregroundStyle(status.color)
            underline
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.title)
    }

    @ViewBuilder private var underline: some View {
        switch status.underline {
        case .still(let opacity):
            Capsule().fill(status.color.opacity(opacity)).frame(height: 2)
        case .breathe(let period):
            if reduceMotion || forceStill {
                Capsule().fill(status.color.opacity(0.8)).frame(height: 2)
            } else {
                // 呼吸燈：透明度 0.25 ↔ 1 緩慢循環（正弦），一個週期 = period 秒
                TimelineView(.animation) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    let phase = (sin(t * 2 * .pi / period) + 1) / 2
                    Capsule().fill(status.color.opacity(0.25 + 0.75 * phase)).frame(height: 2)
                }
            }
        }
    }
}
