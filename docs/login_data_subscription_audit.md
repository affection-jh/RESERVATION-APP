# 로그인·데이터 로드·구독 점검 보고서

## 1. 로그인 후 수행되는 테스크 흐름

### 1.1 인증 경로 (2가지)

| 경로 | 트리거 | 수행 테스크 |
|------|--------|-------------|
| **명시적 로그인** | `AuthProvider.loginUser()` (전화번호+인증코드) | ① verifyCodeAndSignIn ② _initializeFcm ③ **loadPlaceMembershipsForCurrentUser()** (members 1회 조회) ④ **startWatchingPlaceMemberships()** (collectionGroup 'members' 구독) |
| **자동 로그인** | `AuthService.checkUserAutoLogin()` → `_completeAuthentication()` | ① findUserByPhone ② _autoMatchMemberships (createEnrollmentsFromPendingMembers Callable) ③ **_fetchPlaceIdsForUser(userId)** → **members** 쿼리로 placeIds 반환 ④ AuthResult.placeIds 설정 |

- **Auth state 스트림** (`authStateChanges()`): Firebase Auth 변경 시 위와 유사하게 findUserByPhone → _autoMatchMemberships → **_fetchPlaceIdsForUser** → AuthState.authenticated(placeIds) 반환.

### 1.2 앱 시작 (AppStartupScreen)

- `_checkAutoLogin()`:
  - 자동 로그인 성공 시: `authProvider.setCurrentUser` → **loadPlaceMembershipsForCurrentUser()** → **startWatchingPlaceMemberships()** → `setApprovedPlaceIds(userResult.placeIds)` (members 기반).
  - 그 다음 `_prepareUserScreen()` 또는 `_prepareAdminScreenWithUser()`:
    - **placeProvider.loadPlaces(allPlaceIds)** (병렬)
    - placeProvider.setCurrentPlace, authService.setCurrentPlace
    - notificationProvider.loadNotifications (비블로킹)
    - 스토리/코스 등 선로딩

### 1.3 PlaceWaitingScreen (플레이스 선택 대기)

- `_initializeUser()`: Firebase Auth → AuthProvider.currentUser 또는 findUserByPhone → **_startMembershipSubscription()**.
- **_startMembershipSubscription()**:
  - **MemberService.watchUserPlaceIdsIncludingPending(userId, phoneNumber)** 구독 시작.
  - 이 스트림은 내부적으로 **2개 Firestore 리스너**:
    - `watchUserPlaceIds(userId)` → **collectionGroup('members').where('userId', '==', uid)** (members 기준 접근 가능 플레이스).
    - `watchPendingPlaceIds(phoneNumber)` → **collectionGroup('pendingMembers').where('phoneNumber', '==', normalized)** (pending 초대 플레이스).
  - 스트림에서 placeIds 수신 시: 배치로 Place 로드 → **authProvider.setApprovedPlaceIds(placeIds)** 갱신, linkedAdmin/adminManagedPlaceIds 1회 조회, 단일 플레이스면 자동 진입.

### 1.4 MainScreen (플레이스 진입 후)

- `_loadInitialData()` (postFrameCallback, didChangeDependencies에서 재시도):
  - currentPlace 없으면 스킵(다음 기회 대기).
  - courseProvider.loadCourses, storyProvider.loadStories (비로그인도 가능).
  - 로그인 시: **reservationProvider.loadUserReservations(userId, placeId)**, **enrollmentProvider.loadUserEnrollments(userId, placeId)** → 각각 **watchUserReservations**, **watchUserEnrollments** 구독 시작.

---

## 2. 접근 가능 플레이스 데이터 소스 (정리)

| 시점 | 소스 | 비고 |
|------|------|------|
| AuthService._fetchPlaceIdsForUser / AuthResult.placeIds | **members** (getPlaceMembershipsForUser) | 자동 로그인·authStateChanges 초기값 |
| AppStartup setApprovedPlaceIds | AuthResult.placeIds → **members** | 초기 표시용 |
| AuthProvider.placeMemberships / placeIdsFromPlaceMemberships | **members** (collectionGroup 'members', userId) | loadPlaceMembershipsForCurrentUser + startWatchingPlaceMemberships |
| PlaceWaitingScreen watchUserPlaceIdsIncludingPending | **members + pendingMembers** | 실시간 접근 가능 + pending 초대 목록, 여기서 setApprovedPlaceIds 재설정 |

- **일관성**: “접근 가능 플레이스”는 UI상 **members + pending**이 최종 소스이고, 접근 가능 플레이스는 **enrollment 제거됨**. 전부 **members**(+ PlaceWaitingScreen에서 pending) 기준으로 통일됨.

---

## 3. 구독 효율·데이터 로드 효율

### 3.1 잘 되어 있는 부분

- **중복 구독 방지**
  - ReservationProvider / EnrollmentProvider: `loadUserReservations` / `loadUserEnrollments` 시 동일 (userId, placeId)면 재구독 스킵, 아니면 기존 구독 cancel 후 새 구독.
  - PlaceWaitingScreen: `_membershipSubscription != null`이면 `_startMembershipSubscription()` 스킵.
  - AuthProvider: `startWatchingPlaceMemberships()` 진입 시 기존 `_placeMembershipsSubscription?.cancel()` 후 새 구독.
- **Place 로드**: PlaceWaitingScreen에서 placeIds 기준 **배치 병렬** (Future.wait), 이미 _placesMap에 있으면 스킵.
- **watchUserPlaceIdsIncludingPending**: members 1개 + pending 1개 스트림만 사용하고, 내부에서 merge 후 한 스트림으로만 노출.

### 3.2 개선 권장

- ~~**AuthService._fetchPlaceIdsForUser**~~: **members** 기반으로 변경 완료 (getPlaceMembershipsForUser 사용). getApprovedPlaces도 members 기반으로 변경됨.
- **MemberService.watchMemberViews(placeId)**: `StreamController` 사용 시 `onCancel`에서 sub1/sub2만 cancel하고 **controller는 close하지 않음**. 메모리 상 작은 누수 가능성; `watchUserPlaceIdsIncludingPending`처럼 `onCancel` 안에서 controller도 close 하면 일관됨.

---

## 4. 구독 해제(해제) 점검

### 4.1 해제 잘 하고 있는 곳

| 구독 | 해제 시점 |
|------|-----------|
| PlaceWaitingScreen._membershipSubscription | **dispose()**에서 `_membershipSubscription?.cancel()` |
| MemberService.watchUserPlaceIdsIncludingPending 내부 sub1, sub2 | 리스너가 cancel될 때 **controller.onCancel**에서 sub1.cancel(), sub2?.cancel(), controller.close() |
| AuthProvider._placeMembershipsSubscription | **logout()** 시 **stopWatchingPlaceMemberships()**에서 cancel |
| ReservationProvider._reservationSubscription | **loadUserReservations** 시 기존 cancel 후 재구독, **clear()** 없음(아래 참고) |
| EnrollmentProvider._subscription | loadUserEnrollments 시 기존 cancel, **dispose()**에서 cancel (Provider는 앱 생명주기와 같아서 실제 dispose는 앱 종료 시) |
| MemberProvider._membersSub, _enrollmentsSub | **setPlaceId()** 시 기존 cancel 후 새 구독, **clear()** / **dispose()**에서 cancel |
| MemberService.watchMemberViews(placeId) 내부 sub1, sub2 | **onCancel**에서 sub1.cancel(), sub2.cancel() (controller 미 close는 위 3.2 참고) |
| FcmService 토큰/메시지 구독 | **dispose()**에서 cancel |
| compact_calendar_widget, session_detail_screen 등 화면 단위 구독 | 해당 위젯 **dispose()**에서 cancel |

### 4.2 보완 권장

- **로그아웃 시 ReservationProvider / EnrollmentProvider**:  
  현재 **AuthProvider.logout()**에서 이 두 Provider의 구독을 끄지 않음. 로그아웃 후에도 예약/등록 스트림이 남아 있을 수 있음.  
  → 로그아웃 시 **ReservationProvider.clear()**, **EnrollmentProvider.clear()** (또는 각 Provider에 `reset()` 등으로 구독만 cancel) 호출 권장.
- **MemberService.watchMemberViews**: onCancel에서 controller close 추가 권장 (위 3.2와 동일).

---

## 5. 요약

- **로그인 후 테스크**: 인증 → (자동매칭) → members 1회 로드 + members 구독 시작; PlaceWaitingScreen에서는 members+pending 구독으로 접근 가능 플레이스 실시간 반영 후 setApprovedPlaceIds; MainScreen 진입 시 해당 플레이스 기준 예약/등록 구독.
- **접근 가능 플레이스**: 실질 소스는 **members + pending**; 접근 가능 플레이스는 members(+ pending) 단일 소스로 통일 완료.
- **구독 효율**: 중복 구독 방지·배치 로드·스트림 병합이 잘 되어 있음.
- **해제**: 화면/Provider dispose·placeId 변경·로그아웃 시 대부분 해제 잘 됨; **로그아웃 시 ReservationProvider/EnrollmentProvider 구독 해제**와 **watchMemberViews controller close** 추가 시 더 안전함.
