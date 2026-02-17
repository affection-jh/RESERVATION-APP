# 컬렉션·모델·규칙·함수 연동 점검 보고서

점검일: 2025-02 (재점검 반영)  
컬렉션 구조, 모델 매핑, Firestore 규칙, Cloud Functions, 인덱스를 전반 점검한 결과입니다.

---

## 1. 이미 수정 완료

| 항목 | 상태 |
|------|------|
| reservations 규칙 | top-level `reservations` 규칙 추가 완료 |
| admin_auth.ts members 쿼리 | `where('userId', '==', uid)` 로 변경 완료 |
| members 문서 userId 저장 | setPlaceMember에서 userId 저장 완료 |
| MEMBER_DB_STRUCTURE.md | reservations 경로 top-level로 수정 완료 |

---

## 2. 추가 점검 — 검토/수정 필요

### 2.1 reservations 인덱스 — placeId 기반 쿼리 ✅ 추가 완료

| 쿼리 | 필요한 인덱스 | firestore.indexes.json |
|------|----------------|------------------------|
| `placeId` + `userId` + `orderBy reservedDate` | placeId, userId, reservedDate | ✅ 추가 |
| `placeId` + `reservedDateString` (>=) + `orderBy reservedDateString` | placeId, reservedDateString | ✅ 추가 |
| `placeId` + `courseId` + `dayOfWeek` + `startTime` + `reservedDateString` | 복합 | ✅ 추가 |

### 2.2 notifications collectionGroup — placeId 인덱스

- `deletePlace`에서 `collectionGroup('notifications').where('placeId', '==', placeId)` 사용
- 기존 인덱스: `isAdminNotification`, `userId`, `createdAt`만 존재
- placeId 단독 쿼리용 인덱스가 없을 수 있음 → 오류 발생 시 인덱스 추가

### 2.3 enrollments 생성 권한 — place manager vs adminUsers

| 규칙 | 조건 |
|------|------|
| enrollments create/update/delete | `isAdmin()` = `hasAdminUserDoc()` |

- UI에서는 place manager(places/members 역할)만으로도 멤버 등록 가능
- 실제로는 `adminUsers` 문서가 있어야 enrollment 생성 가능
- adminUsers가 없는 place manager가 기존 유저를 멤버로 등록하면 → enrollment 생성 시 권한 거부 가능
- **검토**: 모든 place manager가 adminUsers를 갖는 구조인지, 또는 `isPlaceManager` 기반으로 enrollment 쓰기를 허용할지 결정 필요

---

## 3. 문서·구조 정리 필요

### 3.1 pendingMembers — 규칙 중복

| 경로 | 규칙 위치 | 실제 사용 |
|------|-----------|-----------|
| `places/{placeId}/pendingMembers/{inviteId}` | places 블록 내부 | ✅ 사용 중 |
| `pendingMembers/{pendingId}` (top-level) | 별도 match 블록 | ❌ 미사용 |

- top-level `pendingMembers` 규칙은 미사용 경로에 대한 것
- 혼동 방지를 위해 제거하거나 `// 레거시, 실제는 places 하위 사용` 주석 추가 권장

---

### 3.2 coursePolicies — 이중 저장

| 저장 위치 | 사용처 | 비고 |
|-----------|--------|------|
| `places/{placeId}/courses/{courseId}` 내 `policy` | Flutter CourseService, CoursePolicy | 정상 사용 |
| `coursePolicies/{courseId}` | Functions (place/course 삭제 시) | 정리용 |

- Flutter/앱은 courses 문서의 policy만 사용
- `coursePolicies`는 코스/플레이스 삭제 시 정리용으로만 사용
- 마이그레이션 후 `coursePolicies` 미사용이면 해당 로직 제거 검토

---

### 3.3 MEMBER_DB_STRUCTURE.md

- ~~`places/{placeId}/reservations`~~ → top-level `reservations`로 수정 완료

---

## 4. 정상 연동 컬렉션

| 컬렉션/경로 | Flutter | Functions | 규칙 | 인덱스 |
|-------------|---------|-----------|------|--------|
| users | UserService | index.ts | ✅ | - |
| users/{uid}/fcmTokens | FcmService | - | ✅ | - |
| users/{uid}/notifications | NotificationFirestoreService | index, course_override | ✅ | collectionGroup |
| adminUsers | - | index, admin_auth | ✅ | - |
| places | PlaceFirestoreService | index, course_catalog | ✅ | - |
| places/{placeId}/members | MemberService | admin_auth | ✅ | collectionGroup userId |
| places/{placeId}/pendingMembers | MemberService, AuthService | index, createEnrollments... | ✅ | collectionGroup phoneNumber |
| places/{placeId}/courses | CourseService | index, course_catalog | ✅ | - |
| places/{placeId}/stories | StoryFirestoreService | deletePlace | ✅ | - |
| enrollments | EnrollmentService | index, course_override | ✅ | userId+courseId, userId+placeId |
| sessionReservations | ReservationService | index, course_override | ✅ | 여러 복합 |
| courseOverrides | CourseService | index, course_override | ✅ | placeId+courseId+type+date |
| coursePolicies | - | deletePlace, deleteCourse | ✅ | - |
| bookingWeekOpens | CourseService | index, createReservation | ✅ | placeId |
| promotions | - | deletePlace | ✅ | - |

---

## 5. 미사용/레거시

| 컬렉션 | 상태 | 규칙 |
|--------|------|------|
| placeMemberships | 미사용 | deny all |
| onPlaceMembershipCreated/Updated 트리거 | placeMemberships 기준 → 미호출 | - |

---

## 6. 모델 ↔ Firestore 필드 점검

### 5.1 CourseEnrollment

- Firestore: `validFrom`, `validUntil` 등 Timestamp/ISO 문자열 혼용
- Flutter: `DateTime.parse()` 또는 `Timestamp.toDate()` 처리
- Functions: `Timestamp.fromDate()` 사용 → 저장 형식 일치

### 5.2 PlaceMember

- `userId`를 문서에 저장하도록 수정 완료
- `role`: `manager` | `submanager` | `member` (소문자)

### 5.3 PendingMember

- `allowedCourseIds` (배열)
- `createdAt`: Timestamp 또는 ISO 문자열 처리
- `placeId`는 경로에서 추출 가능, 문서 필드는 선택

### 5.4 Course / CoursePolicy

- 정책은 `places/{placeId}/courses/{courseId}` 문서의 `policy` 필드에 embed
- `coursePolicies`는 삭제 시 정리용으로만 사용

---

## 7. 권한 요약

| 액션 | reservations | enrollments | members | pendingMembers |
|------|-------------|-------------|---------|----------------|
| 클라이언트 읽기 | 본인/admin | 본인/admin | 본인/매니저 | 본인(전화)/매니저 |
| 클라이언트 쓰기 | ❌ | admin | 매니저 | 매니저 |
| Functions | Admin SDK | Admin SDK | Admin SDK | Admin SDK |

---

## 8. 권장 조치 순서

1. **완료**: top-level `reservations` 규칙, `admin_auth` userId 쿼리, members userId 저장
2. **점진적**: 기존 members 문서에 `userId` 마이그레이션
3. **인덱스 검토**: reservations placeId 기반 쿼리, notifications placeId collectionGroup — 필요 시 추가
4. **권한 검토**: place manager가 adminUsers 없이 enrollment 생성 가능해야 하는지 결정
5. **선택**: top-level `pendingMembers` 규칙 제거 또는 주석 처리
