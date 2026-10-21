import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security

/// Osmi 登入（Supabase Auth，PKCE）。使用者按「讓Osmi聽寫逐字稿」且還沒登入時，才會出現登入視窗。
/// Google／Apple 都走系統的網頁登入視窗（ASWebAuthenticationSession，不內嵌網頁、不取得密碼）；
/// 回來時拿到 access／refresh token，存進 Keychain，之後直接用；快過期就用 refresh token 換新的。
/// ⛔ 只有使用者按下登入才會連網；登入狀態只留在本機 Keychain。
@MainActor
final class OsmiAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum Provider: String { case google, apple }

    /// Osmi 的 Supabase 專案（公開值，與 meeting.bookai.com/config 回傳的相同）。
    static let supabaseURL = URL(string: "https://daylxvqiolubdsyuqkvk.supabase.co")!
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRheWx4dnFpb2x1YmRzeXVxa3ZrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODkwMDg5ODgsImV4cCI6MjEwNDU4NDk4OH0.Xr1cWJI4-UBqlB-PGlr0gJ2tZ79YFs_WbP5ckj9auy4"
    static let callbackScheme = "audiomemo"
    static let redirectURL = "audiomemo://auth"

    struct Session: Codable { var access: String; var refresh: String; var expiresAt: Date }

    enum AuthError: LocalizedError {
        case cancelled, noCode, exchangeFailed(Int), badResponse
        var errorDescription: String? {
            switch self {
            case .cancelled: return L("osmi.login.cancelled")
            case .noCode, .badResponse: return L("osmi.login.badResponse")
            case .exchangeFailed(let c): return String(format: L("upload.httpError"), c)
            }
        }
    }

    private var webSession: ASWebAuthenticationSession?
    private static let keychainService = "com.bookai.audiomemo.osmi"
    private static let keychainAccount = "session"

    var hasSession: Bool { Self.load() != nil }

    // MARK: 登入

    func signIn(_ provider: Provider) async throws {
        let verifier = Self.randomURLSafe(64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var comps = URLComponents(url: Self.supabaseURL.appendingPathComponent("auth/v1/authorize"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "provider", value: provider.rawValue),
            URLQueryItem(name: "redirect_to", value: Self.redirectURL),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
        ]
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: comps.url!, callbackURLScheme: Self.callbackScheme) { url, error in
                if let error {
                    let c = (error as? ASWebAuthenticationSessionError)?.code
                    cont.resume(throwing: c == .canceledLogin ? AuthError.cancelled : error)
                } else if let url { cont.resume(returning: url) } else { cont.resume(throwing: AuthError.badResponse) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false     // 共用 Safari 的登入狀態：已登入 Google 就不必再選帳號
            self.webSession = s
            if !s.start() { cont.resume(throwing: AuthError.badResponse) }
        }
        webSession = nil
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else { throw AuthError.noCode }
        try await exchange(code: code, verifier: verifier)
    }

    private func exchange(code: String, verifier: String) async throws {
        var req = URLRequest(url: Self.supabaseURL.appendingPathComponent("auth/v1/token").appending(query: "grant_type", "pkce"))
        req.httpMethod = "POST"
        req.setValue(Self.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["auth_code": code, "code_verifier": verifier])
        try await store(from: req)
    }

    private func store(from req: URLRequest) async throws {
        let (data, resp) = try await Self.session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AuthError.exchangeFailed(status) }
        struct Tokens: Decodable { let access_token: String; let refresh_token: String; let expires_in: Double? }
        let t = try JSONDecoder().decode(Tokens.self, from: data)
        Self.save(Session(access: t.access_token, refresh: t.refresh_token,
                          expiresAt: Date().addingTimeInterval(t.expires_in ?? 3600)))
        DebugLog.write("osmi signed in")
    }

    // MARK: 取得可用的 token（快過期就換）

    /// 回傳可用的 access token；沒有登入或換不到就回 nil（呼叫端應顯示登入）。
    func accessToken() async -> String? {
        guard let s = Self.load() else { return nil }
        if s.expiresAt.timeIntervalSinceNow > 60 { return s.access }
        var req = URLRequest(url: Self.supabaseURL.appendingPathComponent("auth/v1/token").appending(query: "grant_type", "refresh_token"))
        req.httpMethod = "POST"
        req.setValue(Self.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": s.refresh])
        do {
            try await store(from: req)
            return Self.load()?.access
        } catch {
            DebugLog.write("osmi refresh failed: \(error.localizedDescription)")
            if case AuthError.exchangeFailed(let c) = error, c == 400 || c == 401 { signOut() }   // refresh 被拒＝要重新登入
            return nil
        }
    }

    func signOut() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: Self.keychainService,
                                kSecAttrAccount as String: Self.keychainAccount]
        SecItemDelete(q as CFDictionary)
        DebugLog.write("osmi signed out")
    }

    // MARK: Keychain

    private static func save(_ s: Session) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: keychainService,
                                kSecAttrAccount as String: keychainAccount]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    #if DEBUG
    /// 自動測試用（只在 Debug 建置）：放一組假的登入狀態，讓 -uploadTest 不用真的登入也能跑完上傳流程。
    static func debugStoreFakeSession() {
        save(Session(access: "fake-token", refresh: "fake-refresh", expiresAt: Date().addingTimeInterval(3600)))
    }
    #endif

    static func load() -> Session? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: keychainService,
                                kSecAttrAccount as String: keychainAccount,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    // MARK: 小工具

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral          // 不留 cookie、快取
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg)
    }()

    private static func randomURLSafe(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow() }
    }
}

private extension URL {
    func appending(query name: String, _ value: String) -> URL {
        var c = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: name, value: value)]
        return c.url!
    }
}
