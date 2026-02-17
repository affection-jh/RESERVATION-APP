# Provider – Service – Model 아키텍처 점검 보고서

점검일: 2025-02 기준  
기준: (1) 불필요/중복 프로바이더·코드 (2) 불필요/중복 서비스 (3) 계층 불일치 (4) 서비스 로직 품질 (5) Screen 확장성 (6) Firebase 구독/조회 최적화

---

## 1. 프로바이더: 불필요·중복

### 1.1 프로바이더 목록 (9개) — 모두 사용됨
| Provider | 사용처 | 비고 |
|----------|--------|------|
| AuthProvider | 대부분 화면 | 필수 |
| PlaceProvider | 대부분 화면 | 필수 |
| CourseProvider | 캘린더, 홈, 관리자, 코스/멤버 화면 | 필수 |
| ReservationProvider | 캘린더, 홈, 마이페이지, 예약/관리 바텀시트 | 필수 |
| EnrollmentProvider | 캘린더, 홈, 마이페이지, 멤버/등록 상세 | 필수 |
| MemberProvider | 관리자 멤버, 등록 상세, 멤버 편집/등록 화면 | 필수 |
| ReservationSummaryProvider | 캘린더(세션별 N/M명) | 필수 |
| StoryProvider | 홈, 플레이스 대기, 관리자 홈 | 필수 |
| NotificationProvider | 알림 화면 | 필수 |

**결론:** 불필요한 프로바이더 없음. MemberManagementService 삭제 후 MemberProvider만 사용 중.

### 1.2 프로바이더 내 중복·과다 로직 (계층 이탈)
- **ReservationProvider**
  - `_sortUpcomingFirst`, `_reservationKey`, `_parseTimeToMinutes`, `_reservationStartDateTime` → **비즈니스/유틸**: Service 또는 공용 유틸로 이동 권장.
  - 배치 결과 맵 파싱·실패 판단·낙관적 업데이트 계산 → Service로 이동 시 Provider는 “상태 + 서비스 호출 결과 반영”만 담당 가능.
- **ReservationSummaryProvider**
  - `_applyCapacityOverridesToSessionReservationSummarys`, `updateCapacityLocally` 등 집계/오버레이 적용 로직 → Service(또는 전용 도메인 서비스)로 이동 권장.
- **CourseProvider**
  - `_syncCoursePoliciesFromCourses`, 정책 캐시, `subscribeToOverrides` 구독 관리 → CourseService로 위임 시 Provider 단순화.
- **StoryProvider**
  - `_sortStoriesLatestFirst`, loadStories 중복 방지 로직 → StoryService로 이동 권장.
- **MemberProvider**
  - `allMembers` / `filteredMembers` / `getMembersForCourse`: **파생 상태(뷰 모델)** 로 보는 한 Provider 유지 가능. 다만 계산이 무거우면 별도 getter/헬퍼 분리 검토.

---

## 2. 서비스: 불필요·중복

### 2.1 서비스 구조
- **FirestoreService**: 파사드. 도메인별 서비스(Place, Course, Reservation, Notification, Story, Enrollment)로 위임. **비즈니스 로직 없음.**
- **도메인별**
  - Place: `PlaceFirestoreService` (데이터 액세스만)
  - Course: `CourseService` (통합됨)
  - Reservation: `ReservationService`
  - Notification/Story: `*FirestoreService` (데이터 액세스)
  - Enrollment: `EnrollmentService` + Callable(`EnrollmentFirestoreService`는 FirestoreService 경유)
  - Auth: `AuthService`, FCM: `FcmService`, Member: `MemberService`, User: `UserService`
  - Storage: `StorageService` (로컬/업로드)

**중복**
- **MemberService.watchMemberViews** vs (삭제된) MemberManagementService: 동일 로직. 현재 MemberService 단일 소스로 정리됨.
- **EnrollmentService** vs **EnrollmentFirestoreService**: 후자는 Callable `cancelEnrollment`만 담당. FirestoreService가 EnrollmentFirestoreService를 통해 cancelEnrollment 위임. EnrollmentService는 스트림·액션 히스토리·create 등. 역할 분리 유지해도 됨.

### 2.2 불필요한 서비스
- 없음. 단, **FirestoreService**를 점진적으로 제거하고 화면/프로바이더가 도메인 Service만 참조하도록 하면 계층이 더 분명해짐.

---

## 3. 계층에 맞지 않는 코드

### 3.1 Model이 Provider에 있음
- **`Story`** 모델이 `lib/providers/story_provider.dart` 안에 정의됨.
  - **조치:** `lib/models/story.dart`로 이동. `FirestoreService`, `StoryFirestoreService`, `StoryProvider`는 `models/story.dart`를 import하도록 수정.

### 3.2 Service가 Provider를 참조 (역방향 의존)
- **`lib/services/firestore_service.dart`**: `import '../providers/story_provider.dart'` — Story 타입 때문에 Provider 참조.
  - Story를 models로 옮기면 이 import 제거 가능.
- **`lib/services/story_firestore_service.dart`**: 동일하게 `story_provider` import.
- **`lib/services/fcm_service.dart`**: `NotificationProvider`, `AuthProvider`, `MemberProvider`, `CourseProvider`, `EnrollmentProvider`, `PlaceProvider` import — FCM 메시지 시 Provider에 알림/상태 반영.
  - **권장:** FCM 수신 시 “알림 추가” 등은 콜백 또는 이벤트 버스로 전달하고, Provider는 상위(또는 리스너)에서만 갱신하도록 하면 Service→Provider 직접 의존 제거 가능. (대규모 리팩터)

### 3.3 Screen이 Service를 직접 참조 (Provider만 참조해야 함)
- **많은 화면이 FirestoreService / MemberService / AuthService / UserService / EnrollmentService 등 직접 사용.**
  - 예: `place_waiting_screen`, `calendar_screen`, `session_detail_screen`, `course_schedule_edit_screen`, `enrollment_detail_screen`, `member_detail_bottom_sheet`, `bulk_move_reservations_bottom_sheet`, `app_startup_screen`, `course_policy_edit_screen`, `weekly_override_schedule_screen`, `admin_home_screen`, `member_registration_screen`, `course_member_registration_screen`, `member_edit_bottom_sheet`, `place_delete_confirm_screen`, `admin_place_edit_screen`, `admin_greeting_setting_screen`, `name_input_screen`, `verification_code_screen`, `phone_number_input_screen` 등.
- **권장:**  
  - “데이터 조회/구독” → 해당 도메인 **Provider**가 Service를 호출하고 상태로 노출; Screen은 Provider만 참조.  
  - “액션(등록/취소/이동/삭제)” → Provider 메서드로 노출(내부에서 Service 호출); Screen은 `context.read<XxxProvider>().doYyy()` 만 호출.  
  - 예외: **StorageService**(파일 업로드), **AuthService**(일부 로그인 플로우)는 화면에서 직접 호출을 유지할 수 있으나, 가능하면 AuthProvider/별도 Provider 경유로 통일.

---

## 4. 서비스 로직: 간결성·철저성·유지보수성·가독성

### 4.1 잘 되어 있는 부분
- **EnrollmentProvider**: Service 호출 + in-flight만 관리. 단순함.
- **MemberProvider**: MemberService 스트림 구독 + 파생 리스트(getter). 역할 명확.
- **EnrollmentService**: watchUserEnrollments, cancelEnrollment( Callable 위임) 등 역할 분리.
- **CourseService**: 코스 + 오버라이드 + 주차 오픈 통합 후 한 파일로 정리됨.

### 4.2 개선 권장
- **ReservationProvider**  
  - 정렬·키 생성·결과 파싱·낙관적 업데이트를 **ReservationService**로 이전.  
  - Service: `createReservation`/`cancelReservation`/`moveReservation`/`deleteReservation` + “정렬된 리스트 반환” 또는 “배치 결과 해석” 메서드 제공.  
  - Provider: 상태 + `reservationService.xxx()` 호출 + 결과로 `_reservations` 갱신 + `operationEvents` 전달.
- **ReservationSummaryProvider**  
  - 집계/오버레이 적용 로직을 Service로 이전. Provider는 “구독 + 상태 보관”만.
- **MemberService**  
  - 규모가 큼(1000줄 근처). “멤버 CRUD”, “pending”, “등록(registerMember / enrollMemberToCourses)” 등으로 파일/클래스 분할하거나, private 메서드로 블록 단위 정리하면 가독성·유지보수성 향상.
- **AuthService**  
  - 역시 규모가 큼. “인증(로그인/자동로그인)”, “User CRUD”, “Place 접근” 등 역할별로 메서드 그룹화·주석으로 구간 나누기 권장.

---

## 5. Screen 확장성 — “Provider 값만으로 UI 구성” 가능 여부

### 5.1 현재 상태
- **Provider만 참조해 UI를 만드는 경우:** Home, MyPage, Notification 등 일부.
- **Service를 직접 쓰는 화면이 많음:**  
  - FirestoreService: 캘린더, 세션 상세, 코스 스케줄 편집, 주간 오버라이드, 정책 편집, 플레이스 대기, 앱 스타트업, 멤버 등록/상세/편집, bulk move 등.  
  - MemberService / UserService / EnrollmentService / AuthService: 멤버·등록·인증 관련 화면 다수.
- **결과:** “새 화면은 Provider만 보면 된다”가 **성립하지 않음**. 어떤 데이터는 Provider에 없어서 Screen이 Service를 직접 호출하는 패턴이 혼재.

### 5.2 권장 방향
- **도메인별 “진입점” 정리**
  - 예약: `ReservationProvider` — 예약 목록, 생성/취소/이동, in-flight. (세션 집계는 `ReservationSummaryProvider`.)
  - 코스: `CourseProvider` — 코스 목록, 정책, 비정기 일정(오버라이드), 주차 오픈.
  - 멤버: `MemberProvider` — 멤버 목록(MemberView), enrollments, 필터/선택.
  - 플레이스/스토리/알림/등록: 각 Provider가 해당 Service를 통해 “현재 필요한 데이터”를 상태로 노출.
- **화면이 하면 좋은 것**
  - `context.watch<XxxProvider>()` / `context.read<XxxProvider>()` 만 사용.
  - “한 번만 조회”가 필요한 경우도 Provider에 `loadYyy()` / `getZzz()` 형태로 두고, 내부에서만 Service 호출.
- **예외**
  - 파일 업로드(StorageService), 로그인 플로우(전화번호/인증코드 입력) 등은 Provider 경유 또는 전용 작은 Provider로 감싸면 “대부분 Provider만 참조”에 가까워짐.

---

## 6. Firebase 구독·조회: 비용·성능 최적화

### 6.0 현재 상태 요약 (적용 후)

| 항목 | 상태 | 비고 |
|------|------|------|
| **bookingWeekOpens** | ✅ 통합됨 | CourseProvider에서 (placeId, courseId)당 1회만 구독. calendar_screen, admin_home_screen, compact_calendar_widget은 Provider만 사용 → **비용·성능 효과적.** |
| **watchCourseSessionReservations / watchDateCapacityOverrides** | ⚠️ 중복 가능 | ReservationSummaryProvider(setContext)와 **compact_calendar_widget**이 동일 (placeId, courseId, 기간)에 대해 각각 구독. 같은 화면 트리에서 둘 다 쓰이면 **동일 데이터 2회 리드.** |
| **streamCourseOverrides** | ⚠️ 중복 가능 | CourseProvider(주별) + ReservationSummaryProvider(setContext 시) 둘 다 구독 → 같은 주에 2 리스너. |
| **일회성 조회** | ✅ 적절 | session_detail_screen은 `watchCourseSessionReservations(...).first`, `getCourseOverrides`, `getCapacityOverride` 등 get/한 번만 사용. |
| **인덱스** | ✅ 부합 | firestore.indexes.json에 sessionReservations(courseId, placeId, date), courseOverrides(placeId, courseId, type, date) 등 쿼리와 일치. |
| **구독 해제** | ✅ 정리됨 | 각 Provider·위젯에서 dispose/clear 시 cancel 호출. |

**결론:** bookingWeekOpens는 **비용·성능 측면에서 효과적**으로 개선됨. 같은 (placeId, courseId)에 대한 구독·리드는 1회.  
추가로 **compact_calendar_widget**이 ReservationSummaryProvider를 사용하도록 바꾸고, **streamCourseOverrides**를 CourseProvider 단일 구독으로 모으면 리드·연결 수를 더 줄일 수 있음.

---

### 6.1 중복 구독 가능성
- **streamBookingWeekOpens(placeId, courseId)** — **조치 완료**  
  - **CourseProvider**에서 (placeId, courseId)당 1회만 `subscribeToBookingWeekOpens`로 구독.  
  - calendar_screen, admin_home_screen, compact_calendar_widget은 `CourseProvider.getBookingWeekOpens(...)`만 사용 → 중복 구독 제거됨.
- **watchCourseSessionReservations / watchDateCapacityOverrides** — **일부 중복 잔존**  
  - **ReservationSummaryProvider**: setContext 시 1회 구독 (courseId, placeId, 기간).  
  - **compact_calendar_widget**: 자체적으로 `watchDateCapacityOverrides`, `watchCourseSessionReservations` 구독.  
  - 같은 (placeId, courseId, 기간)에 대해 **Provider와 위젯이 각각 구독**할 수 있음 → **중복 리드** 가능.  
  - **권장:** compact_calendar_widget은 동일 컨텍스트일 때 **ReservationSummaryProvider**만 사용하고, 자체 Firestore 구독 제거.
- **streamCourseOverrides**  
  - CourseProvider(주별 구독)와 ReservationSummaryProvider(setContext 시 동일 주 구독) 둘 다 사용 시 **같은 쿼리 2 리스너**.  
  - **권장:** ReservationSummaryProvider는 CourseProvider.getOverridesForWeek 등으로 1회/캐시 값을 쓰거나, overrides는 CourseProvider 단일 구독만 두고 공유.

### 6.2 구독 수명·해제
- **CourseProvider**: bookingWeekOpens는 (placeId, courseId)당 1구독. subscribeToOverrides는 주별 구독; placeId 변경 시 `_cancelAllOverrideSubscriptions()` 호출.  
  - “wanted에 없는 주를 cancel하지 않고 유지”하는 전략이라, 오래 쓰면 불필요한 주 구독이 남을 수 있음. 필요 시 미사용 주 정리 정책 검토.
- **ReservationSummaryProvider.setContext**: placeId/courseId/기간 변경 시 기존 3개 구독 cancel 후 재구독. 적절함.
- **ReservationProvider**: `startWatchingReservations` 시 1개 스트림. `clear()` 시 cancel. 적절함.
- Screen/위젯에서 직접 `.listen()` 하는 경우(compact_calendar_widget의 capacity/session 구독 등)는 dispose에서 cancel 확인됨. 가능하면 Provider 단일 구독으로 이전 시 누수 위험 감소.

### 6.3 쿼리·인덱스
- `firestore.indexes.json`에 sessionReservations(courseId, placeId, date), (courseId, date), courseOverrides(placeId, courseId, type, date) 등 정의됨. 현재 쿼리와 부합.
- **한 번만 필요한 데이터**는 `get()` / `.first` 사용, **실시간 필요**할 때만 `snapshots()` 사용. session_detail_screen 등에서 일회성 조회는 적절히 사용 중.

---

## 요약 액션

| 우선순위 | 항목 | 조치 |
|----------|------|------|
| 1 | 모델 위치 | `Story`를 `lib/providers/story_provider.dart` → `lib/models/story.dart`로 이동. FirestoreService, StoryFirestoreService, StoryProvider import 수정. |
| 2 | 계층 역전 | Service가 Provider 참조 제거(Story 이동으로 Firestore/Story 서비스 해소). FCM은 장기적으로 콜백/이벤트로 Provider 갱신. |
| 3 | Screen → Service 직접 의존 | 새/수정 화면부터 Provider만 사용. 기존 화면은 “데이터/액션”을 해당 Provider로 올려서 Provider 경유로 전환. |
| 4 | 프로바이더 비즈니스 로직 | ReservationProvider 정렬·결과 파싱·낙관적 업데이트 → ReservationService. ReservationSummaryProvider 집계/오버레이 → Service. CourseProvider 정책/오버라이드 구독 → CourseService. |
| 5 | Firebase 중복 구독 | bookingWeekOpens, sessionReservations, capacityOverrides 등 동일 파라미터 구독을 Provider 단일 구독으로 모으고, 화면/위젯은 Provider만 watch. |
| 6 | 서비스 가독성 | MemberService, AuthService 등 대형 서비스는 역할별 메서드 그룹·주석 또는 파일 분할로 유지보수성 개선. |

이 순서로 적용하면 Provider–Service–Model 관계가 정리되고, 화면은 Provider만 참조하는 구조로 확장하기 쉬워집니다.
