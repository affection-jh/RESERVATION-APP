# 구독·스트림·데이터 로드 최종 점검

## 1. 구독/스트림 일람 및 해제 상태

| 구독 | 소유 | 생성 시점 | 해제 시점 | 상태 |
|------|------|-----------|-----------|------|
| **MemberProvider** | | | | |
| _placeMembersSegmentSub | MemberProvider | setPlaceId, _switchSegmentTo | setPlaceId(null), clear(), dispose(), _switchSegmentTo | ✅ |
| _pendingSub | MemberProvider | setPlaceId | setPlaceId(null), clear(), dispose() | ✅ |
| _enrollmentsSub | MemberProvider | _refreshEnrollmentsSubscription | setPlaceId(null), clear(), _refreshEnrollmentsSubscription 재호출 시 | ✅ |
| _visibleRangeDebounce | MemberProvider | setVisibleRange | setPlaceId(null), clear(), dispose(), 새 타이머 시 | ✅ |
| **EnrollmentProvider** | | | | |
| _subscription | EnrollmentProvider | loadUserEnrollments | loadUserEnrollments(다른 id), clear(), dispose() | ✅ |
| **ReservationProvider** | | | | |
| _reservationSubscription | ReservationProvider | loadUserReservations | clear(), dispose() | ✅ |
| _opController (BroadcastStream) | ReservationProvider | 생성 시 | dispose()에서 close() | ✅ |
| **ReservationSummaryProvider** | | | | |
| _reservationsSub | ReservationSummaryProvider | setContext | clear(), dispose() | ✅ |
| _loadingTimeout, _notifyDebounceTimer | ReservationSummaryProvider | 내부 | clear(), dispose() | ✅ |
| **CourseProvider** | | | | |
| _coursesSubscription | CourseProvider | subscribeToCourses | clear(), dispose() | ✅ |
| _overrideSubscriptionsByWeek | CourseProvider | subscribeToOverrides | clear(), dispose() | ✅ |
| _bookingWeekOpensSubs | CourseProvider | subscribeToBookingWeekOpens | clear(), dispose() | ✅ |
| **AuthProvider** | | | | |
| _placeMembershipsSubscription | AuthProvider | startWatchingPlaceMemberships | stopWatchingPlaceMemberships(로그아웃 시) | ✅ |
| **PlaceWaitingScreen** | | | | |
| _membershipSubscription | PlaceWaitingScreen | initState | dispose(), 플레이스 선택 시 | ✅ |
| **SessionDetailScreen** | | | | |
| _reservationsSub | SessionDetailScreen | _listenReservations | dispose(), 재구독 시 | ✅ |
| _operationEventsSub | SessionDetailScreen | initState | dispose(), 재구독 시 | ✅ |
| **CalendarScreen** | | | | |
| _reservationOpSub | CalendarScreen | initState | dispose(), 재구독 시 | ✅ |
| **MemberDetailBottomSheet** | | | | |
| _enrollmentSubscription | MemberDetailBottomSheet | (EnrollmentProvider 사용) | - | EnrollmentProvider이 관리 |
| _pendingMemberSubscription | MemberDetailBottomSheet | _ensurePendingRef | dispose() | ✅ |
| **CourseScheduleEditScreen** | | | | |
| _reservedSessionIdsSub | CourseScheduleEditScreen | initState | dispose(), courseId 변경 시 | ✅ |
| **EnrollmentTimelineProvider** | | | | |
| _subscription | EnrollmentTimelineProvider | watchTimeline | watchTimeline(다른 id), dispose() | ✅ |
| **ReservationFeedbackListener** | | | | |
| _sub | ReservationFeedbackListener | initState | dispose() | ✅ |
| **FcmService** | | | | |
| _tokenRefreshSubscription | FcmService | initialize | - | ⚠️ 앱 생명주기와 동일, dispose 없음 |
| _foregroundMessageSubscription | FcmService | _setupForegroundHandlers | - | ⚠️ 동일 |
| _messageOpenedSubscription | FcmService | _setupForegroundHandlers | - | ⚠️ 동일 |

---

## 2. 데이터 로드 (1회성) - limit 적용

| 로드 | limit | 비고 |
|------|-------|------|
| getUserNotifications | 100 | ✅ |
| getPlaceMembersPage | 100 | ✅ |
| getPlaceMembers (watchPlaceMembersSegment) | 30 (segmentSize) | ✅ |
| watchPlaceMembersSegment | 30 | ✅ |
| watchEnrollmentsForUserIds | 30 (whereIn) | ✅ |
| watchPendingMembersByPlace | 100 | ✅ |
| watchReservationSummaryByCourseAndDateRange | 날짜 범위로 제한 | ✅ |
| streamCourseOverrides | 주차별 | ✅ |

---

## 3. clear() 호출 경로

| 시나리오 | 호출 대상 |
|----------|-----------|
| 플레이스 전환 (PlaceSwitchWidget) | course, summary, story, notification, member, reservation, enrollment |
| 로그아웃 (SettingScreen) | member, summary, reservation, enrollment |
| 대기실 이탈/플레이스 선택 (PlaceWaitingScreen) | course, story, summary, reservation, enrollment, member |
| 인사말 설정 화면 이탈 (GreetingMassageSettingScreen) | course, summary, story, notification, member, reservation, enrollment |

---

## 4. 구독 누수·주의 대상

### 4.1 FcmService

- FCM 구독은 앱 생명주기와 동일하게 유지
- dispose 없음 → 앱 종료 시 프로세스 종료로 함께 해제
- **판단**: 앱 단일 인스턴스 서비스로 허용

### 4.2 CourseProvider.subscribeToOverrides

- `weekStartDates.take(3)`로 최대 3주만 구독
- placeId 변경/clear 시 `_cancelAllOverrideSubscriptions()` 호출
- 주차만 바꿀 때 기존 구독 유지 → 일시적 3~6개 가능
- **판단**: 설계상 의도된 동작, 부담 적음

### 4.3 AuthProvider._placeMembershipsSubscription

- 로그아웃 시 `stopWatchingPlaceMemberships()` 호출
- AuthProvider 자체 dispose는 앱 종료 시
- **판단**: 정상

---

## 5. 비용·성능 (1000명 플레이스 기준)

| 구독 | 예상 reads | 상태 |
|------|------------|------|
| MemberProvider (members) | 30/세그먼트 | ✅ 슬라이딩 윈도우 |
| MemberProvider (enrollments) | ~60/세그먼트 (30 userIds) | ✅ |
| MemberProvider (pending) | 최대 100 | ✅ |
| EnrollmentProvider | 1 userId → 소량 | ✅ 온디멘드 |
| ReservationSummaryProvider | 날짜×코스 범위 | ✅ |
| CourseProvider (courses) | 코스 수 | ✅ |
| CourseProvider (overrides) | 주차별 3개 | ✅ |
| NotificationProvider | loadNotifications 1회, limit 100 | ✅ |

---

## 6. 권장 조치

### 즉시

- 없음. 기존 개선(members/enrollments 슬라이딩 윈도우)으로 안정적.

### 참고

1. **FcmService**: 필요 시 `dispose()`에서 구독 취소 추가 검토 (앱 전역 서비스라 우선순위 낮음).

---

## 7. 결론

- **구독 누수**: clear/dispose 처리 양호, 누수 의심 구간 없음.
- **비용**: members/enrollments 슬라이딩 윈도우(30명) 적용으로 1000명 플레이스에서도 수용 가능.
- **해제 시점**: 플레이스 전환·로그아웃·화면 이탈 시 해당 Provider clear 호출 확인됨.
