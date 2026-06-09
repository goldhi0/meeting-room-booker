import Foundation

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}

/// 사용자가 선택한 캘린더 ID 등을 저장하는 간단한 설정 저장소.
/// ~/Library/Application Support/MeetingRoomBooker/settings.json
enum Settings {
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingRoomBooker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }()

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }
    private static func store(_ dict: [String: String]) {
        if let data = try? JSONEncoder().encode(dict) { try? data.write(to: url) }
    }

    static var selectedCalendarId: String? {
        get { load()["selectedCalendarId"] }
        set {
            var d = load()
            d["selectedCalendarId"] = newValue
            store(d)
        }
    }
}

/// application/x-www-form-urlencoded 본문 인코딩.
func formEncode(_ params: [String: String]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return params.map { key, value in
        let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(k)=\(v)"
    }.joined(separator: "&")
}

/// HTTP 2xx가 아니면 본문을 포함한 에러를 던진다.
func checkResponse(_ resp: URLResponse, _ data: Data) throws {
    guard let http = resp as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else {
        let body = String(data: data, encoding: .utf8) ?? ""
        throw AppError.message("HTTP \(http.statusCode): \(body)")
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
