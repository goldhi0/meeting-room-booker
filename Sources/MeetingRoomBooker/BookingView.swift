import SwiftUI
import AppKit

/// 강남오피스 캘린더에 대한 로그인 계정의 접근 상태.
enum CalendarAccess {
    case loading    // 확인 중
    case ok         // 편집 가능 → 예약 화면
    case readOnly   // 조회만 가능 → 편집 권한 요청 안내
    case notFound   // 공유 안 됨 → 공유 요청 안내
}

@MainActor
final class BookingViewModel: ObservableObject {
    @Published var signedIn: Bool = GoogleAuth.shared.isSignedIn
    @Published var access: CalendarAccess = .loading
    @Published var targetCalendarId: String = ""
    @Published var myEmail: String = ""   // 로그인 계정 이메일(primary 캘린더 id) — 내 예약 판별

    @Published var selectedRoom: Room? = nil   // 기본 선택 없음 — 사용자가 직접 회의실을 골라야 예약 가능
    @Published var team: String = ""
    @Published var title: String = ""
    @Published var date: Date = Date()
    @Published var startMinutes: Int = 10 * 60   // 자정 기준 분 (10:00)
    @Published var durationMinutes: Int = 60

    /// 08:00 ~ 19:30, 30분 간격 시작 시간 슬롯.
    /// 예약 현황 타임라인이 20:00까지만 표시되므로, 30분 예약이 정확히 20:00에 끝나도록
    /// 선택 가능한 마지막 시작 시각을 19:30으로 둔다.
    let timeSlots: [Int] = Array(stride(from: 8 * 60, through: 19 * 60 + 30, by: 30))
    static func slotLabel(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }

    @Published var status: String = ""
    @Published var isBusy: Bool = false

    @Published var dayEvents: [BookedEvent] = []
    @Published var loadingEvents: Bool = false

    private var didInitDefaults = false      // 시작 시간 기본값 1회 설정 가드
    private var didAutoSelectRoom = false     // 기본 회의실 자동 선택 1회 가드

    let durations: [Int] = [30, 60, 90, 120]
    var statusIsError: Bool { status.hasPrefix("⚠️") }

    /// 선택한 회의실이 고른 시간대에 이미 예약돼 있으면 그 예약을 반환. (회의실 미선택 시 nil)
    /// "대회의실 전체 ↔ A/B" 처럼 서로 포함 관계인 방의 예약도 겹침으로 본다.
    var conflict: BookedEvent? {
        guard let room = selectedRoom else { return nil }
        let blockers = AppConfig.blockedRoomNames(for: room.name)
        let s = combinedStart()
        let e = s.addingTimeInterval(TimeInterval(durationMinutes * 60))
        return dayEvents.first { ev in
            guard let r = ev.room, blockers.contains(r) else { return false }
            return ev.start < e && s < ev.end
        }
    }

    /// 예약 버튼 활성화 조건: 회의실 선택됨 + 겹침 없음 + 권한 OK + 진행 중 아님.
    var canBook: Bool {
        !isBusy && selectedRoom != nil && conflict == nil && !targetCalendarId.isEmpty
    }

    /// 현재 선택한 날짜·시간·길이 기준으로 해당 회의실이 비어 있는지.
    /// 포함 관계(대회의실 전체 ↔ A/B)인 방이 점유돼 있어도 사용 불가로 본다.
    func isRoomAvailable(_ room: Room) -> Bool {
        let blockers = AppConfig.blockedRoomNames(for: room.name)
        let s = combinedStart()
        let e = s.addingTimeInterval(TimeInterval(durationMinutes * 60))
        return !dayEvents.contains { ev in
            guard let r = ev.room, blockers.contains(r) else { return false }
            return ev.start < e && s < ev.end
        }
    }

    /// 타임라인에 그릴 제안 시간대(분).
    var proposedStartMinute: Int { startMinutes }
    var proposedEndMinute: Int { startMinutes + durationMinutes }

    private static let hm: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "HH:mm"; return f
    }()

    private func combinedStart() -> Date {
        let cal = Calendar.current
        let d = cal.dateComponents([.year, .month, .day], from: date)
        var c = DateComponents()
        c.year = d.year; c.month = d.month; c.day = d.day
        c.hour = startMinutes / 60; c.minute = startMinutes % 60
        return cal.date(from: c) ?? date
    }

    /// 만들어질 일정 제목 미리보기: "[회의실][팀] 제목" (팀이 비면 "[회의실] 제목")
    var composedTitle: String {
        let t = title.trimmingCharacters(in: .whitespaces)
        let tm = team.trimmingCharacters(in: .whitespaces)
        let teamPart = tm.isEmpty ? "" : "[\(tm)]"
        let roomName = selectedRoom?.name ?? "회의실"
        return "[\(roomName)]\(teamPart) \(t.isEmpty ? "회의" : t)"
    }

    /// "10:00 ~ 11:00" 형태의 시작~종료.
    var rangeText: String {
        let s = combinedStart()
        let e = s.addingTimeInterval(TimeInterval(durationMinutes * 60))
        return "\(Self.hm.string(from: s)) ~ \(Self.hm.string(from: e))"
    }

    // MARK: - Auth & calendars

    func onAppear() {
        // 처음 열 때만 시작 시간을 '지금 기준 가장 가까운 미래 슬롯'으로 맞춘다.
        // (메뉴바 팝오버는 다시 열 때마다 onAppear가 불리므로 1회만 적용해 사용자의 이후 선택을 보존)
        if !didInitDefaults {
            didInitDefaults = true
            startMinutes = Self.nearestFutureSlot(timeSlots, now: Date())
        }
        if signedIn { resolveAccess() }
    }

    /// 슬롯들 중 '지금 이후'의 가장 빠른 시작 시각. 오늘 남은 슬롯이 없으면 마지막 슬롯.
    static func nearestFutureSlot(_ slots: [Int], now: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return slots.first(where: { $0 >= m }) ?? slots.last ?? slots.first ?? 0
    }

    /// 첫 예약 현황 로드 후, 그 시간에 가능한 첫 회의실을 기본 선택한다. (1회)
    private func autoSelectRoomIfNeeded() {
        guard !didAutoSelectRoom else { return }
        didAutoSelectRoom = true
        if selectedRoom == nil {
            selectedRoom = AppConfig.rooms.first { isRoomAvailable($0) }
        }
    }

    func signIn() {
        isBusy = true
        status = "로그인 창을 여는 중…"
        Task { @MainActor in
            do {
                try await GoogleAuth.shared.signIn()
                signedIn = true
                status = ""
                isBusy = false
                resolveAccess()
            } catch {
                status = "⚠️ 로그인 실패: " + error.localizedDescription
                isBusy = false
            }
        }
    }

    /// 다른 계정으로 다시 로그인하기 위해 로그아웃.
    func signOut() {
        GoogleAuth.shared.signOut()
        signedIn = false
        access = .loading
        targetCalendarId = ""
        myEmail = ""
        dayEvents = []
        status = ""
    }

    /// 강남오피스 캘린더 접근 권한을 확인하고 상태를 정한다.
    func resolveAccess() {
        access = .loading
        status = ""
        Task { @MainActor in
            do {
                let list = try await GoogleCalendarService.shared.listCalendars()
                myEmail = list.first(where: { $0.isPrimary })?.id ?? ""
                if let target = list.first(where: { $0.summary == AppConfig.requiredCalendarName }) {
                    if target.canWrite {
                        targetCalendarId = target.id
                        access = .ok
                        loadEvents()
                    } else {
                        access = .readOnly
                    }
                } else {
                    access = .notFound
                }
            } catch {
                access = .notFound
                status = "⚠️ 캘린더 확인 실패: " + error.localizedDescription
            }
        }
    }

    /// 고정 캘린더의 날짜별 예약 현황을 불러온다.
    func loadEvents() {
        guard !targetCalendarId.isEmpty else { dayEvents = []; return }
        let calId = targetCalendarId
        let day = date
        loadingEvents = true
        Task { @MainActor in
            do {
                dayEvents = try await GoogleCalendarService.shared.listEvents(calendarId: calId, day: day)
                autoSelectRoomIfNeeded()
            } catch {
                dayEvents = []
                status = "⚠️ 예약 현황 로드 실패: " + error.localizedDescription
            }
            loadingEvents = false
        }
    }

    func shiftDay(_ delta: Int) {
        if let d = Calendar.current.date(byAdding: .day, value: delta, to: date) {
            date = d
            loadEvents()
        }
    }

    /// 일시를 '오늘 · 지금 기준 가장 가까운 미래 슬롯'으로 되돌린다.
    func resetToNow() {
        let now = Date()
        date = now
        startMinutes = Self.nearestFutureSlot(timeSlots, now: now)
        loadEvents()
    }

    /// 특정 회의실의 그 날 예약들.
    func events(forRoom name: String) -> [BookedEvent] {
        dayEvents.filter { $0.room == name }
    }

    /// 이벤트가 로그인 계정이 만든 내 예약인지.
    func isMine(_ ev: BookedEvent) -> Bool {
        guard !myEmail.isEmpty, let email = ev.creatorEmail else { return false }
        return email.caseInsensitiveCompare(myEmail) == .orderedSame
    }

    /// 로그인 계정이 만든 그 날의 내 예약들 (시작 시간 순).
    var myEvents: [BookedEvent] {
        dayEvents.filter { isMine($0) }.sorted { $0.start < $1.start }
    }

    /// 삭제 중인 예약 id (버튼 비활성/스피너 표시용).
    @Published var deletingId: String? = nil

    /// 내가 만든 예약 1건을 삭제한다.
    func deleteEvent(_ event: BookedEvent) {
        guard !targetCalendarId.isEmpty, isMine(event) else { return }
        let calId = targetCalendarId
        let eventId = event.id
        deletingId = eventId
        Task { @MainActor in
            do {
                try await GoogleCalendarService.shared.deleteBooking(calendarId: calId, eventId: eventId)
                status = ""   // 성공 알림 없이 목록 갱신으로 반영
                deletingId = nil
                loadEvents()
            } catch {
                status = "⚠️ 삭제 실패: " + error.localizedDescription
                deletingId = nil
            }
        }
    }

    /// 설정된 회의실 목록에 없는(또는 회의실명이 없는) 기타 예약들.
    var otherEvents: [BookedEvent] {
        let known = Set(AppConfig.rooms.map { $0.name })
        return dayEvents.filter { ev in
            guard let r = ev.room else { return true }
            return !known.contains(r)
        }
    }

    /// 선택한 날짜 라벨: "6월 8일 (월)"
    var dateLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 (E)"
        return f.string(from: date)
    }

    // MARK: - Booking

    func book() {
        guard !targetCalendarId.isEmpty else {
            status = "⚠️ 캘린더 접근 권한을 확인하세요."
            return
        }
        guard let room = selectedRoom else {
            status = "⚠️ 회의실을 선택하세요."
            return
        }
        let calId = targetCalendarId
        let start = combinedStart()
        let end = start.addingTimeInterval(TimeInterval(durationMinutes * 60))
        let summary = composedTitle
        isBusy = true
        status = "예약 중…"
        Task { @MainActor in
            do {
                try await GoogleCalendarService.shared.createBooking(
                    calendarId: calId, summary: summary, colorId: room.colorId, start: start, end: end
                )
                status = ""   // 성공 알림은 따로 띄우지 않고, '내 예약' 목록 갱신으로 대체
                title = ""
                // 방금 예약한 시간 다음 칸으로 시작시간 이동 → 자기 자신과 '겹침' 표시 방지 + 연속 예약 편의.
                // 마지막 슬롯(20:00)을 예약해도 23:00까지 이동을 허용해(슬롯 범위 밖이어도 OK)
                // 방금 만든 예약과 겹쳐 보이지 않게 한다.
                startMinutes = min(startMinutes + durationMinutes, 23 * 60)
                isBusy = false
                loadEvents()
            } catch {
                status = "⚠️ " + error.localizedDescription
                isBusy = false
            }
        }
    }
}

// MARK: - 토스 스타일 디자인 토큰

enum Theme {
    static let bg            = Color(hex: "F2F4F6")  // 연한 회색 배경
    static let card          = Color(hex: "FFFFFF")
    static let textPrimary   = Color(hex: "191F28")  // 거의 검정
    static let textSecondary = Color(hex: "8B95A1")  // 회색 텍스트
    static let blue          = Color(hex: "3182F6")  // 토스 블루
    static let blueSoft      = Color(hex: "E8F1FD")
    static let chipBg        = Color(hex: "EEF1F4")
    static let orange        = Color(hex: "FF8A00")
    static let orangeSoft    = Color(hex: "FFF1E0")
    static let track         = Color(hex: "EAEDF0")
}

extension View {
    /// 흰 카드 + 둥근 모서리 + 옅은 그림자 (토스 카드).
    func tossCard(_ pad: CGFloat = 16) -> some View {
        self
            .padding(pad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
            .shadow(color: Color.black.opacity(0.04), radius: 7, x: 0, y: 2)
    }
}

// MARK: - Main view (토스 스타일 단일 컬럼)

struct BookingView: View {
    @StateObject private var vm = BookingViewModel()
    @State private var showDatePopover = false

    private let roomColumns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        Group {
            if vm.signedIn { signedInLayout } else { signInLayout }
        }
        .onAppear { vm.onAppear() }
    }

    // MARK: layouts

    private var signInLayout: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            VStack(alignment: .leading, spacing: 14) {
                Text("간편하게 회의실을 예약하세요")
                    .font(.system(size: 16, weight: .bold)).foregroundColor(Theme.textPrimary)
                Text("Google 계정으로 로그인하면\n내 캘린더를 골라 바로 예약할 수 있어요.")
                    .font(.system(size: 13)).foregroundColor(Theme.textSecondary)
                primaryButton(vm.isBusy ? "로그인 중…" : "Google 로그인", color: Theme.blue) { vm.signIn() }
            }
            .tossCard()
            statusLabel
        }
        .padding(18)
        .frame(width: 360)
        .background(Theme.bg)
    }

    private var signedInLayout: some View {
        Group {
            if case .ok = vm.access { bookingScroll } else { infoScreen }
        }
        .frame(width: 380, height: 600)
        .background(Theme.bg)
    }

    private var bookingScroll: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                header
                scheduleCard
                timelineCard
                myBookingsCard
                roomCard
                titleCard
                primaryButton(bookTitle, color: Theme.blue, disabled: !vm.canBook) { vm.book() }
                statusLabel
            }
            .padding(16)
        }
    }

    // 권한 없음 / 확인 중 화면
    private var infoScreen: some View {
        VStack(spacing: 16) {
            header
            Spacer()
            Group {
                switch vm.access {
                case .loading:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("캘린더 권한 확인 중…").font(.system(size: 13)).foregroundColor(Theme.textSecondary)
                    }
                case .readOnly:
                    permissionCard(
                        title: "편집 권한이 필요해요",
                        message: "‘\(AppConfig.requiredCalendarName)’ 캘린더에 조회 권한만 있어요.\n예약하려면 관리자에게 편집(변경) 권한을 요청하세요."
                    )
                case .notFound:
                    permissionCard(
                        title: "캘린더 접근 권한이 없어요",
                        message: "‘\(AppConfig.requiredCalendarName)’ 캘린더가 이 계정에 공유돼 있지 않아요.\n관리자에게 캘린더 공유를 요청하세요."
                    )
                case .ok:
                    EmptyView()
                }
            }
            Spacer()
            if vm.access != .loading {
                VStack(spacing: 10) {
                    primaryButton("권한 다시 확인", color: Theme.blue) { vm.resolveAccess() }
                    Button(action: { vm.signOut() }) {
                        Text("다른 계정으로 로그인")
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            statusLabel
        }
        .padding(18)
    }

    private func permissionCard(title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 28)).foregroundColor(Theme.orange)
                .frame(width: 64, height: 64).background(Circle().fill(Theme.orangeSoft))
            Text(title).font(.system(size: 16, weight: .bold)).foregroundColor(Theme.textPrimary)
            Text(message)
                .font(.system(size: 13)).foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .tossCard(20)
    }

    // MARK: header

    /// Google 캘린더 웹 주소. 로그인 계정을 알면 authuser 로 그 계정을 지정해
    /// 브라우저가 다른(첫 번째) 계정으로 열지 않도록 한다.
    private var calendarWebURL: URL {
        var comps = URLComponents(string: "https://calendar.google.com/calendar/r")!
        if !vm.myEmail.isEmpty {
            comps.queryItems = [URLQueryItem(name: "authuser", value: vm.myEmail)]
        }
        return comps.url!
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text("회의실 예약")
                    .font(.system(size: 19, weight: .bold)).foregroundColor(Theme.textPrimary)
                Text(AppConfig.requiredCalendarName)
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.blue)
            }
            Spacer()
            Link(destination: calendarWebURL) {
                Image(systemName: "safari")
                    .font(.system(size: 13, weight: .bold)).foregroundColor(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.chipBg))
            }
            .buttonStyle(.plain)
            .help(vm.myEmail.isEmpty ? "Google 캘린더 웹에서 열기"
                                     : "Google 캘린더 웹에서 열기 (\(vm.myEmail))")
            Menu {
                if vm.signedIn {
                    Button("로그아웃 / 계정 변경") { vm.signOut() }
                    Divider()
                }
                Button("앱 종료") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .bold)).foregroundColor(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.chipBg))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 2)
    }

    // MARK: schedule

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                sectionTitle("일시")
                Spacer()
                Button(action: { vm.resetToNow() }) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }.buttonStyle(.plain).help("오늘·현재 시각으로")
            }
            dateRow
            timePills
            durationSegmented
        }
        .tossCard()
    }

    private var dateRow: some View {
        HStack(spacing: 10) {
            Button(action: { showDatePopover = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar").font(.system(size: 12)).foregroundColor(Theme.blue)
                    Text(vm.dateLabel).font(.system(size: 15, weight: .bold)).foregroundColor(Theme.textPrimary)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.textSecondary)
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDatePopover, arrowEdge: .bottom) {
                DatePicker("", selection: $vm.date, displayedComponents: .date)
                    .datePickerStyle(.graphical).labelsHidden().padding(12)
                    .onChange(of: vm.date) { _ in vm.loadEvents() }
            }
            Spacer(minLength: 0)
            navButton("chevron.left") { vm.shiftDay(-1) }
            navButton("chevron.right") { vm.shiftDay(1) }
        }
    }

    private func navButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold)).foregroundColor(Theme.textPrimary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.chipBg))
        }
        .buttonStyle(.plain)
    }

    private var timePills: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(vm.timeSlots, id: \.self) { (m: Int) in
                        let sel = m == vm.startMinutes
                        Text(BookingViewModel.slotLabel(m))
                            .font(.system(size: 13, weight: sel ? .bold : .medium))
                            .foregroundColor(sel ? .white : Theme.textPrimary)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(sel ? Theme.blue : Theme.chipBg))
                            .id(m)
                            .onTapGesture { vm.startMinutes = m }
                    }
                }
                .padding(.vertical, 1)
            }
            .onAppear { proxy.scrollTo(vm.startMinutes, anchor: .center) }
        }
    }

    private var durationSegmented: some View {
        HStack(spacing: 4) {
            ForEach(vm.durations, id: \.self) { (d: Int) in
                let sel = d == vm.durationMinutes
                Text("\(d)분")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(sel ? Theme.blue : Theme.textSecondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(sel ? Color.white : Color.clear)
                            .shadow(color: sel ? Color.black.opacity(0.06) : .clear, radius: 2, y: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { vm.durationMinutes = d }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.track))
    }

    // MARK: timeline

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                sectionTitle("예약 현황")
                if vm.loadingEvents { ProgressView().controlSize(.small) }
                Spacer()
                if vm.dayEvents.isEmpty && !vm.loadingEvents {
                    Text("예약 없음").font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                }
                Button(action: { vm.loadEvents() }) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }.buttonStyle(.plain).help("새로고침")
            }
            DayTimelineView(vm: vm)
        }
        .tossCard()
    }

    // MARK: my bookings

    private var myBookingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                sectionTitle("내 예약")
                if !vm.myEvents.isEmpty {
                    Text("\(vm.myEvents.count)건").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.blue)
                }
                Spacer()
            }
            if vm.myEvents.isEmpty {
                Text("이 날 내가 만든 예약이 없어요")
                    .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 8) {
                    ForEach(vm.myEvents) { (ev: BookedEvent) in myBookingRow(ev) }
                }
            }
        }
        .tossCard()
    }

    private func myBookingRow(_ ev: BookedEvent) -> some View {
        let deleting = vm.deletingId == ev.id
        return HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 4).fill(ev.displayColor).frame(width: 5, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(ev.room.map { "[\($0)] \(ev.title)" } ?? ev.title)
                    .font(.system(size: 13, weight: .bold)).foregroundColor(Theme.textPrimary).lineLimit(1)
                Text(ev.timeText).font(.system(size: 11)).foregroundColor(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            Button(action: { vm.deleteEvent(ev) }) {
                if deleting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "F04452"))
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: "F04452").opacity(0.1)))
                }
            }
            .buttonStyle(.plain).disabled(vm.deletingId != nil).help("예약 삭제")
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.chipBg))
    }

    // MARK: rooms

    private var roomCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                sectionTitle("회의실")
                Text("이 시간 가능한 방만").font(.system(size: 11)).foregroundColor(Theme.textSecondary)
            }
            LazyVGrid(columns: roomColumns, spacing: 8) {
                ForEach(AppConfig.rooms) { (room: Room) in roomChip(room) }
            }
        }
        .tossCard()
    }

    private func roomChip(_ room: Room) -> some View {
        let available = vm.isRoomAvailable(room)
        let isSelected = room == vm.selectedRoom
        return Button(action: { if available { vm.selectedRoom = room } }) {
            HStack(spacing: 7) {
                Circle().fill(room.displayColor).frame(width: 11, height: 11).opacity(available ? 1 : 0.3)
                Text(room.name)
                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                    .foregroundColor(available ? (isSelected ? Theme.blue : Theme.textPrimary) : Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !available {
                    Text("예약됨").font(.system(size: 9, weight: .semibold)).foregroundColor(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(isSelected ? Theme.blueSoft : Theme.chipBg.opacity(available ? 1 : 0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(isSelected ? Theme.blue : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
            .opacity(available ? 1 : 0.6)
        }
        .buttonStyle(.plain).disabled(!available)
    }

    // MARK: title

    private var titleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 9) {
                sectionTitle("팀")
                tossField("예: 디제플", text: $vm.team)
            }
            VStack(alignment: .leading, spacing: 9) {
                sectionTitle("제목")
                tossField("예: 주간회의", text: $vm.title)
            }
        }
        .tossCard()
    }

    private func tossField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 11).fill(Theme.chipBg))
    }

    private var bookTitle: String {
        if vm.isBusy { return "예약 중…" }
        if vm.selectedRoom == nil { return "회의실을 선택하세요" }
        if vm.conflict != nil { return "이미 예약된 시간이에요" }
        return "예약하기"
    }

    // MARK: shared bits

    private func primaryButton(_ title: String, color: Color, disabled: Bool = false, _ action: @escaping () -> Void) -> some View {
        let off = vm.isBusy || disabled
        return Button(action: action) {
            HStack(spacing: 8) {
                if vm.isBusy { ProgressView().controlSize(.small).colorInvert() }
                Text(title).font(.system(size: 16, weight: .bold)).foregroundColor(.white)
            }
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(off ? color.opacity(0.4) : color))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return)
        .disabled(off)
    }

    @ViewBuilder
    private var statusLabel: some View {
        if !vm.status.isEmpty {
            Text(vm.status)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(vm.statusIsError ? Color(hex: "F04452") : Color(hex: "15803D"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .bold)).foregroundColor(Theme.textPrimary)
    }
}

// MARK: - Day timeline (회의실별 가로 막대 그래프)

struct DayTimelineView: View {
    @ObservedObject var vm: BookingViewModel
    @State private var hoveredID: String? = nil   // 커서 올린 예약 막대 (즉시 툴팁용)

    private let startMin = 8 * 60      // 08:00
    private let endMin = 20 * 60       // 20:00
    private let labelWidth: CGFloat = 62
    private let rowHeight: CGFloat = 20
    private var total: CGFloat { CGFloat(endMin - startMin) }
    private var ticks: [Int] { Array(stride(from: startMin, through: endMin, by: 2 * 60)) }

    private func x(_ minute: Int, _ width: CGFloat) -> CGFloat {
        let clamped = min(max(minute, startMin), endMin)
        return CGFloat(clamped - startMin) / total * width
    }

    // 선택한 날짜가 '오늘'이고 표시 범위(08:00~20:00) 안일 때만 현재 시각 세로선을 그린다.
    private var nowMinute: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    private var showNow: Bool {
        Calendar.current.isDateInToday(vm.date) && nowMinute >= startMin && nowMinute <= endMin
    }
    private let nowColor = Color(hex: "F04452")

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            axisRow
            ForEach(AppConfig.rooms) { (room: Room) in roomRow(room) }
            if !vm.otherEvents.isEmpty {
                Text("그 외 \(vm.otherEvents.count)건 (회의실명 없는 일정)")
                    .font(.system(size: 9)).foregroundColor(Theme.textSecondary).padding(.top, 2)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredID)
    }

    private var axisRow: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: labelWidth)
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach(ticks, id: \.self) { (m: Int) in
                        Text("\(m / 60)")
                            .font(.system(size: 8, weight: .medium)).foregroundColor(Theme.textSecondary)
                            .position(x: x(m, geo.size.width), y: 5)
                    }
                    if showNow {
                        Circle().fill(nowColor).frame(width: 5, height: 5)
                            .position(x: x(nowMinute, geo.size.width), y: 8)
                    }
                }
            }
            .frame(height: 11)
        }
    }

    private func roomRow(_ room: Room) -> some View {
        let evs = vm.events(forRoom: room.name)
        let isSelected = room == vm.selectedRoom
        return HStack(spacing: 6) {
            HStack(spacing: 4) {
                Circle().fill(room.displayColor).frame(width: 8, height: 8)
                Text(room.name)
                    .font(.system(size: 10, weight: isSelected ? .bold : .regular))
                    .foregroundColor(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(width: labelWidth, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { vm.selectedRoom = room }   // 회의실명 클릭 → 회의실 선택
            .help("\(room.name) 선택")

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(Theme.track)
                    ForEach(ticks, id: \.self) { (m: Int) in
                        Rectangle().fill(Color.white.opacity(0.7))
                            .frame(width: 1).offset(x: x(m, geo.size.width))
                    }
                    ForEach(evs) { (ev: BookedEvent) in
                        block(ev, geo.size.width, room.displayColor)
                    }
                    if showNow {
                        Rectangle().fill(nowColor)
                            .frame(width: 1.5, height: rowHeight)
                            .offset(x: x(nowMinute, geo.size.width))
                    }
                    if isSelected {
                        proposed(geo.size.width)
                    }
                    // 커서 올린 막대 위에 즉시 뜨는 제목 툴팁
                    if let ev = evs.first(where: { $0.id == hoveredID }) {
                        let cx = (x(ev.startMinuteOfDay, geo.size.width) + x(ev.endMinuteOfDay, geo.size.width)) / 2
                        tooltip(ev)
                            .position(x: min(max(cx, 0), geo.size.width), y: -14)
                            .zIndex(10)
                    }
                }
            }
            .frame(height: rowHeight)
        }
        // 툴팁이 위 행을 가리지 않고 위로 올라오도록, hover 중인 행을 앞으로
        .zIndex(evs.contains { $0.id == hoveredID } ? 1 : 0)
    }

    /// 막대 위에 뜨는 제목+시간 툴팁.
    private func tooltip(_ ev: BookedEvent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ev.room.map { "[\($0)] \(ev.title)" } ?? ev.title)
                .font(.system(size: 11, weight: .bold)).foregroundColor(.white)
            Text(ev.timeText)
                .font(.system(size: 10)).foregroundColor(.white.opacity(0.85))
            if ev.roomCorrected, let raw = ev.rawRoom {
                Text("✎ 원본 표기: [\(raw)] (오타 보정됨)")
                    .font(.system(size: 9)).foregroundColor(Color(hex: "FFD8A8"))
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.textPrimary))
        .shadow(color: Color.black.opacity(0.18), radius: 5, y: 2)
        .fixedSize()
        .allowsHitTesting(false)
    }

    private func block(_ ev: BookedEvent, _ width: CGFloat, _ color: Color) -> some View {
        let x0 = x(ev.startMinuteOfDay, width)
        let x1 = x(ev.endMinuteOfDay, width)
        let w = max(3, x1 - x0)
        return RoundedRectangle(cornerRadius: 5)
            .fill(color)
            .frame(width: w, height: rowHeight - 4)
            .offset(x: x0)
            .onHover { hovering in
                if hovering { hoveredID = ev.id }
                else if hoveredID == ev.id { hoveredID = nil }
            }
            .help("\(ev.timeText) \(ev.title)")
    }

    private func proposed(_ width: CGFloat) -> some View {
        let x0 = x(vm.proposedStartMinute, width)
        let x1 = x(vm.proposedEndMinute, width)
        let w = max(3, x1 - x0)
        let color: Color = vm.conflict != nil ? Theme.orange : Theme.blue
        return RoundedRectangle(cornerRadius: 5)
            .strokeBorder(color, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
            .frame(width: w, height: rowHeight)
            .offset(x: x0)
    }
}
