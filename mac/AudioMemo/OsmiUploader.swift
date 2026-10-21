import AppKit
import Foundation

/// 「讓Osmi聽寫逐字稿」一鍵上傳：
/// 1. POST {base}/imports（不需登入）→ import_id、secret、upload_url（GCS resumable session）、claim_url
/// 2. PUT 整個檔案到 upload_url（顯示進度、可取消、失敗可重試）
/// 3. 用預設瀏覽器打開 claim_url：使用者在網頁登入（若尚未）後，Osmi 自動建立任務
/// ⛔ 只有使用者按下按鈕時才連網；其他時候 App 完全離線。
@MainActor
final class OsmiUploader: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing                 // 建立匯入
        case uploading(Double)         // 0…1
        case opening                   // 上傳完成，正在打開 Osmi
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var file: URL?
    /// 還沒登入 Osmi：畫面顯示登入視窗；登入完成後會接著上傳 pendingRecording。
    @Published var showLogin = false
    @Published var loginError: String?
    private(set) var pendingRecording: Recording?
    let auth = OsmiAuth()

    var isBusy: Bool {
        switch phase { case .preparing, .uploading, .opening: return true; default: return false }
    }

    /// 預設正式站；測試可用 `defaults write com.bookai.audiomemo osmiBaseURL https://meeting-dev.bookai.com`
    /// 或啟動參數 `-osmiBaseURL <網址>` 覆寫。
    static var baseURL: URL {
        if let s = UserDefaults.standard.string(forKey: "osmiBaseURL"), let u = URL(string: s), u.scheme != nil { return u }
        return URL(string: "https://meeting.bookai.com")!
    }

    private struct ImportResponse: Decodable {
        let import_id: String
        let secret: String
        let upload_url: String
        let claim_url: String
        let expires_at: String?
    }

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral          // 不留 cookie、快取
        cfg.timeoutIntervalForRequest = 60
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
    }()
    private var task: URLSessionTask?
    private var pending: ImportResponse?
    private var lastRecording: Recording?

    func start(_ r: Recording) {
        guard !isBusy else { return }
        guard auth.hasSession else { return needLogin(r) }
        lastRecording = r
        file = r.url
        pending = nil
        phase = .preparing
        Task { await createImport(r) }
    }

    /// 登入視窗的兩個按鈕（Google／Apple）。登入成功就接著上傳剛剛按下的那個錄音。
    func signIn(_ provider: OsmiAuth.Provider) {
        loginError = nil
        Task {
            do {
                try await auth.signIn(provider)
                showLogin = false
                if let r = pendingRecording { pendingRecording = nil; start(r) }
            } catch OsmiAuth.AuthError.cancelled {
                // 使用者自己關掉登入視窗：什麼都不做
            } catch {
                loginError = error.localizedDescription
            }
        }
    }

    func cancelLogin() {
        showLogin = false; loginError = nil; pendingRecording = nil
    }

    private func needLogin(_ r: Recording) {
        pendingRecording = r
        file = nil; phase = .idle
        loginError = nil
        showLogin = true
    }

    func retry() {
        guard case .failed = phase, let r = lastRecording else { return }
        if let p = pending, p.upload_url.isEmpty == false {
            phase = .uploading(0); upload(r.url, to: p)          // 匯入已建立：只重傳檔案
        } else {
            start(r)
        }
    }

    func cancel() {
        task?.cancel(); task = nil
        DebugLog.write("osmi upload cancelled")
        reset()
    }

    func reset() { phase = .idle; file = nil; pending = nil }

    private static func contentType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "flac": "audio/flac"
        case "aiff", "aif": "audio/aiff"
        default: "audio/mp4"
        }
    }

    private func createImport(_ r: Recording) async {
        let base = Self.baseURL
        guard let token = await auth.accessToken() else {
            if phase == .preparing { needLogin(r) }             // 登入已過期或取不到：重新登入後再上傳
            return
        }
        var req = URLRequest(url: base.appendingPathComponent("imports"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "filename": r.url.lastPathComponent,
            "size": r.size,
            "content_type": Self.contentType(r.url),
            "duration_s": r.duration ?? 0,
            "source": "audiomemo",
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await session.data(for: req)
            guard phase == .preparing else { return }             // 中途取消了
            if (resp as? HTTPURLResponse)?.statusCode == 401 {    // 伺服器不認這個登入：清掉重來
                auth.signOut()
                return needLogin(r)
            }
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return fail(String(format: L("upload.httpError"), (resp as? HTTPURLResponse)?.statusCode ?? 0))
            }
            let imp = try JSONDecoder().decode(ImportResponse.self, from: data)
            // 只接受同一個網站的 claim 網址（避免打開任意網址）
            guard let claim = URL(string: imp.claim_url), claim.host == base.host,
                  claim.scheme == "https" || claim.host == "127.0.0.1" || claim.host == "localhost",
                  URL(string: imp.upload_url)?.scheme != nil else {
                return fail(L("upload.badResponse"))
            }
            pending = imp
            DebugLog.write("osmi import \(imp.import_id) created")
            phase = .uploading(0)
            upload(r.url, to: imp)
        } catch {
            if phase == .preparing { fail(error.localizedDescription) }
        }
    }

    private func upload(_ file: URL, to imp: ImportResponse) {
        guard let url = URL(string: imp.upload_url) else { return fail(L("upload.badResponse")) }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(Self.contentType(file), forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600
        let t = session.uploadTask(with: req, fromFile: file)
        task = t
        t.resume()
    }

    private func finished(_ t: URLSessionTask, error: Error?) {
        guard t === task else { return }
        task = nil
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { return }
            return fail(error.localizedDescription)
        }
        guard let http = t.response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return fail(String(format: L("upload.httpError"), (t.response as? HTTPURLResponse)?.statusCode ?? 0))
        }
        guard let imp = pending, let claim = URL(string: imp.claim_url) else { return fail(L("upload.badResponse")) }
        phase = .opening
        DebugLog.write("osmi upload done \(imp.import_id)")
        if UserDefaults.standard.bool(forKey: "osmiNoOpen") {          // 自動測試：不開瀏覽器，只記錄
            DebugLog.write("osmi claim url (not opened): \(claim.absoluteString)")
        } else {
            NSWorkspace.shared.open(claim)
        }
        AppModel.shared.notices.post(.uploadDone(file: file?.lastPathComponent ?? ""))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if self?.phase == .opening { self?.reset() }
        }
    }

    private func fail(_ message: String) {
        DebugLog.write("osmi upload failed: \(message)")
        phase = .failed(message)
    }
}

extension OsmiUploader: URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                                totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let p = totalBytesExpectedToSend > 0 ? Double(totalBytesSent) / Double(totalBytesExpectedToSend) : 0
        Task { @MainActor in
            guard task === self.task else { return }
            self.phase = .uploading(min(1, p))
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in self.finished(task, error: error) }
    }
}
