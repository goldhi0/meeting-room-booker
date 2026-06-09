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
}
