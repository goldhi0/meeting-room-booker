import Foundation

/// 앱 설정. 회의실/색상 매핑과 Google OAuth 클라이언트 정보를 여기서 관리한다.
enum AppConfig {
    /// 이 앱이 고정으로 사용하는 캘린더 이름. 회의실이 이 오피스 기준으로 구성돼 있어 고정한다.
    /// 로그인 계정이 이 캘린더에 접근 권한이 없으면 권한 요청 안내 화면을 띄운다. (띄어쓰기 주의)
    static let requiredCalendarName = "LGU+ 강남오피스"

    /// Google Cloud "데스크톱 앱" OAuth 클라이언트 정보. 값은 git에 올라가지 않는 Secrets.swift 에서 가져온다.
    /// (Secrets.swift.example 를 복사해 Secrets.swift 를 만들고 값을 채울 것)
    static let clientID = Secrets.clientID
    static let clientSecret = Secrets.clientSecret

    /// 캘린더 읽기 + 이벤트 생성 권한.
    static let scope = "https://www.googleapis.com/auth/calendar"

    /// 회의실 목록과 색상(Google colorId 1~11).
    static let rooms: [Room] = [
        Room(name: "소회의실",      colorId: "4"),  // 플라밍고 (연분홍 대체 — 확인 필요)
        Room(name: "중회의실A",     colorId: "2"),  // 세이지
        Room(name: "중회의실B",     colorId: "10"), // 바질
        Room(name: "대회의실A",     colorId: "7"),  // 공작
        Room(name: "대회의실B",     colorId: "9"),  // 블루베리
        Room(name: "대회의실 전체", colorId: "6"),  // 귤
    ]

    /// 한 회의실이 물리적으로 포함하는 하위 회의실.
    /// "대회의실 전체" = "대회의실A" + "대회의실B" → 셋은 동시에 쓸 수 없다.
    /// (A와 B는 서로 독립이라 겹치지 않는다.)
    static let roomContains: [String: Set<String>] = [
        "대회의실 전체": ["대회의실A", "대회의실B"],
    ]

    /// 주어진 회의실을 예약하면 함께 점유돼 사용할 수 없게 되는 모든 회의실 이름(자기 자신 포함).
    /// 즉, 이들 중 하나라도 예약돼 있으면 이 회의실은 그 시간에 예약할 수 없다.
    static func blockedRoomNames(for room: String) -> Set<String> {
        var names: Set<String> = [room]
        if let children = roomContains[room] { names.formUnion(children) }   // 내가 포함하는 방들
        for (parent, children) in roomContains where children.contains(room) {
            names.insert(parent)                                            // 나를 포함하는 상위 방
        }
        return names
    }

    /// 제목에서 뽑은 회의실명을 표준 회의실명으로 보정한다.
    /// 구글 캘린더에 직접 타이핑하다 생긴 오타("소희의실" → "소회의실")를 커버하기 위함.
    ///
    /// - 정확히 일치하면 그대로 반환.
    /// - 아니면 편집거리(Levenshtein)가 가장 가까운 회의실로 매칭하되,
    ///   거리가 임계값을 넘거나(너무 다름) 동률 후보가 둘 이상이면(애매함) 보정하지 않고 nil.
    ///   → "대회의실"(A/B 애매), "포커스룸"(너무 멀음) 같은 건 그대로 기타 일정으로 남는다.
    /// - 매칭 실패 시 nil 을 반환하므로, 호출부는 nil 이면 원래 이름을 유지하면 된다.
    static func canonicalRoom(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return nil }
        if rooms.contains(where: { $0.name == name }) { return name }   // 정확 일치

        // 임계값 안에 드는 후보들 수집 (회의실명 길이의 약 1/3, 최소 1글자까지 허용)
        let candidates: [(room: String, dist: Int)] = rooms.compactMap { room in
            let d = levenshtein(name, room.name)
            let threshold = max(1, Int((Double(room.name.count) * 0.34).rounded()))
            return d <= threshold ? (room.name, d) : nil
        }
        guard let minDist = candidates.map(\.dist).min() else { return nil }
        let closest = candidates.filter { $0.dist == minDist }
        return closest.count == 1 ? closest[0].room : nil   // 유일 최근접일 때만 보정
    }

    /// 두 문자열의 편집거리(삽입/삭제/치환 횟수). 한글은 글자(Character) 단위로 비교한다.
    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var curr = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            curr[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[t.count]
    }
}
