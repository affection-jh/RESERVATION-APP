# 부매니저(Submanager) 시스템 전체 점검

## 1. 요약

- **역할**: `places/{placeId}/members/{uid}` 의 `role: 'submanager'` + `manageableCourseIds: string[]`
- **권한**: 매니저와 동일하게 관리자 화면 진입, 단 **지정된 코스**에만 멤버 목록·일정 편집·멤버 등록 가능
- **제한**: 플레이스 문서 수정 불가, 전체 멤버 목록 미로드, 코스 추가 불가

---

## 2. 백엔드 (Firebase Functions) 점검

| 항목 | 상태 | 비고 |
|------|------|------|
| `createEnrollmentsFromPendingMembers` | ✅ | pending `role`이 subManager면 member 문서에 `role: 'submanager'`, `manageableCourseIds` from `allowedCourseIds` |
| `inviteSubManagerForCourse` | ✅ | 코스별 부매니저 초대, pending/기존 멤버에 `allowedCourseIds`/`manageableCourseIds` 병합 |
| `registerMemberByAdmin` | ✅ | 부매니저 호출 시 `courseEnrollments`를 `manageableCourseIds`로 필터 후 등록 |
| **`addEnrollmentForExistingMember`** | ✅ **수정됨** | 부매니저 호출 시 등록 코스를 `manageableCourseIds`로 제한 (미적용 시 다른 코스 등록 가능했음) |
| **`updateCourseSchedule`** | ✅ **수정됨** | 부매니저 호출 시 `courseId`가 `manageableCourseIds`에 있을 때만 허용 |
| `deleteCourse` | ✅ | 코스 삭제 후 해당 코스를 가진 부매니저의 `manageableCourseIds`에서 제거, 비면 `role: 'member'` 전락 |
| `demoteSubManagerToMemberIfNoCourses` | ✅ | Callable: 부매니저이고 `manageableCourseIds` 비면 `role: 'member'`로 갱신 |
| **`removeMemberFromPlace`** | ✅ **수정됨** | 호출자는 매니저/소유자만 허용 (부매니저 호출 시 permission-denied) |
| **`deletePlace`** | ✅ **수정됨** | 호출자는 매니저/소유자만 허용 (부매니저 호출 시 permission-denied) |
| **`deleteCourse`** | ✅ **수정됨** | 부매니저 호출 시 `courseId`가 `manageableCourseIds`에 있을 때만 허용 |
| **`cancelEnrollment`** | ✅ **수정됨** | 부매니저 호출 시 해당 `courseId`가 `manageableCourseIds`에 있을 때만 수강 취소 허용 |
| **`upsertCourseOverride`** (course_override.ts) | ✅ **수정됨** | 부매니저 호출 시 `courseId`가 `manageableCourseIds`에 있을 때만 비정기 일정 편집 허용 |
| **`batchCreateReservations`** | ✅ **수정됨** | assertAdminForPlaceUid + 부매니저 시 `courseId`가 `manageableCourseIds`에 있을 때만 허용 |
| **`batchMoveReservations`** | ✅ **수정됨** | assertAdminForPlaceUid + 부매니저 시 이동 대상 예약의 `courseId`가 `manageableCourseIds`에 있을 때만 처리 |
| **`batchCancelReservations`** | ✅ **수정됨** | 부매니저 시 취소 대상 예약의 `courseId`가 `manageableCourseIds`에 있을 때만 취소 처리 |
| `assertAdminForPlaceUid` / `admin_auth` | ✅ | `canManagePlace`에서 `manager`·`submanager` 모두 관리자로 통과 |

---

## 3. Firestore 규칙 점검

| 항목 | 상태 | 비고 |
|------|------|------|
| **`places/{placeId}` update/delete** | ✅ **수정됨** | `isPlaceManagerOnly(placeId)` 사용 → **매니저만** 플레이스 문서 수정/삭제 가능 (부매니저 불가) |
| **`places/{placeId}/courses/{courseId}`** | ✅ **수정됨** | `canWriteCourse(placeId, courseId)` 도입 → 매니저는 전체, 부매니저는 `manageableCourseIds`에 포함된 코스만 create/update/delete |
| **`courseOverrides/{overrideId}`** | ✅ **수정됨** | create/update/delete 시 문서의 `placeId`·`courseId`로 `canWriteCourse` 검사 → 부매니저는 관리 코스 비정기 일정만 쓰기 가능 |
| `places/.../members` | ✅ | 매니저·부매니저 모두 create/update/delete 가능 (역할 변경은 앱/서버에서만) |
| `places/.../pendingMembers` | ✅ | isPlaceManager(placeId) → 매니저·부매니저 초대 가능 (실제 등록 코스는 Callable에서 제한) |

---

## 4. Flutter 클라이언트 점검

### 4.1 인증·멤버십

| 항목 | 상태 | 비고 |
|------|------|------|
| `AuthProvider.getPlaceMemberForPlace` | ✅ | placeId별 PlaceMember (role, manageableCourseIds) |
| `AuthProvider.isSubManagerForPlace` | ✅ | 부매니저 여부 |
| `AuthProvider._maybeDemoteSubManagersWithNoCourses` | ✅ | 관리 코스 0개면 Callable 호출 후 멤버십 재로드 |
| `loadPlaceMembershipsForCurrentUser` / 스트림 | ✅ | 로드·스트림 수신 후 전락 체크 및 필요 시 재로드 |
| `MemberService.demoteSubManagerToMemberIfNoCourses` | ✅ | Callable 호출 |

### 4.2 멤버 목록 (30명 롤링 윈도우)

| 항목 | 상태 | 비고 |
|------|------|------|
| `MemberProvider.setPlaceId(..., isSubManagerForPlace: true)` | ✅ | 전체 멤버 스트림 미구독, 코스별 enrollments 기반만 |
| `_updateCourseOnlyMembers` / `_subscribeCourseOnlySegment` | ✅ | 선택 코스(들)의 30명 세그먼트 구독·전환 |
| `loadMoreMembers` / `hasMoreMembers` | ✅ | 부매니저 모드에서 다음 30명 세그먼트 로드 |
| `MemberService.watchPlaceMembersByUserIds` / `getPlaceMembersByUserIds` | ✅ | 최대 30명 userId 기준 스트림·배치 조회 |

### 4.3 관리 화면

| 항목 | 상태 | 비고 |
|------|------|------|
| Admin 진입 | ✅ | `managedPlaceIdsFromMemberships`에 부매니저 플레이스 포함 → 진입 가능 |
| **Admin 마이페이지** | ✅ | 부매니저: more_vert 숨김(플레이스 수정 불가), "관리중인 코스", `manageableCourseIds` 필터, 코스 추가 버튼 없음 |
| **Admin 홈** | ✅ | 캘린더·빈 상태: 관리 코스만 표시, 코스 추가 버튼 null, 비정기 일정 편집 시 `allowedCourseIds` 전달 |
| **Admin 멤버** | ✅ | 부매니저: "전체" 탭 숨김, 코스별만, 코스 목록 `manageableCourseIds` 필터, `setPlaceId(..., isSubManagerForPlace: true)` |
| **코스 편집** | ✅ | "매니저 관리"(부매니저 칩·부매니저 추가)는 매니저만 표시; 정기 일정 편집은 진입 경로가 관리 코스뿐이므로 관리 코스만 편집 |
| **비정기 일정** | ✅ | `WeeklyOverrideScheduleScreen(allowedCourseIds: placeMember.manageableCourseIds)` 로 관리 코스만 편집 |
| **멤버 선택 사이드 패널** | ✅ | 부매니저일 때 `setPlaceId(..., isSubManagerForPlace: true)`, 코스 탭만·해당 코스 선택 |

### 4.4 기타

| 항목 | 상태 | 비고 |
|------|------|------|
| `MemberView` / `card_widgets` 역할 칩 | ✅ | 부매니저일 때 "부매니저" 표시 |
| `member_detail_bottom_sheet` 제거 | ✅ | 매니저·부매니저·소유자 제거 불가 메시지 |
| `empty_state_card` | ✅ | `buttonText`·`onPressed` null 허용 (부매니저 빈 상태용) |

---

## 5. 이번 점검에서 수정한 항목

1. **Functions `addEnrollmentForExistingMember`**  
   - 호출자가 부매니저일 때 등록할 코스를 `manageableCourseIds`로 필터.  
   - 필터 후 0개면 `invalid-argument` 에러.

2. **Functions `updateCourseSchedule`**  
   - 호출자가 부매니저일 때 `courseId`가 `manageableCourseIds`에 없으면 `permission-denied` (지정 관리 코스만 정기 일정 편집).

3. **Firestore 규칙**  
   - **Place 문서**: `update`/`delete`를 `isPlaceManagerOnly(placeId)`로 제한 → 부매니저는 플레이스 문서 수정 불가.  
   - **Courses**: `canWriteCourse(placeId, courseId)` 도입 → 부매니저는 `manageableCourseIds`에 포함된 코스만 create/update/delete.  
   - **courseOverrides**: create/update/delete 시 문서의 `placeId`·`courseId`로 `canWriteCourse` 적용 → 부매니저는 관리 코스 비정기 일정만 쓰기 가능.

---

## 6. 정리

- **서버**: 부매니저는 `registerMemberByAdmin`, `addEnrollmentForExistingMember`, `updateCourseSchedule`에서 모두 관리 코스로 제한됨.
- **규칙**: 플레이스 수정은 매니저만, 코스·비정기 일정 쓰기는 매니저 전체 / 부매니저는 `manageableCourseIds`만.
- **클라이언트**: 관리 화면·멤버 목록·일정 편집·멤버 등록이 관리 코스 기준으로만 노출·동작하고, 관리 코스 0개 시 전락 호출 및 재로드로 일반 멤버로 전환됨.

---

## 7. 2차 점검에서 수정한 항목 (Callable별 부매니저 제한 보강)

| Callable | 수정 내용 |
|----------|-----------|
| `cancelEnrollment` | 부매니저는 `manageableCourseIds`에 포함된 코스의 수강만 취소 가능 |
| `removeMemberFromPlace` | 부매니저 호출 시 permission-denied (매니저/소유자만 멤버 제거 가능) |
| `deletePlace` | 부매니저 호출 시 permission-denied (매니저만 플레이스 삭제 가능) |
| `deleteCourse` | 부매니저는 `manageableCourseIds`에 포함된 코스만 삭제 가능 |
| `upsertCourseOverride` | 부매니저는 `manageableCourseIds`에 포함된 코스의 비정기 일정만 편집 가능 |
| `batchCreateReservations` | placeId 기준 assertAdminForPlaceUid + 부매니저 시 courseId가 manageableCourseIds에 있을 때만 허용 |
| `batchMoveReservations` | assertAdminForPlaceUid + 부매니저 시 이동 대상 예약의 courseId가 manageableCourseIds에 있을 때만 처리 (그 외는 결과에 권한 없음) |
| `batchCancelReservations` | 부매니저 시 취소 대상 예약의 courseId가 manageableCourseIds에 있을 때만 취소 (그 외는 결과에 권한 없음) |

---

## 8. 중대 이슈 점검 (3차)에서 수정·확인한 항목

| 구분 | 항목 | 내용 |
|------|------|------|
| **Functions** | `createReservation` | 관리자가 타인 대리 예약 시 기존 `assertAdminUid`만 사용 → **수정**: `assertAdminForPlaceUid(placeId)` + 부매니저일 때 `courseId in manageableCourseIds` 검사 추가. |
| **Functions** | `inviteSubManagerForCourse` | 주석상 "매니저만 호출 가능"이나 코드는 assertAdminForPlaceUid만 사용 → **수정**: 호출자가 부매니저면 `permission-denied` (부매니저 추가는 매니저만). |
| **Flutter** | 멤버 제거 버튼 | 부매니저도 "멤버 제거" 버튼 노출 → **수정**: `_canRemoveFromPlace`에서 `authProvider.isSubManagerForPlace(place.id)`이면 false 반환해 버튼 숨김. |
| **확인** | `deleteUserAccount`, `searchPlaces` | place/course 스코프 없음 또는 본인만 처리 → 부매니저 별도 제한 불필요. |
| **확인** | 그 외 Callable | createReservation 제외한 관리자용 Callable은 이전 점검에서 모두 place/course 제한 적용됨. |

---

## 9. 논리 오류 점검: 부매니저 `manageableCourseIds` 빈 배열 시 거부

**이슈**: `if (manageableCourseIds.length > 0 && !manageableCourseIds.includes(courseId))` 조건만 쓰면, 부매니저의 `manageableCourseIds`가 **비어 있을 때**는 조건이 false라 **거부되지 않고** 통과함. 관리 코스가 0개인 부매니저는 전락 대상이므로, 그 전까지라도 어떤 코스에도 권한을 주면 안 됨.

**수정**: 다음 Callable에서 **부매니저이면서 `manageableCourseIds.length === 0`이면** `permission-denied`(관리할 코스가 없습니다)로 거부하도록 추가함.

- `createReservation` (관리자 대리 예약)
- `batchCreateReservations`
- `cancelEnrollment`
- `updateCourseSchedule`
- `deleteCourse`
- `upsertCourseOverride` (course_override.ts)
- `removeSubManagerFromCourse`
- `addEnrollmentForExistingMember`
- `registerMemberByAdmin`
- `batchMoveReservations`
- `batchCancelReservations` (관리자로 호출 시에만, 빈 리스트면 거부)

---

## 10. 접속·점검 시 자동 강등 (0개면 member로)

- **클라이언트**: `loadPlaceMembershipsForCurrentUser()` 직후, 스트림 수신 직후 `_maybeDemoteSubManagersWithNoCourses()` 호출 → 부매니저이고 `manageableCourseIds.isEmpty`면 Callable 호출 후 멤버십 재로드. (접속/Admin 진입/AppStartup에서 로드 시 실행.)
- **서버**: `admin_auth.demoteSubManagerToMemberIfNoCoursesInternal(db, placeId, uid)` 공용 헬퍼 추가. 아래 Callable에서 **"관리할 코스가 없습니다" throw 직전**에 해당 헬퍼 호출 → 점검 시 서버에서 즉시 member로 강등, 다음 로드부터 반영.
  - `createReservation`, `batchCreateReservations`, `cancelEnrollment`, `updateCourseSchedule`, `deleteCourse`, `registerMemberByAdmin`, `removeSubManagerFromCourse`, `addEnrollmentForExistingMember`, `batchMoveReservations`, `batchCancelReservations`, `upsertCourseOverride`.

---

이 문서는 점검 시점(부매니저 시스템 전체 점검) 기준이며, 이후 규칙/함수/앱 변경 시 이 문서도 함께 갱신하는 것을 권장합니다.
