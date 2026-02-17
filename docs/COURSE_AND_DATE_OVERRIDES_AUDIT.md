# courseOverrides / dateCapacityOverrides 점검

## 1. courseOverrides (비정기 일정)

### 역할
- **정기 일정 외** 특정 날짜에만 있는 세션을 표현 (추가 세션 or 해당 주만 정기 취소).
- 예: "이번 주 수요일만 14:00 세션 추가", "다음 주 월요일 10:00 세션 취소".

### 사용처 (유효 사용)

| 구분 | 위치 | 용도 |
|------|------|------|
| **Flutter** | `FirestoreService` | `getCourseOverrides`, `streamCourseOverrides`, `getCourseOverridesByDate`, `upsertCourseOverride`(callable), `createCourseOverride`, `updateCourseOverride`, `deleteCourseOverride` |
| **Flutter** | `CourseProvider.subscribeToOverrides()` | 주차별 비정기 일정 구독 |
| **Flutter** | `calendar_screen.dart` | 캘린더에 비정기 세션 표시, 로딩 상태 |
| **Flutter** | `session_detail_screen.dart` | 세션 상세(비정기 포함) |
| **Flutter** | `weekly_override_schedule_screen.dart` | 주간 비정기 일정 편집 UI |
| **Functions** | `course_override.ts` | `upsertCourseOverride` → courseOverrides 문서 생성/수정/삭제 |
| **Functions** | `createReservation` | 정기 세션 없을 때 courseOverrides로 해당 날짜·시간 세션 존재 여부 및 capacity 확인 |
| **Functions** | `updateCourseSchedule` | 정기 일정 수정 시 courseOverrides와 요일·시간 겹침 검사 |
| **Functions** | 코스/플레이스 삭제 | 해당 placeId·courseId의 courseOverrides 정리 |

### 결론
- **필수 컬렉션.** 비정기 일정 기능의 단일 소스이며, 앱·Functions 전반에서 일관되게 사용됨.
- 제거하거나 대체할 계획 없음.

---

## 2. dateCapacityOverrides (날짜별 수용인원 오버라이드)

### 역할
- **특정 (sessionId, date)** 에만 다른 정원을 적용.
- 정기 세션의 기본 capacity는 그대로 두고, "해당 날짜만 10명으로 제한" 같은 설정.

### 사용처 (유효 사용)

| 구분 | 위치 | 용도 |
|------|------|------|
| **Flutter** | `FirestoreService` | `getCapacityOverride`, `setCapacityOverride`, `deleteCapacityOverride`, `watchDateCapacityOverrides` |
| **Flutter** | `calendar_screen.dart` | 날짜별 capacity 구독 후 셀에 반영 |
| **Flutter** | `compact_calendar_widget.dart` | 동일하게 날짜별 capacity 오버라이드 반영 |
| **Flutter** | `session_detail_screen.dart` | `_capacityOverride`로 해당 날짜 수용인원 표시/편집 |
| **Functions** | `getCapacityForDate()` | 예약 생성 시 해당 (sessionId, date)의 수용인원 결정 (오버라이드 우선) |
| **Functions** | `createReservation` | 정기 세션인 경우 dateCapacityOverrides 조회 후 capacity 사용 |
| **Functions** | 코스/플레이스 삭제 | 해당 placeId·courseId의 dateCapacityOverrides 정리 |

### Course 모델의 `dateCapacityOverrides` 필드
- `CourseSession.dateCapacityOverrides` (Map<DateTime, int>)는 **Place 문서에 저장되는 값이 아님**.
- 실제 저장소는 **dateCapacityOverrides 컬렉션** 하나뿐.
- 모델 필드는 UI/로직에서 "해당 세션 + 날짜별 정원"을 쓸 때 쓰는 **클라이언트 측 보조** 용도이며, 컬렉션과 중복 저장이 아님.

### 결론
- **필수 컬렉션.** 날짜별 수용인원 오버라이드의 단일 소스이며, 예약 생성·캘린더·세션 상세에서 일관되게 사용됨.
- 제거하거나 대체할 계획 없음.

---

## 3. 요약

| 컬렉션 | 필요 여부 | 비고 |
|--------|-----------|------|
| **courseOverrides** | ✅ 필요 | 비정기 일정의 단일 소스, 예약/정기 수정/캘린더/주간 편집에서 사용 |
| **dateCapacityOverrides** | ✅ 필요 | 날짜별 수용인원의 단일 소스, 예약/캘린더/세션 상세에서 사용 |

둘 다 **유효하게 사용 중**이며, 구조·사용처에 문제 없음. courseMembers처럼 제거할 레거시가 아님.
