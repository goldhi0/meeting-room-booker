import Foundation

private struct CalendarListResponse: Codable {
    struct Item: Codable {
        let id: String
        let summary: String?
        let primary: Bool?
        let accessRole: String?
    }
    let items: [Item]
}

private struct EventsResponse: Codable {
    struct When: Codable { let dateTime: String?; let date: String? }
    struct Person: Codable { let email: String?; let `self`: Bool? }
    struct Item: Codable {
        let id: String?
        let summary: String?
        let colorId: String?
        let start: When?
        let end: When?
        let creator: Person?
        let organizer: Person?
    }
    let items: [Item]
}

final class GoogleCalendarService {
    static let shared = GoogleCalendarService()

    /// 로그인 계정이 접근 가능한 모든 캘린더(권한 등급 포함)를 가져온다.
    func listCalendars() async throws -> [CalendarInfo] {
        let token = try await GoogleAuth.shared.validAccessToken()
        var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
        comps.queryItems = [.init(name: "maxResults", value: "250")]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkResponse(resp, data)
        let list = try JSONDecoder().decode(CalendarListResponse.self, from: data)
        return list.items.map {
            CalendarInfo(id: $0.id, summary: $0.summary ?? $0.id,
                         isPrimary: $0.primary ?? false, accessRole: $0.accessRole ?? "reader")
        }
    }

    /// 선택한 캘린더에서 특정 날짜(하루)의 예약을 가져온다. 시작 시간 순 정렬.
    func listEvents(calendarId: String, day: Date) async throws -> [BookedEvent] {
        let token = try await GoogleAuth.shared.validAccessToken()
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: day)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay

        // timeMin/timeMax는 UTC "Z" 형식으로 보낸다. (로컬 오프셋 "+09:00"의 "+"가
        // URL 쿼리에서 공백으로 해석돼 400을 일으키는 문제 회피)
        let outFmt = ISO8601DateFormatter()
        outFmt.formatOptions = [.withInternetDateTime]
        outFmt.timeZone = TimeZone(identifier: "UTC")

        let encoded = calendarId.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? calendarId
        var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(encoded)/events")!
        comps.queryItems = [
            .init(name: "timeMin", value: outFmt.string(from: startOfDay)),
            .init(name: "timeMax", value: outFmt.string(from: endOfDay)),
            .init(name: "singleEvents", value: "true"),
            .init(name: "orderBy", value: "startTime"),
            .init(name: "maxResults", value: "2500"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkResponse(resp, data)
        let parsed = try JSONDecoder().decode(EventsResponse.self, from: data)

        // 이벤트의 dateTime은 "+09:00" 오프셋을 그대로 파싱 (초 단위 소수 유무 모두 대응)
        let parseFmt = ISO8601DateFormatter()
        parseFmt.formatOptions = [.withInternetDateTime]
        let parseFmtFrac = ISO8601DateFormatter()
        parseFmtFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        dateOnly.timeZone = TimeZone.current

        func parse(_ w: EventsResponse.When?) -> Date? {
            guard let w = w else { return nil }
            if let dt = w.dateTime { return parseFmt.date(from: dt) ?? parseFmtFrac.date(from: dt) }
            if let d = w.date { return dateOnly.date(from: d) }   // 종일 일정
            return nil
        }
        func splitRoom(_ summary: String) -> (String?, String) {
            if summary.hasPrefix("["), let close = summary.firstIndex(of: "]") {
                let room = String(summary[summary.index(after: summary.startIndex)..<close])
                let rest = summary[summary.index(after: close)...].trimmingCharacters(in: .whitespaces)
                return (room, rest)
            }
            return (nil, summary)
        }

        return parsed.items.compactMap { item -> BookedEvent? in
            guard let s = parse(item.start), let e = parse(item.end) else { return nil }
            let summary = item.summary ?? "(제목 없음)"
            let (room, title) = splitRoom(summary)
            return BookedEvent(
                id: item.id ?? UUID().uuidString,
                room: room,
                title: title.isEmpty ? summary : title,
                start: s, end: e,
                colorId: item.colorId,
                creatorEmail: item.creator?.email
            )
        }
        .sorted { $0.start < $1.start }
    }

    /// 선택한 캘린더에 예약 이벤트를 생성한다. summary는 호출부에서 조합한 전체 제목.
    func createBooking(calendarId: String, summary: String, colorId: String, start: Date, end: Date) async throws {
        let token = try await GoogleAuth.shared.validAccessToken()
        let encoded = calendarId.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? calendarId
        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encoded)/events")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        fmt.timeZone = TimeZone.current
        let tz = TimeZone.current.identifier

        let event: [String: Any] = [
            "summary": summary,
            "colorId": colorId,
            "start": ["dateTime": fmt.string(from: start), "timeZone": tz],
            "end": ["dateTime": fmt.string(from: end), "timeZone": tz],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: event)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkResponse(resp, data)
    }

    /// 선택한 캘린더에서 예약 이벤트 1건을 삭제한다. (내가 만든 예약만 호출할 것)
    func deleteBooking(calendarId: String, eventId: String) async throws {
        let token = try await GoogleAuth.shared.validAccessToken()
        let encCal = calendarId.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? calendarId
        let encEvent = eventId.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? eventId
        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encCal)/events/\(encEvent)")!
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkResponse(resp, data)
    }
}
