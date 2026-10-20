import SwiftUI

/// 右上角「提示區」的提示類型（集中定義；文字都在字典）。跟左上的錄音狀態機分開。
enum Notice: Equatable {
    case followedApp(app: String, device: String)   // 已跟上某 App 使用的麥克風
    case followedInUse(device: String)              // 已跟上正在使用中的麥克風（判斷不到 App）
    case switchedDevice(device: String)             // 已切換到新的麥克風（系統預設變了、插拔）
    case deviceLost(device: String)                 // 選的麥克風不見了，改用系統預設
    case bluetoothWarning(device: String)           // 藍牙麥克風音質提醒（要使用者關掉）
    case exportDone(file: String)                   // 轉檔完成
    case uploadDone(file: String)                   // 已上傳到 Osmi，正在打開網頁
    case tooShort                                   // 錄音太短沒存
    case message(String)                            // 其他（錯誤訊息等，文字已在字典取好）

    var text: String {
        switch self {
        case .followedApp(let app, let device): String(format: L("notice.followedApp"), app, device)
        case .followedInUse(let device): String(format: L("notice.followedInUse"), device)
        case .switchedDevice(let device): String(format: L("notice.switchedDevice"), device)
        case .deviceLost(let device): String(format: L("notice.deviceLost"), device)
        case .bluetoothWarning: L("notice.bluetooth")
        case .exportDone(let file): String(format: L("notice.exportDone"), file)
        case .uploadDone: L("notice.uploadDone")
        case .tooShort: L("notice.tooShort")
        case .message(let m): m
        }
    }

    var symbol: String {
        switch self {
        case .followedApp, .followedInUse, .switchedDevice: "arrow.triangle.2.circlepath"
        case .deviceLost: "mic.slash"
        case .bluetoothWarning: "exclamationmark.triangle"
        case .exportDone, .uploadDone: "checkmark.circle"
        case .tooShort, .message: "info.circle"
        }
    }

    var color: Color {
        switch self {
        case .bluetoothWarning, .deviceLost: Theme.warn
        default: Theme.primaryText
        }
    }

    /// 要使用者自己關掉（不會 4 秒後自動翻回）
    var isSticky: Bool { if case .bluetoothWarning = self { return true } else { return false } }
}

/// 提示佇列：一次顯示一則；短暫提示約 4 秒後翻回常駐文字，連續多則依序排隊。
@MainActor
final class NoticeCenter: ObservableObject {
    @Published private(set) var current: Notice?
    private var queue: [Notice] = []
    private var timer: Timer?
    static let duration: TimeInterval = 4

    func post(_ n: Notice) {
        DebugLog.write("notice: \(n.text)")
        if current == n || queue.contains(n) { return }
        if current == nil { show(n) } else if current?.isSticky == true && !n.isSticky { queue.insert(n, at: 0); showNextAfterSticky(n) } else { queue.append(n) }
    }

    /// 黏著提示在顯示時，來了短暫提示：先翻去短暫提示，結束後再翻回黏著提示。
    private func showNextAfterSticky(_ n: Notice) {
        guard let sticky = current else { return }
        queue.removeFirst()
        queue.insert(sticky, at: 0)
        show(n)
    }

    /// 關掉目前的提示（黏著提示的「略過」）。
    func dismiss() {
        timer?.invalidate(); timer = nil
        next()
    }

    /// 移除某類黏著提示（例如換掉藍牙麥克風了）。
    func clearSticky() {
        queue.removeAll { $0.isSticky }
        if current?.isSticky == true { dismiss() }
    }

    private func show(_ n: Notice) {
        current = n
        timer?.invalidate()
        guard !n.isSticky else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.duration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.next() }
        }
    }

    private func next() {
        if queue.isEmpty { current = nil } else { show(queue.removeFirst()) }
    }
}

/// 提示區一格要顯示的內容（值型別：翻牌時舊、新兩格各自保留自己的內容）。
struct FlapItem: Equatable {
    var symbol: String
    var text: String
    var color: Color
    var dismissible = false
    /// 同一個 key 只更新文字、不翻牌（例如上傳進度 12% → 13%）；key 變了才翻牌。nil＝用文字當 key。
    var key: String? = nil
    /// 額外的動作按鈕（例如「取消」「重試」），按下時把 id 傳回 onAction
    var actions: [FlapAction] = []
    var flipKey: String { key ?? text }
}

struct FlapAction: Equatable {
    let id: String
    let title: String
}

/// 時鐘翻牌（split-flap）：換字時舊字上半往下翻、新字下半翻上來（合計約 0.28 秒，ease-out）；
/// 系統「減少動態效果」時改成淡入淡出。
struct FlapText: View {
    let item: FlapItem
    var onDismiss: (() -> Void)?
    var onAction: ((String) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 除錯：-slowFlap YES 時放慢 6 倍（自我截圖連拍用）
    private static let slow = UserDefaults.standard.bool(forKey: "slowFlap") ? 6.0 : 1.0
    static var half: Double { 0.13 * slow }   // 兩段合計約 0.26 秒（含收尾 < 0.3 秒）

    @State private var shown: FlapItem?
    @State private var old: FlapItem?
    @State private var topAngle: Double = 0        // 舊字上半：0 → -90
    @State private var bottomAngle: Double = 90    // 新字下半：90 → 0
    @State private var flipping = false

    @State private var cellHeight: CGFloat = 20

    /// 某張牌的上半或下半（用 frame＋clipped 切，不用 mask）。
    private func half(_ it: FlapItem, top: Bool) -> some View {
        cell(it)
            .frame(height: cellHeight)
            .frame(height: cellHeight / 2, alignment: top ? .top : .bottom)
            .clipped()
    }

    var body: some View {
        let now = shown ?? item
        ZStack {
            // 量高度用（看不見）：一般狀態就是它本身
            cell(now)
                .background(GeometryReader { g in Color.clear.preference(key: FlapHeightKey.self, value: g.size.height) })
                .opacity(flipping ? 0 : 1)
            if flipping, let old {
                VStack(spacing: 0) {
                    half(now, top: true)          // 底層上半：新字
                    half(old, top: false)         // 底層下半：舊字（等新字下半翻下來蓋住）
                }
                VStack(spacing: 0) {
                    half(old, top: true)          // 舊字上半往下翻
                        .scaleEffect(x: 1, y: max(0.001, cos(topAngle * .pi / 180)), anchor: .bottom)
                        .brightness(-0.12 * sin(-topAngle * .pi / 180))
                        .opacity(topAngle <= -89 ? 0 : 1)
                    half(now, top: false)         // 新字下半從中線翻下來
                        .scaleEffect(x: 1, y: max(0.001, cos(bottomAngle * .pi / 180)), anchor: .top)
                        .brightness(-0.12 * sin(bottomAngle * .pi / 180))
                        .opacity(bottomAngle >= 89 ? 0 : 1)
                }
            }
        }
        .onPreferenceChange(FlapHeightKey.self) { if $0 > 0 && !flipping { cellHeight = $0 } }
        .onAppear { shown = item }
        .onChange(of: item) { prev, newItem in
            if prev.flipKey == newItem.flipKey { shown = newItem; return }   // 同一則提示只換內容，不翻牌
            if reduceMotion {
                withAnimation(.easeInOut(duration: 0.25)) { shown = newItem }
            } else {
                flip(from: prev, to: newItem)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func cell(_ it: FlapItem) -> some View {
        HStack(spacing: 6) {
            Image(systemName: it.symbol)
                .font(.system(size: 12, weight: .semibold))
            Text(it.text)
                .font(.system(size: Theme.fsCaption))
                .lineLimit(2)                       // 長字串換行（最多兩行），再不夠才縮字
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(it.actions, id: \.id) { a in
                Button(a.title) { onAction?(a.id) }
                    .buttonStyle(.link)
                    .font(.system(size: Theme.fsSmall))
                    .fixedSize()
            }
            if it.dismissible, let onDismiss {
                Button(L("action.dismiss"), action: onDismiss)
                    .buttonStyle(.link)
                    .font(.system(size: Theme.fsSmall))
                    .fixedSize()
            }
        }
        .foregroundStyle(it.color)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .trailing)   // 每張牌一樣大：翻動的半片能完整蓋住底下那張
        .background(Theme.surface)
    }

    private func flip(from prev: FlapItem, to newItem: FlapItem) {
        old = shown ?? prev
        shown = newItem
        topAngle = 0; bottomAngle = 90; flipping = true
        let t0 = Date()
        let log = UserDefaults.standard.bool(forKey: "logFlap")
        withAnimation(.easeOut(duration: Self.half)) { topAngle = -90 }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.half) {
            withAnimation(.easeOut(duration: Self.half)) { bottomAngle = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.half + 0.005) {
                flipping = false
                old = nil
                if log { DebugLog.write(String(format: "flap done in %.3fs", Date().timeIntervalSince(t0))) }
            }
        }
    }
}

private struct FlapHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
