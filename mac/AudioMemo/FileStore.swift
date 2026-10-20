import AVFoundation
import AppKit
import Foundation

struct Recording: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let created: Date
    let size: Int64
    var duration: TimeInterval?

    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// 錄音檔都在 ~/Music/AudioMemo/；只存本機，不自動上傳、不自動刪。
@MainActor
final class FileStore: ObservableObject {
    @Published private(set) var recordings: [Recording] = []

    /// 使用者自訂的錄音資料夾（設定 → 錄音資料夾 →「…」）。
    /// 存 security-scoped bookmark（Mac App Store 沙盒版必須；非沙盒版也能用），路徑只當備援與顯示。
    nonisolated static let customFolderKey = "customFolderPath"
    nonisolated static let customFolderBookmarkKey = "customFolderBookmark"

    /// 使用者真正的家目錄（沙盒裡 homeDirectoryForCurrentUser 會是容器路徑）
    nonisolated static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// 預設 ~/Music/AudioMemo（沙盒版靠 com.apple.security.assets.music.read-write 存取）
    nonisolated static var defaultFolder: URL {
        realHome.appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent("AudioMemo", isDirectory: true)
    }

    nonisolated(unsafe) private static var resolvedBookmark: (data: Data, url: URL)?

    /// 使用者選的資料夾（若有設定）。有 bookmark 就解析並開始存取（只做一次）。
    nonisolated static var customFolder: URL? {
        if let data = UserDefaults.standard.data(forKey: customFolderBookmarkKey) {
            if let r = resolvedBookmark, r.data == data { return r.url }
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
                resolvedBookmark = (data, url)
                if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    UserDefaults.standard.set(fresh, forKey: customFolderBookmarkKey)
                }
                return url
            }
        }
        guard let p = UserDefaults.standard.string(forKey: customFolderKey), !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    /// 顯示用路徑（家目錄縮成 ~）
    nonisolated static func displayPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: realHome.path, with: "~")
    }

    nonisolated static func isUsableFolder(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            && FileManager.default.isWritableFile(atPath: url.path)
    }

    /// 自訂資料夾設定了、但不存在或沒有寫入權限 → 退回預設，畫面上提示。
    nonisolated static var customFolderUnavailable: Bool {
        if let c = customFolder { return !isUsableFolder(c) }
        return false
    }

    /// 目前的錄音資料夾。優先順序：
    /// 1) 啟動參數 `-storageFolder <路徑>`（⛔ 自動測試專用，只在這次執行有效、不寫進使用者設定）
    /// 2) 使用者自訂資料夾（可用時）  3) 預設 ~/Music/AudioMemo/
    nonisolated static var folder: URL {
        if let test = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["storageFolder"] as? String,
           !test.isEmpty {
            return URL(fileURLWithPath: (test as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let c = customFolder, isUsableFolder(c) { return c }
        return defaultFolder
    }

    /// 選擇新的錄音資料夾（nil＝恢復預設）。舊位置的檔案不搬、不刪。
    func setCustomFolder(_ url: URL?) {
        if let url {
            UserDefaults.standard.set(url.path, forKey: Self.customFolderKey)
            if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(data, forKey: Self.customFolderBookmarkKey)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: Self.customFolderKey)
            UserDefaults.standard.removeObject(forKey: Self.customFolderBookmarkKey)
        }
        DebugLog.write("folder -> \(Self.folder.path)")
        objectWillChange.send()
        refresh()
    }

    nonisolated static func ensureFolder() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// 預設檔名：`AudioMemo 2026-10-20 14.30.m4a`；同一分鐘重複就加 (2)、(3)…
    nonisolated static func newRecordingURL(date: Date = Date()) throws -> URL {
        try ensureFolder()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let base = "AudioMemo \(f.string(from: date))"
        var url = folder.appendingPathComponent(base).appendingPathExtension("m4a")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(n))").appendingPathExtension("m4a")
            n += 1
        }
        return url
    }

    /// 錄音中的暫存檔：同資料夾的隱藏檔（列表不顯示），停止後才改成正式檔名。
    nonisolated static func newTempURL() throws -> URL {
        try ensureFolder()
        return folder.appendingPathComponent(".recording-\(UUID().uuidString).m4a")
    }

    /// 列表顯示的副檔名（錄音＋轉出的格式）。
    nonisolated static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "flac", "aiff"]

    func refresh(excluding active: URL? = nil) {
        try? Self.ensureFolder()
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        let old = Dictionary(uniqueKeysWithValues: recordings.map { ($0.url, $0) })
        var list: [Recording] = urls
            .filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) && $0.standardizedFileURL != active?.standardizedFileURL }
            .map { url in
                let v = try? url.resourceValues(forKeys: Set(keys))
                let size = Int64(v?.fileSize ?? 0)
                var r = Recording(url: url, created: v?.creationDate ?? .distantPast, size: size)
                if let prev = old[url], prev.size == size { r.duration = prev.duration }
                return r
            }
        list.sort { $0.created > $1.created }
        recordings = list
        for r in list where r.duration == nil {
            Task { await loadDuration(r.url) }
        }
    }

    private func loadDuration(_ url: URL) async {
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration) else { return }
        let secs = d.seconds
        guard secs.isFinite, let i = recordings.firstIndex(where: { $0.url == url }) else { return }
        recordings[i].duration = secs
    }

    // MARK: - 操作

    /// 重新命名（只改主檔名，副檔名維持 .m4a）。回傳錯誤訊息或 nil。
    func rename(_ r: Recording, to newName: String) -> String? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !trimmed.isEmpty else { return L("error.emptyName") }
        let dest = r.url.deletingLastPathComponent().appendingPathComponent(trimmed).appendingPathExtension(r.url.pathExtension)
        if dest == r.url { return nil }
        if FileManager.default.fileExists(atPath: dest.path) { return L("error.nameExists") }
        do {
            try FileManager.default.moveItem(at: r.url, to: dest)
        } catch {
            return error.localizedDescription
        }
        refresh()
        return nil
    }

    /// 行內改名：空白或含非法字元（/、:）→ 恢復原名並提示；重名 → 自動加序號並提示。結果都顯示在右上提示區。
    func renameInline(_ r: Recording, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == r.name { return }
        if trimmed.isEmpty {
            AppModel.shared.notices.post(.message(L("rename.emptyReverted"))); refresh(); return
        }
        if trimmed.contains("/") || trimmed.contains(":") || trimmed.hasPrefix(".") {
            AppModel.shared.notices.post(.message(L("rename.illegalReverted"))); refresh(); return
        }
        let dir = r.url.deletingLastPathComponent(), ext = r.url.pathExtension
        var dest = dir.appendingPathComponent(trimmed).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path), dest.standardizedFileURL != r.url.standardizedFileURL {
            dest = dir.appendingPathComponent("\(trimmed) (\(n))").appendingPathExtension(ext); n += 1
        }
        do {
            try FileManager.default.moveItem(at: r.url, to: dest)
            DebugLog.write("rename \(r.url.lastPathComponent) -> \(dest.lastPathComponent)")
            if n > 2 { AppModel.shared.notices.post(.message(String(format: L("rename.numbered"), dest.deletingPathExtension().lastPathComponent))) }
        } catch {
            AppModel.shared.notices.post(.message(error.localizedDescription))
        }
        refresh()
    }

    /// 刪除＝移到垃圾桶（還救得回來）。
    func delete(_ r: Recording) -> String? {
        do {
            try FileManager.default.trashItem(at: r.url, resultingItemURL: nil)
        } catch {
            return error.localizedDescription
        }
        refresh()
        return nil
    }


    static func revealInFinder(_ r: Recording) { NSWorkspace.shared.activateFileViewerSelecting([r.url]) }

    static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    /// 跟介面語言一致（介面是中文就用中文日期），不跟系統地區走。
    static let uiLocale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = uiLocale
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// 播放位置：無條件捨去到秒（跟上方大計時一致）。
    static func positionText(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func durationText(_ t: TimeInterval?) -> String {
        guard let t else { return "—" }
        let s = Int(t.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
