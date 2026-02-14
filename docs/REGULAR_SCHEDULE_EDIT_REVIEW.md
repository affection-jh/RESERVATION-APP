# 정기일정 편집 로직 점검 요약

## 1. 클라이언트 (CourseScheduleEditScreen)

### 1.1 로드·초기화
- **진입 시**: `_loadSessions()`로 `widget.course.sessions` → `_daySessions`(요일별 SessionDraft), `_initialDaySessionsSnapshot` 복사.
- **예약 여부**: `watchReservedSessionIdsForCourse` 구독으로 `_reservedSessionIds` 실시간 반영 → `_hasReservationsForDay` / `_hasReservationsForSession`에서 사용.

### 1.2 세션 추가·수정 (SessionEditBottomSheet → onRegister)
- **단일 요일**
  - 추가: `_findOverlap(dayOfWeek, newStartTime, newEndTime)`으로 같은 요일 내 **정기 세션끼리** 겹침 검사 → 겹치면 스낵바, 미적용.
  - 수정: `_findOverlapInDay(..., excludeIndex)`로 **자기 자신 제외** 후 겹침 검사.
- **일괄 적용(bulkDays)**
  - 수정 모드: 각 bulkDay마다 기존 세션 인덱스 찾아 수정 후 `_findOverlapInDay` / 없으면 `_findOverlap`으로 겹침 검사.
  - 등록 모드: 각 bulkDay마다 `_findOverlap`으로 겹침 검사 후 추가.
- **참고**: 여기서의 겹침 검사는 **정기 세션만** 대상. 비정기(override) 겹침은 서버에서만 검사.

### 1.3 세션 삭제
- **예약 없음**: 바텀시트에서 삭제 → `_daySessions[dayOfWeek]`에서 해당 SessionDraft 제거.
- **예약 있음**: `_showBulkMoveOption` → 최근 4주 예약 조회 후 "일괄 취소" 확인 → `batchCancelReservations` 호출 후 `_deleteSession`(로컬에서 세션 제거).

### 1.4 요일 편집 (_showAddDayDialog)
- **요일 추가**: `tempSelectedDays`에 요일 추가 시 `_daySessions[day]`를 원본 복사 또는 `[]`로 설정.
- **요일 제거**: 선택 해제 시 `_daySessions.remove(day)`.
- **취소**: `originalDaySessionsCopy` / `originalSelectedDays` 기준으로 `_daySessions` 전부 복원.
- **예약 있는 요일**: `_hasReservationsForDay(day)`이면 해당 요일 해제(선택 해제) 불가(잠금).

### 1.5 변경 감지 (_hasChanges)
- **요일 추가/삭제**: `originalDays` vs `currentDays` 비교. 다르면 요일 변경으로 보고, **현재 남아 있는 모든 요일에 세션이 1개 이상 있어야** true (빈 요일 있으면 저장 버튼 비활성화).
- **요일 동일**: 요일별로 `originalSessions.length` vs `currentSessions.length`, 그리고 같은 인덱스의 startTime/endTime/capacity 비교. 하나라도 다르면 true.

### 1.6 저장 (_saveSessions)
- **빈 세션**: 전체 세션 0개면 확인 다이얼로그 후 진행.
- **요일 삭제**: 삭제되는 요일 중 “원래 세션이 있던 요일”이 있으면 확인 다이얼로그.
- **페이로드**: `_daySessions.entries` → `CourseSession` 리스트 생성(요일·시작/종료·정원). **빈 리스트인 요일은 세션 0개로 전달** (= 해당 요일 삭제).
- **서버 호출**: `updateCourseSchedule(placeId, courseId, sessions)`.
- **에러 처리**
  - `details.requiresBulkMove == true`: `dayOfWeek`, `startTime`으로 대상 세션 찾아 `_showBulkMoveOption` 호출.
  - 그 외(정기끼리 겹침, 비정기와 겹침 등): `e.message` 스낵바 표시.

---

## 2. 클라이언트 (SessionEditBottomSheet)

- **같은 요일 내 겹침**: `existingSessions` 기준 `_hasTimeConflict` / `_isTimeInConflict` (편집 시 자기 자신 제외).
- **등록/수정 완료 직전**: `_handleRegister()`에서 한 번 더 `_hasTimeConflict` 호출 → 겹치면 스낵바 후 `onRegister` 미호출.
- **일괄 적용**: `_shouldShowBulkUi()`로 “다른 요일에 같은 시간대 세션 없을 때”만 일괄 체크박스 노출.

---

## 3. 서버 (updateCourseSchedule)

### 3.1 검증 순서
1. **필수 파라미터**: placeId, courseId, sessions.
2. **세션 형식**: dayOfWeek(1–7), startTime/endTime(parseHHmm), capacity > 0.
3. **정기끼리 겹침**: 요일별로 정렬 후 같은 요일 내 시간 겹침 시 `failed-precondition: 세션 시간이 겹칩니다.`
4. **비정기와 겹침**: `courseOverrides`(placeId, courseId, isCancelled=false, startTime/endTime 있는 것) 조회 후, 각 override의 (dayOfWeek, startTime~endTime)과 새 정기 세션의 같은 요일·시간대 겹침 시 `failed-precondition: 정기 일정이 비정기 일정과 겹칩니다. ...` (날짜·시간 명시).
5. **예약 여부**: 삭제/변경 대상 세션에 대해 `sessionReservations`에서 reservedCount>0, date>=today 조회. 있으면 `throwRequiresBulkMove` → 클라이언트가 details.requiresBulkMove로 일괄 취소 플로우 유도.

### 3.2 반영
- `places/{placeId}` 문서의 `courses` 배열에서 해당 코스의 `sessions`만 새 리스트로 교체.

---

## 4. 정합성 요약

| 구분 | 주체 | 내용 |
|------|------|------|
| 정기 vs 정기 겹침 | 클라이언트 + 서버 | 바텀시트·onRegister 시 _findOverlap / _findOverlapInDay, 저장 시 서버 요일별 겹침 검사 |
| 정기 vs 비정기 겹침 | 서버만 | updateCourseSchedule에서 courseOverrides 조회 후 요일·시간 겹침 시 저장 차단 |
| 예약 있는 세션 삭제/변경 | 서버 | removedKeys/modifiedKeys에 대해 미래 예약 있으면 requiresBulkMove → 클라이언트에서 일괄 취소 유도 |
| 변경 감지 | 클라이언트 | 요일 추가/삭제·세션 개수·내용 비교, 빈 요일 있으면 저장 비활성화 |
| 요일 삭제 시 예약 | 서버 | 해당 요일의 세션 삭제 시 각 세션별로 예약 여부 검사 → 있으면 requiresBulkMove |

---

## 5. 알려진 동작·참고

- **일괄 적용 부분 성공**: 여러 요일에 일괄 적용 시, 한 요일에서만 겹침이 나와도 나머지 요일은 적용됨. (전부 되거나 전부 안 되거나 아님.)
- **요일 삭제 확인**: “요일 삭제 확인” 다이얼로그는 “세션이 있던 요일을 지우는지”만 묻고, “그 요일에 예약이 있는지”는 서버 저장 시점에 막힘. (서버가 requiresBulkMove로 막고, 클라이언트가 일괄 취소 플로우로 유도.)

이 문서는 정기일정 편집 전반의 로직 점검 결과를 요약한 것입니다.
