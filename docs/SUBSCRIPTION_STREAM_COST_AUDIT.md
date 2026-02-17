# 구독 누수·실시간 스트림·비용 감사 (플레이스당 1000명 가정)

## 1. 요약

| 구분 | 심각도 | 개요 |
|------|--------|------|
| **비용폭탄** | 🔴 높음 | members 1000건 + enrollments 2000~3000건 무제한 실시간 구독 |
| **구독 누수** | 🟡 중간 | 대부분 clear/dispose 대응됨. CourseProvider override 주차 누적 가능 |
| **논리적 위험** | 🟡 중간 | 일부 limit 미적용, 알림/멤버 전체 조회 |
| **권장 조치** | - | members/enrollments 페이지네이션·limit, 알림 limit, 관리자 전용 구독 조건 강화 |

---

## 2. 비용폭탄 (1000명/플레이스)

### 2.1 MemberProvider — members + enrollments 무제한 구독

**위치**: `MemberProvider.setPlaceId()`  
**구독 시작**: Admin 화면 진입 시 (AdminScreen, AdminMemberScreen, SessionDetailScreen 등)

| 스트림 | 컬렉션 | 예상 문서 수 (1000명) | 비용 |
|--------|--------|------------------------|------|
| `watchPlaceMembers(placeId)` | places/{id}/members | **1000** | 스냅샷마다 1000 reads |
| `watchEnrollmentsByPlace(placeId)` | enrollments (placeId) | **2000~3000** | 멤버당 2~3 enrollments 가정 |

**Firestore 실시간 구독 특성**:
- 초기 연결 시 전체 문서 1회 읽기
- 이후 변경된 문서만 증분 읽기 (다만 대량 동시 변경 시 비용 급증)
- **문제**: 관리자가 멤버관리 탭에 있지 않아도 Admin 진입만으로 구독 시작 가능

**권장**:
- [ ] 멤버관리 화면(AdminMemberScreen) 진입 시에만 `setPlaceId` 구독 시작
- [ ] 또는 **페이지네이션** 도입: members/enrollments `.limit(100)` + `startAfterDocument`
- [ ] enrollments는 `watchEnrollmentsByPlace` 대신 “현재 화면에 보이는 멤버”만 구독하는 방식 검토

### 2.2 getUserNotifications — limit 없음

**위치**: `NotificationFirestoreService.getUserNotifications()`  
**쿼리**: `users/{uid}/notifications` 전체 `.get()`

- 알림이 많을수록(수백~수천 건) 읽기 비용 증가
- NotificationProvider는 **일회성 로드**만 사용 (스트림 아님)

**권장**: `.limit(100)` 또는 `.limit(500)` 적용

### 2.3 watchUserNotifications — limit 없음

**위치**: `NotificationFirestoreService.watchUserNotifications()`  
**상태**: NotificationProvider는 **watch 사용 안 함** (loadNotifications만 사용)  
→ 현재는 비용 이슈 없음. 향후 실시간 구독 도입 시 limit 필수.

---

## 3. 구독 누수

### 3.1 정상 해제되는 구독

| 구독 | 해제 시점 |
|------|-----------|
| MemberProvider._membersSub, _enrollmentsSub | setPlaceId(null), clear(), dispose() |
| ReservationProvider._reservationSubscription | clear(), dispose() |
| EnrollmentProvider._subscription | clear(), dispose() |
| ReservationSummaryProvider._reservationsSub | clear(), dispose() |
| CourseProvider (courses, overrides, bookingWeekOpens) | clear(), dispose() |
| MemberDetailBottomSheet._pendingMemberSubscription | dispose() |
| ReservationFeedbackListener._sub | dispose() |
| PlaceWaitingScreen._membershipSubscription | dispose() |
| SessionDetailScreen _reservationsSub, _operationEventsSub | dispose() |
| CalendarScreen._reservationOpSub | dispose() |
| FcmService (token, message subscriptions) | dispose() |

### 3.2 주의 대상

1. **CourseProvider.subscribeToOverrides**
   - `weekStartDates.take(3)`로 최대 3주만 구독
   - 다만 “다른 화면이 다른 주차를 요청하면” **기존 구독을 취소하지 않고 누적**
   - placeId 변경/clear 시 `_cancelAllOverrideSubscriptions()`로 전부 해제
   - → 플레이스 전환 없이 주차만 바꾸는 경우, 일시적으로 3~6개 구독 가능. 상대적으로 부담 적음.

2. **MemberProvider**
   - Admin 화면 여러 곳에서 `setPlaceId` 호출
   - 플레이스 전환·로그아웃 시 `memberProvider.clear()` 호출됨 (place_switch_widget, setting_screen 등)
   - Provider는 앱 생명주기와 같아 dispose는 앱 종료 시

3. **CompactCalendarWidget / SessionDetailScreen**
   - ReservationSummaryProvider `setContext` 사용
   - SessionDetailScreen pop 시 `refreshContextTrigger`로 컨텍스트 재설정 완료
   - 플레이스 전환 시 `ReservationSummaryProvider.clear()` 호출 완료

---

## 4. 논리적·구조적 위험

### 4.1 MemberService.watchMemberViews

- `StreamController` + `watchPlaceMembers` + `watchPendingMembersByPlace` 병합
- `controller.onCancel`에서 `sub1.cancel()`, `sub2.cancel()`, `controller.close()` 호출
- docs: `controller.isClosed` 체크 후 `close()` — 이중 close 방지됨 ✅

### 4.2 enrollments 일괄 쿼리

- `watchEnrollmentsByPlace`, `watchPlaceMemberUserIds`, `watchEnrollmentAdminDisplayNamesByPlace` 모두 **placeId 단위 전체 조회**
- 1000명 플레이스에서 enrollments 2000~3000건 → Firestore 부하 가능
- **권장**: 최소한 `limit` 또는 페이지네이션 설계

### 4.3 collectionGroup 쿼리

| 쿼리 | 용도 | 규모 | 비고 |
|------|------|------|------|
| collectionGroup('members').where('userId', ...) | 유저별 플레이스 목록 | 1 uid → 소량 | ✅ |
| collectionGroup('pendingMembers').where('phoneNumber', ...) | 전화번호별 대기 플레이스 | 1 번호 → 소량 | ✅ |

---

## 5. 권장 조치 (우선순위)

### 즉시 (비용 직접 영향)

1. **getUserNotifications에 limit 적용**  
   - `.limit(100)` 또는 `.limit(500)`  
   - 알림 화면은 보통 최근 N건만 표시하면 충분

2. **MemberProvider 구독 조건 검토**  
   - AdminMemberScreen, SessionDetailScreen(멤버 선택) 등 **실제로 멤버 목록이 필요한 화면**에서만 `setPlaceId` 호출  
   - Admin 홈 화면에서 불필요한 멤버 구독 방지

### 단기 (설계 개선)

3. **members / enrollments 페이지네이션**  
   - `watchPlaceMembers` → `.limit(100).orderBy(...)` + `startAfterDocument`  
   - 무한 스크롤 또는 “더보기”로 추가 로드  
   - 1000명 단위 구독은 피하는 것이 안전

### 중기 (모니터링)

5. **Firestore 사용량 대시보드**  
   - reads/writes 추이 확인  
   - 특히 members, enrollments, reservationSummary 구독 패턴 모니터링

---

## 6. 참고: 주요 스트림 목록

| 서비스/Provider | 메서드 | 컬렉션/쿼리 | limit |
|-----------------|--------|-------------|-------|
| MemberService | watchPlaceMembers | places/{id}/members | ❌ |
| MemberService | watchEnrollmentsByPlace | enrollments (placeId) | ❌ |
| EnrollmentService | watchUserEnrollments | enrollments (userId, placeId) | ❌ |
| ReservationService | watchReservationSummaryByCourseAndDateRange | reservationSummary | ✅ 날짜 범위 |
| NotificationFirestoreService | getUserNotifications | users/{id}/notifications | ❌ |
| CourseService | watchCoursesByPlace | places/{id}/courses | ❌ (코스 수 제한적) |
| CourseService | streamCourseOverrides | courseOverrides | ✅ 주차별 |

---

## 7. 결론

- **비용 폭탄**: members + enrollments 무제한 구독이 1000명 규모에서 가장 큰 리스크
- **구독 누수**: clear/dispose 대응은 대체로 양호. CourseProvider override 구독은 주차·placeId 변경 시 정리됨
- **우선 조치**: 알림 limit, 멤버/등록 구독 조건·페이지네이션 설계
