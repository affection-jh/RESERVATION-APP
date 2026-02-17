# 캘린더 관련 코드 감사

## 1. 캘린더 역할 정리

| 파일 | 용도 |
|------|------|
| **calendar_screen.dart** | 예약 하기 화면 (멤버가 코스별 주차 캘린더에서 세션 선택 → 예약) |
| **drag_calendar_editor.dart** | 정기 예약 일정 편집, 비정기 일정 편집, 코스 등록 시 시간대 드래그 편집 |
| **compact_calendar_widget.dart** | 어드민 홈, 멤버 마이페이지(일정보기), 코스 상세, bulk move 슬롯 선택 |
| **abstract_calendar_widget.dart** | 코스 카드 내부용 미니 캘린더 (현재 사용처 확인 필요) |

---

## 2. 중복 코드

### 2.1 시간/날짜 파싱·포맷

- **`_parseTimeToMinutes(String time)`**  
  "HH:mm" → 분 단위 정수. 아래 파일마다 **동일 로직이 각각 private으로 존재**.
  - `calendar_screen.dart` (1곳)
  - `compact_calendar_widget.dart` (1곳)
  - `drag_calendar_editor.dart` (1곳)
  - `course_schedule_edit_screen.dart` (1곳)
  - `course_schedule_screen.dart` (1곳)
  - `weekly_override_schedule_screen.dart` (1곳)
  - `session_edit_bottom_sheet.dart` (시·분 인자 버전)
  - `session_slot_builder.dart` (static, private)
  - `reservation_service.dart` (다른 포맷 용도)
  - `reservation_utils.dart` (3곳)

- **`_formatDate(DateTime date)`**  
  "YYYY-MM-DD" 문자열. 다음 파일에 **각각 정의**.
  - `calendar_screen.dart`
  - `compact_calendar_widget.dart`
  - `session_slot_builder.dart` (static)
  - `reservation_service.dart`
  - `enrollment_detail_screen.dart`
  - `session_detail_screen.dart`
  - `admin_home_screen.dart`
  - `home_screen.dart`

- **`_startOfWeekMonday(DateTime date)`**  
  해당 주 월요일 00:00. 다음에 **중복**.
  - `calendar_screen.dart`
  - `compact_calendar_widget.dart`
  - `reservation_policy_engine.dart` (static)

**구현됨:** **`lib/utils/calendar_utils.dart`**  
- `CalendarUtils.parseTimeToMinutes(String time)`  
- `CalendarUtils.minutesToTimeString(int minutes)`  
- `CalendarUtils.formatDateYMD(DateTime date)`  
- `CalendarUtils.startOfWeekMonday(DateTime date)`  
- `CalendarUtils.weekStartFrom(DateTime referenceDate, int weekOffset)`  
위 위젯/서비스는 점진적으로 이 유틸만 참조하도록 교체하면 됨.

---

### 2.2 주차·요일 계산

- 이번 주 월요일 기준 `weekOffset`으로 주 시작일 계산하는 패턴이  
  `calendar_screen`, `compact_calendar_widget`, `weekly_override_schedule_screen`, `my_page_screen` 등에 **비슷하게 반복**됨.
- **권장:** `CalendarUtils.startOfWeekMonday` + `weekOffset` 조합을 공통 함수 하나로 (예: `getWeekStart(DateTime ref, int weekOffset)`) 제공.

---

### 2.3 세션 블록 UI (박스 디자인)

- **calendar_screen.dart**  
  `_buildSessionBlock`:  
  - `borderRadius: 8`, `boxShadow` 조건부,  
  - `blockColor` = 예약됨/잠김/가능에 따라 코스색·회색·opacity 조합,  
  - `textColor`/`iconColor` = 비활성 시 `textPrimary` 등.
- **compact_calendar_widget.dart**  
  - `_buildReservationSessionBlock` (일정보기): `borderRadius: 12`, 비슷한 shadow/색상 분기.  
  - `_buildSessionBlock` (어드민/코스상세): `borderRadius: 12`, `visuallyDisabled`/`opacity`/`blockColor` 분기.
- **drag_calendar_editor.dart**  
  `_buildSessionBlock`: 정기=회색, 비정기=코스색, `borderRadius: 8`, preview 시 opacity.
- **abstract_calendar_widget.dart**  
  세션 블록: `borderRadius: 6`, `course.colorValue.withOpacity(0.25)`.

**문제:**  
- “예약 가능 / 예약됨 / 잠김 / 처리중 / 정기 / 비정기” 등 **타입별 스타일이 파일마다 제각각** 정의됨.  
- borderRadius(6 vs 8 vs 12), shadow 유무, 색/투명도 규칙이 통일되어 있지 않음.

**구현됨:**  
- **`lib/widgets/session_block_style.dart`**  
  - `SessionBlockType` enum (available, reserved, locked, processing, regularSchedule, overrideSchedule, preview, courseDetail)  
  - `SessionBlockStyle.fromType(type, courseColor)` + `toBoxDecoration()`  
- 각 캘린더 위젯은 “이 블록의 타입 + 코스색”만 넘기고, 실제 `BoxDecoration`/`TextStyle`은 여기서 가져오도록 점진적으로 이전하면 됨.

---

## 3. 비즈니스 로직 vs UI 렌더링 분리

### 3.1 잘 분리된 부분

- **ReservationPolicyEngine.evaluateReservation**  
  예약 가능 여부·잠금 사유 등은 엔진에서 계산하고, UI는 결과만 사용.
- **ReservationSummaryProvider**  
  N/M, 정원, 날짜별 capacity는 프로바이더가 관리하고, 캘린더는 `sessionReservationsByKey` 등만 구독.
- **SessionSlotBuilder**  
  코스+오버라이드로 슬롯 목록 생성하는 로직이 유틸로 분리됨.

### 3.2 혼재된 부분

- **calendar_screen._buildSessionBlock**  
  - 블록 **한 번** 그리기 위해  
    `_getUserReservationForSession`, `enrollmentCanReserve`, `ReservationSummaryProvider` 조회,  
    `ReservationPolicyEngine.evaluateReservation`, `isBookingWeekOpened`까지 **전부 build 안에서** 수행.  
  - “이 셀의 상태(가능/예약됨/잠김/처리중)”를 계산하는 로직이 **위젯 build와 한 덩어리**.
- **compact_calendar_widget**  
  - `_buildSessionBlock` / `_buildReservationSessionBlock` 내부에서  
    eligibility, `isLocked`, `isFull`, `visuallyDisabled`, `opacity` 등을 **같은 메서드 안에서** 계산 후 바로 색/텍스트에 사용.  
  - “상태 계산”과 “그 상태를 어떤 색/폰트로 그릴지”가 분리되어 있지 않음.

**권장:**  
- “세션 셀 하나의 표시 상태”를 담는 **SessionCellState**(또는 SessionBlockViewModel) 같은 모델을 두고,  
  - **상태 계산**은 화면/프로바이더 레벨에서 한 번만 (예: `computeSessionCellState(course, session, date, ...)`) 수행.  
- **UI**는 `SessionCellState` + `SessionBlockType`(또는 state에 type 포함)만 받아서 **공통 세션 블록 위젯**으로 그리도록 분리.  
- 가능하면 `_buildSessionBlock` 안에서는 `Provider.of`/정책 호출을 하지 않고, “이미 계산된 state”만 받도록 정리.

---

## 4. 조잡한 코드 / 개선 포인트

1. **compact_calendar_widget.dart (3800줄 이상)**  
   - 한 파일에 “일정보기 / 어드민 홈 / 코스 상세 / adminSelectNewSlot” 등 **모든 모드**가 섞여 있음.  
   - `_usage` switch가 여러 곳에 반복되고, 블록 하나 그리는데도 분기가 매우 많음.  
   - **제안:**  
     - “주차/날짜/시간축 계산”, “슬롯 레이아웃”, “세션 블록 그리기”, “탭 가능 여부”를 **작은 클래스/함수나 mixin**으로 나누거나,  
     - 용도별로 **CompactCalendarForAdmin**, **CompactCalendarForUserWeek** 등으로 파일을 나누고 공통 부분만 공유.

2. **calendar_screen.dart**  
   - `_buildSessionBlock`이 매우 길고 (예약/취소/로그인 유도/스낵바 등) **onTap 처리와 블록 UI가 한 위젯에 함께** 있음.  
   - **제안:** onTap은 콜백으로 빼고, 블록은 “상태 + 공통 세션 블록 위젯”으로만 구성.

3. **drag_calendar_editor.dart**  
   - 포인터 이벤트/드래그와 세션 블록 그리기가 같은 파일에 있음.  
   - 블록 “디자인”만 본다면 **SessionBlockStyle**으로 빼고, 이 위젯은 “배치 + 제스처 + 드래그 데이터”에만 집중하도록 정리 가능.

4. **상수 분산**  
   - `_sessionPadding`, `_lineOffset`, `borderRadius` 값 등이 파일마다 하드코딩.  
   - **제안:** `SessionBlockStyle`(또는 `CalendarLayoutConstants`)에 한 번만 정의.

---

## 5. 세션 박스 디자인 타입별 정리 (제안)

아래는 “타입별로 어떻게 보여줄지”를 한 곳에서 관리하기 위한 제안 스펙이다.  
실제 구현은 `lib/widgets/calendar/session_block_style.dart`(및 필요 시 `SessionBlockPainter`/공통 위젯)에서 사용.

| 타입 | 용도 | 배경색 | 텍스트/아이콘 | 테두리/그림자 | 비고 |
|------|------|--------|----------------|----------------|------|
| **available** | 예약 가능 | 코스색 (불투명) | 흰색 | shadow 있음 | |
| **reserved** | 내 예약됨 | 코스색 0.4 opacity | textPrimary | shadow 없음 | |
| **locked** | 잠김(만석/정책/미오픈 등) | reservedGrey | textPrimary | shadow 없음 | |
| **processing** | 예약/취소/변경 중 | 코스색 또는 회색 0.45 | 흰색 + 로딩 | shadow 유무 통일 | |
| **regularSchedule** | 정기 일정 (편집 UI) | 회색 400 | 밝기에 따라 흑/백 | borderRadius 8 | DragCalendarEditor 정기 |
| **overrideSchedule** | 비정기 일정 (편집 UI) | 코스색 | 밝기에 따라 흑/백 | borderRadius 8 | DragCalendarEditor 비정기 |
| **preview** | 드래그 미리보기 | 코스색 0.3 | 동일 | shadow 없음 | |
| **courseDetail** | 코스 상세용 단순 블록 | 코스색 | 흰색 | borderRadius 12 | |

- **공통:**  
  - `borderRadius`: 8(편집) vs 12(일반 캘린더) 정도로 두 가지로 고정.  
  - `boxShadow`: “선택됨/가능”일 때만 주고, “비활성/예약됨/잠김”은 동일 규칙으로 제거 또는 약하게.

이렇게 타입을 정의해 두면,  
- calendar_screen / compact_calendar / drag_calendar_editor는  
  “이 셀의 상태 → SessionBlockType”만 결정하고,  
- 실제 `Container`/`BoxDecoration`/`TextStyle`은 **SessionBlockStyle.fromType(type, courseColor)** 같은 식으로 한 곳에서만 생성하면 됨.

---

## 6. 작업 우선순위 제안

1. **공통 유틸 추가**  
   `parseTimeToMinutes`, `formatDateYMD`, `startOfWeekMonday`(또는 `getWeekStart`)를 `calendar_utils.dart`(또는 timezone_utils)에 두고,  
   calendar_screen / compact_calendar_widget / drag_calendar_editor / weekly_override / course_schedule* / session_slot_builder 등에서 **점진적으로** 이걸 쓰도록 교체.

2. **SessionBlockStyle 도입**  
   - `SessionBlockType` enum + `SessionBlockStyle`(색, borderRadius, shadow, textColor 규칙) 정의.  
   - compact_calendar_widget의 `_buildSessionBlock` / `_buildReservationSessionBlock`에서 먼저 이 스타일을 참조하도록 리팩터.  
   - 이어서 calendar_screen, drag_calendar_editor의 블록도 동일 스타일을 쓰도록 통일.

3. **상태와 UI 분리**  
   - “세션 셀 상태”를 계산하는 함수/클래스를 하나 두고 (예: `SessionCellStateResolver` 또는 기존 Provider 확장),  
   - `_buildSessionBlock`은 “state + type → SessionBlockStyle → 위젯”만 담당하도록 단계적으로 분리.

4. **compact_calendar_widget 분할**  
   - 용도별로 파일을 나누거나, 최소한 “레이아웃 계산 / 그리드 그리기 / 세션 블록 그리기”를 별도 클래스나 함수 그룹으로 분리해 가독성과 테스트 가능성을 높이기.

이 순서로 진행하면 중복 제거와 “세션 박스 디자인 타입별 정의”가 동시에 정리된다.
