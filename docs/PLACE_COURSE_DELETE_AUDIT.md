# 플레이스/코스 삭제 시 데이터 정리 점검

## 1. 요약

| 구분 | deleteCourse | deletePlace | 비고 |
|------|--------------|-------------|------|
| **reservations** | ⚪ 삭제 안 함 (이력 보존) | ⚪ 삭제 안 함 (이력 보존) | 플레이스/코스 삭제 시에도 예약 문서는 유지 |
| **reservationSummary** | ✅ deleteSummariesForCourse | ✅ 코스별 deleteSummariesForCourse | 고아 방지 반영됨 |
| **courseOverrides** | ✅ 삭제 | ✅ 삭제 | 자동정리(30일)도 있음 |
| **bookingWeekOpens** | ✅ 삭제 | ✅ 삭제 | 자동정리도 있음 |
| **enrollments** | ✅ 서브컬렉션 포함 삭제 | ✅ 서브컬렉션 포함 삭제 | actionHistory, extensionRequests 선삭제 후 문서 삭제 |
| **places/…/courses** | ✅ 해당 코스 문서만 | ✅ 전체 서브컬렉션 | |
| **places/…/pendingMembers** | ⚪ 업데이트만 (courseId 제거) | ✅ 전체 삭제 | |
| **coursePolicies** | ✅ courseId 문서 (placeId 일치 시) | ✅ 모든 코스 문서 | |
| **promotions** | ⚪ 해당 없음 | ✅ placeId 일치 삭제 | |
| **notifications** | ⚪ 해당 없음 | ✅ collectionGroup placeId | |
| **places/…/members** | ⚪ 해당 없음 | ✅ 전체 삭제 | |
| **places/…/stories** | ⚪ 해당 없음 | ✅ 전체 삭제 | |
| **users.placeIds** | ⚪ 미수정 | ⚪ 미수정 | 삭제된 place 참조 잔존 가능(선택 정리) |

---

## 2. 수정 반영 사항

### 2.1 deletePlace – reservationSummary 누락 보완

- **문제**: 플레이스 삭제 시 `reservationSummary` 삭제 없음 → 고아 문서 발생.
- **조치**: 글로벌 컬렉션 정리 단계에서 `courseIds` 기준으로 `deleteSummariesForCourse(db, placeId, courseId)` 호출 추가.

### 2.2 deleteCourse / deletePlace – enrollments 서브컬렉션 고아 방지

- **문제**: `deleteByQuery(enrollments)`만 사용 시 `enrollments/{id}/actionHistory`, `enrollments/{id}/extensionRequests` 서브컬렉션이 남음.
- **조치**: `deleteEnrollmentsWithSubcollections(db, query)` 도입. 쿼리로 조회한 각 enrollment에 대해 actionHistory, extensionRequests 삭제 후 문서 삭제. deleteCourse·deletePlace 모두 이 함수로 enrollments 삭제하도록 변경.

---

## 3. reservations 정책 (이력 보존)

- **결정**: 플레이스/코스 삭제 시 **reservations는 삭제하지 않음**. 예약 이력·통계·분쟁 대응을 위해 보존.
- **구현**: deleteCourse, deletePlace 모두 예약 삭제 단계 제거. 코스 삭제 시 해당 코스에 미래 예약이 있던 사용자에게는 "코스가 삭제되었습니다. 예약 이력은 보존됩니다." 안내 알림만 발송.

---

## 4. 자동정리와의 관계

- **courseOverrides**, **reservationSummary**, **bookingWeekOpens**는 `cleanupOldData`에서 일정 기간(예: 30일) 이전 데이터 자동 삭제됨.
- 플레이스/코스 **삭제 시에는** 해당 place/course에 대한 문서를 즉시 삭제해 고아를 만들지 않도록 유지. 자동정리만 믿지 않고, 삭제 플로우에서 명시적으로 정리하는 현재 방식 유지.

---

## 5. 컬렉션/서브컬렉션 정리 체크리스트

### deleteCourse 시

- [x] places/{placeId}/courses/{courseId}
- [x] reservations 삭제 안 함 (이력 보존)
- [x] reservationSummary (placeId+courseId, deleteSummariesForCourse)
- [x] courseOverrides (placeId+courseId)
- [x] bookingWeekOpens (placeId+courseId)
- [x] enrollments (placeId+courseId, 서브컬렉션 포함)
- [x] places/{placeId}/pendingMembers 내 courseId 필드만 업데이트
- [x] coursePolicies (courseId 문서, placeId 일치 시)

### deletePlace 시

- [x] reservations 삭제 안 함 (이력 보존)
- [x] reservationSummary (코스별 deleteSummariesForCourse)
- [x] enrollments (placeId, 서브컬렉션 포함)
- [x] promotions (placeId)
- [x] notifications (collectionGroup, placeId)
- [x] bookingWeekOpens (placeId)
- [x] courseOverrides (placeId)
- [x] coursePolicies (해당 place의 모든 courseId)
- [x] places/{placeId}/pendingMembers 전체
- [x] places/{placeId}/courses 전체
- [x] places/{placeId}/stories 전체
- [x] places/{placeId}/members 전체
- [x] places/{placeId} 문서

### 별도 정리 없음 (의도적)

- **reservations**: 삭제하지 않음(이력 보존).
- **users.placeIds**: 삭제된 place ID가 남아도 동작에는 영향 적음. 필요 시 별도 정리 단계 추가 가능.
- **placeMemberships**: 레거시/미사용(rules deny all). 삭제 대상 아님.

---

## 6. 재점검 (최종) — DB 깔끔하게 유지 여부

### 6.1 placeId/courseId를 참조하는 모든 저장소

| 저장소 | deleteCourse | deletePlace | 비고 |
|--------|--------------|-------------|------|
| **reservations** (top-level) | ⚪ 삭제 안 함 | ⚪ 삭제 안 함 | 이력 보존 |
| **reservationSummary** (top-level) | ✅ placeId+courseId | ✅ 코스별 placeId+courseId | |
| **courseOverrides** (top-level) | ✅ placeId+courseId | ✅ placeId | |
| **bookingWeekOpens** (top-level) | ✅ placeId+courseId | ✅ placeId | 문서에 placeId 필드 있음 |
| **enrollments** (top-level) | ✅ placeId+courseId + 서브컬렉션 | ✅ placeId + 서브컬렉션 | actionHistory, extensionRequests 선삭제 |
| **coursePolicies** (top-level, docId=courseId) | ✅ placeId 일치 시 삭제 | ✅ 해당 place의 모든 courseId 문서 | |
| **promotions** (top-level) | 해당 없음 | ✅ placeId | |
| **notifications** (users/{uid}/notifications) | 해당 없음 | ✅ collectionGroup placeId | |
| **places/{placeId}/courses** | ✅ 해당 1개 문서 | ✅ 전체 | 코스 문서 아래 서브컬렉션 없음 |
| **places/{placeId}/pendingMembers** | ⚪ courseId만 제거(update) | ✅ 전체 삭제 | |
| **places/{placeId}/members** | 해당 없음 | ✅ 전체 삭제 | |
| **places/{placeId}/stories** | 해당 없음 | ✅ 전체 삭제 | |
| **places/{placeId}** 문서 | 해당 없음 | ✅ 삭제 | |

위 외에 placeId/courseId를 저장하는 컬렉션은 없음. **placeMemberships**는 미사용이라 삭제하지 않음.

### 6.2 서브컬렉션

- **enrollments/{id}/actionHistory**, **enrollments/{id}/extensionRequests**: deleteEnrollmentsWithSubcollections에서 선삭제 후 enrollment 문서 삭제 → 고아 없음.
- **places/{placeId}/courses/{courseId}**: 서브컬렉션 없음(코스는 단일 문서).
- **users/{uid}/notifications**: placeId 필드로 collectionGroup 삭제 → 해당 place 관련만 삭제.

### 6.3 결론

- **플레이스 삭제**: placeId를 참조하는 글로벌 컬렉션 + place 서브컬렉션 전부 정리됨. reservationSummary는 코스별로 삭제해 고아 없음.
- **코스 삭제**: courseId(및 placeId)를 참조하는 글로벌 컬렉션 + 해당 코스 문서 + coursePolicies + pendingMembers 내 courseId 제거까지 반영됨. enrollments 서브컬렉션 포함.
- **순서 개선 반영**: deleteCourse에서 코스 문서 삭제를 **정리(예약·reservationSummary·courseOverrides·bookingWeekOpens·enrollments·pendingMembers·coursePolicies) 완료 후**로 이동함. 정리 중 실패해도 코스 문서가 남아 있어 재시도·수동 정리 가능하고, 고아만 남는 상황을 줄임.
