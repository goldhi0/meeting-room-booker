# 회의실예약

맥 메뉴바에서 LGU+ 강남오피스 구글 캘린더에 회의실을 예약하는 앱.

## 요구 사항
- macOS 13+
- Xcode Command Line Tools: `xcode-select --install`

## 설치
```bash
git clone https://github.com/goldhi0/meeting-room-booker.git
cd meeting-room-booker

# OAuth 키 설정 (1회) — 아래 "OAuth 클라이언트 발급" 으로 본인 값 채우기
cp Sources/MeetingRoomBooker/Secrets.swift.example Sources/MeetingRoomBooker/Secrets.swift

./install.sh
```

## OAuth 클라이언트 발급 (1회, 본인 구글 계정)
`Secrets.swift` 에 넣을 clientID/secret 은 **각자 본인 구글 계정으로** 발급받으면 돼요. (무료, 5~10분)
1. https://console.cloud.google.com → 새 프로젝트 생성
2. **API 및 서비스 → 라이브러리 → "Google Calendar API" 사용 설정**
3. **OAuth 동의 화면** → User type "외부" → 앱 정보 입력 → 본인 이메일을 **테스트 사용자**로 추가
   (또는 **앱 게시(PUBLISH)** 하면 재로그인 주기 없음)
4. **사용자 인증 정보 → OAuth 클라이언트 ID → 애플리케이션 유형 "데스크톱 앱"** 생성
5. 발급된 **클라이언트 ID / 보안 비밀** 을 `Secrets.swift` 에 입력

> 첫 로그인 시 "확인되지 않은 앱 → 고급 → 계속" 경고는 정상(미검증). 본인만 쓰면 통과하면 됨.
- `~/Applications/회의실예약.app` 생성 후 실행돼요. (메뉴바 상주)
- 처음 열 때 경고가 뜨면 앱 **우클릭 → 열기**.
- 업데이트: `git pull && ./install.sh`

## 실행 / 사용
- 메뉴바 📅 아이콘 클릭 → **Google 로그인**(최초 1회) → 날짜·시간·회의실 선택 → 예약
- 종료/로그아웃: 팝오버 우측 **⋯ 메뉴**

## 개발용 실행 (빌드 후 바로 실행)
```bash
./run.sh
```
