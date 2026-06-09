import Foundation
import Network
import AppKit
import CryptoKit

struct Tokens: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiry: Date
    var isExpired: Bool { Date() >= expiry.addingTimeInterval(-60) }
}

private struct TokenResponse: Codable {
    let access_token: String
    let expires_in: Int
    let refresh_token: String?
}

/// Google OAuth 2.0 (데스크톱 앱 / 루프백 + PKCE) 흐름.
final class GoogleAuth {
    static let shared = GoogleAuth()

    private let authBase = "https://accounts.google.com/o/oauth2/v2/auth"
    private let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private let storeURL: URL
    private var tokens: Tokens?
    private var pendingRedirect: String?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingRoomBooker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("tokens.json")
        if let data = try? Data(contentsOf: storeURL),
           let t = try? JSONDecoder().decode(Tokens.self, from: data) {
            tokens = t
        }
    }

    var isSignedIn: Bool { tokens?.refreshToken != nil }

    private func save() {
        if let t = tokens, let data = try? JSONEncoder().encode(t) {
            try? data.write(to: storeURL)
        }
    }

    /// 유효한 access token을 반환한다. 필요 시 갱신하거나 최초 로그인을 수행한다.
    func validAccessToken() async throws -> String {
        if let t = tokens, !t.isExpired { return t.accessToken }
        if let rt = tokens?.refreshToken {
            try await refresh(refreshToken: rt)
            return tokens!.accessToken
        }
        try await authorize()
        return tokens!.accessToken
    }

    func signIn() async throws { try await authorize() }

    /// 저장된 토큰을 삭제해 로그아웃한다. (계정 변경용)
    func signOut() {
        tokens = nil
        try? FileManager.default.removeItem(at: storeURL)
    }

    // MARK: - Authorization Code + PKCE

    private func authorize() async throws {
        let verifier = randomString(64)
        let challenge = codeChallenge(verifier)
        let (code, redirectURI) = try await runLoopback(challenge: challenge)
        try await exchange(code: code, verifier: verifier, redirectURI: redirectURI)
    }

    private func runLoopback(challenge: String) async throws -> (String, String) {
        try await withCheckedThrowingContinuation { cont in
            let listener: NWListener
            do {
                listener = try NWListener(using: .tcp)
            } catch {
                cont.resume(throwing: error); return
            }

            var finished = false
            func finish(_ result: Result<(String, String), Error>) {
                if finished { return }
                finished = true
                listener.cancel()
                cont.resume(with: result)
            }

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else { return }
                    let redirect = "http://127.0.0.1:\(port)"
                    self.pendingRedirect = redirect
                    var comps = URLComponents(string: self.authBase)!
                    comps.queryItems = [
                        .init(name: "client_id", value: AppConfig.clientID),
                        .init(name: "redirect_uri", value: redirect),
                        .init(name: "response_type", value: "code"),
                        .init(name: "scope", value: AppConfig.scope),
                        .init(name: "access_type", value: "offline"),
                        .init(name: "prompt", value: "consent"),
                        .init(name: "code_challenge", value: challenge),
                        .init(name: "code_challenge_method", value: "S256"),
                    ]
                    if let url = comps.url { NSWorkspace.shared.open(url) }
                case .failed(let error):
                    finish(.failure(error))
                default:
                    break
                }
            }

            listener.newConnectionHandler = { conn in
                conn.start(queue: .main)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                    if let data = data, let req = String(data: data, encoding: .utf8) {
                        let firstLine = req.split(separator: "\r\n").first.map(String.init) ?? ""
                        let parts = firstLine.split(separator: " ")
                        let path = parts.count >= 2 ? String(parts[1]) : "/"
                        let url = URL(string: "http://127.0.0.1" + path)
                        let items = url.flatMap {
                            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems
                        } ?? []
                        let code = items.first { $0.name == "code" }?.value
                        let oauthError = items.first { $0.name == "error" }?.value

                        let html = code != nil
                            ? "<html><body style='font-family:-apple-system;text-align:center;padding-top:80px'><h2>✅ 인증 완료</h2><p>이 창을 닫고 앱으로 돌아가세요.</p></body></html>"
                            : "<html><body style='font-family:-apple-system;text-align:center;padding-top:80px'><h2>⚠️ 인증 실패</h2></body></html>"
                        let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(html.utf8.count)\r\n\r\n\(html)"
                        conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })

                        let redirect = self.pendingRedirect ?? "http://127.0.0.1"
                        if let code = code {
                            finish(.success((code, redirect)))
                        } else {
                            finish(.failure(AppError.message("OAuth 오류: \(oauthError ?? "code 없음")")))
                        }
                    } else if let error = error {
                        finish(.failure(error))
                    }
                }
            }

            listener.start(queue: .main)
        }
    }

    private func exchange(code: String, verifier: String, redirectURI: String) async throws {
        let body = [
            "code": code,
            "client_id": AppConfig.clientID,
            "client_secret": AppConfig.clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ]
        let tr = try await postToken(body)
        tokens = Tokens(
            accessToken: tr.access_token,
            refreshToken: tr.refresh_token,
            expiry: Date().addingTimeInterval(TimeInterval(tr.expires_in))
        )
        save()
    }

    private func refresh(refreshToken: String) async throws {
        let body = [
            "client_id": AppConfig.clientID,
            "client_secret": AppConfig.clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        let tr = try await postToken(body)
        tokens = Tokens(
            accessToken: tr.access_token,
            refreshToken: tr.refresh_token ?? refreshToken,
            expiry: Date().addingTimeInterval(TimeInterval(tr.expires_in))
        )
        save()
    }

    private func postToken(_ body: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode(body).data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkResponse(resp, data)
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: - PKCE helpers

    private func randomString(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var s = ""
        for _ in 0..<n { s.append(chars.randomElement()!) }
        return s
    }

    private func codeChallenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }
}
