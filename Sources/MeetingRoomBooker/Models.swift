import Foundation
import SwiftUI

struct Room: Identifiable, Hashable {
    let name: String
    let colorId: String
    var id: String { name }
    var displayColor: Color { GoogleColor.color(for: colorId) }
}

/// 사용자가 접근 가능한 Google 캘린더 한 개.
struct CalendarInfo: Identifiable, Hashable {
    let id: String
    let summary: String
    let isPrimary: Bool
    let accessRole: String   // owner / writer / reader / freeBusyReader

    /// 예약(이벤트 생성) 가능한 권한인지.
    var canWrite: Bool { accessRole == "owner" || accessRole == "writer" }
}

/// 캘린더에 이미 잡혀 있는 예약 1건 (선택한 날짜 기준).
struct BookedEvent: Identifiable, Hashable {
    let id: String
    let room: String?      // 제목의 "[회의실명]" 에서 추출 후 표준 회의실명으로 보정한 값 (없을 수 있음)
    let rawRoom: String?   // 보정 전, 제목에 실제로 적혀 있던 회의실명 (오타 표시용)
    let title: String
    let start: Date
    let end: Date
    let colorId: String?
    let creatorEmail: String?   // 이벤트를 만든 사람의 이메일 (내 예약 판별용)
    let creatorName: String?    // 이벤트를 만든 사람의 표시 이름 (있으면 이메일보다 우선 표시)
    let createdAt: Date?        // 이벤트가 실제로 생성된 시각 (중복 예약 시 선착순 판별용)

    /// 제목의 회의실명에 오타가 있어 표준 회의실명으로 보정됐는지.
    var roomCorrected: Bool {
        guard let room = room, let rawRoom = rawRoom else { return false }
        return room != rawRoom
    }

    /// 예약자 표시용 이름. displayName이 없으면 이메일의 "@" 앞부분을 사용.
    var creatorDisplay: String? {
        if let n = creatorName, !n.isEmpty { return n }
        if let e = creatorEmail, let at = e.firstIndex(of: "@") { return String(e[..<at]) }
        return creatorEmail
    }

    private static let hm: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "HH:mm"; return f
    }()
    private static let createdFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "yyyy년 M월 d일 HH:mm:ss"; return f
    }()

    var timeText: String { "\(Self.hm.string(from: start))~\(Self.hm.string(from: end))" }

    /// "2026년 7월 23일 14:02:07" 형태의 예약(생성) 시각.
    var createdAtText: String? {
        guard let createdAt = createdAt else { return nil }
        return Self.createdFmt.string(from: createdAt)
    }

    var startMinuteOfDay: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: start)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    var endMinuteOfDay: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: end)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return m == 0 ? 24 * 60 : m   // 자정 종료는 24:00으로
    }

    var displayColor: Color {
        if let room = room, let m = AppConfig.rooms.first(where: { $0.name == room }) {
            return m.displayColor
        }
        if let colorId = colorId { return GoogleColor.color(for: colorId) }
        return .gray
    }
}

/// Google Calendar 기본 이벤트 색상 팔레트 (colorId -> 근사 hex).
enum GoogleColor {
    static let palette: [String: String] = [
        "1": "7986CB",  // Lavender / 라벤더
        "2": "33B679",  // Sage / 세이지
        "3": "8E24AA",  // Grape / 포도
        "4": "E67C73",  // Flamingo / 플라밍고
        "5": "F6BF26",  // Banana / 바나나
        "6": "F4511E",  // Tangerine / 귤
        "7": "039BE5",  // Peacock / 공작
        "8": "616161",  // Graphite / 그래파이트
        "9": "3F51B5",  // Blueberry / 블루베리
        "10": "0B8043", // Basil / 바질
        "11": "D50000", // Tomato / 토마토
    ]
    static func color(for id: String) -> Color {
        guard let hex = palette[id] else { return .gray }
        return Color(hex: hex)
    }
}

extension Color {
    init(hex: String) {
        var h = hex
        if h.hasPrefix("#") { h.removeFirst() }
        let v = UInt64(h, radix: 16) ?? 0
        let r = Double((v >> 16) & 0xff) / 255.0
        let g = Double((v >> 8) & 0xff) / 255.0
        let b = Double(v & 0xff) / 255.0
        self = Color(red: r, green: g, blue: b)
    }
}
