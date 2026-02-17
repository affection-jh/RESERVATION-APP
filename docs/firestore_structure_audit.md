# Firestore 구조 점검 및 정합성 보고서

점검일: 2025-02  
기준 구조:
```
User / notifications          → users/{userId}/notifications
Place / members               → places/{placeId}/members
      /courses                → places/{placeId}/courses (정책 및 정보)
      /stories                → places/{placeId}/stories
      /pendingMembers         → places/{placeId}/pendingMembers
      /reservations           → places/{placeId}/reservations
Enrollments                   → enrollments (top-level)
SessionReservations           → sessionReservations (top-level)
courseOverrides               → courseOverrides (top-level)
```

---

## 1. 정상적으로 구조에 맞는 항목

| 컬렉션/경로 | Flutter | Functions | 비고 |
|-------------|---------|-----------|------|
| users | ✅ UserService | ✅ index.ts | |
| users/{userId}/notifications | ✅ NotificationFirestoreService | ✅ course_override, index | |
| places | ✅ PlaceFirestoreService | ✅ index, course_override, course_catalog | |
| places/{placeId}/courses | ✅ CourseService | ✅ index, course_catalog | |
| places/{placeId}/stories | ✅ StoryFirestoreService | ✅ deletePlace | |
| places/{placeId}/members | ✅ MemberService | ⚠️ admin_auth는 adminUsers 사용 | **admin_auth 마이그레이션 필요** |
| places/{placeId}/reservations | ✅ ReservationService | ✅ index, course_override | |
| enrollments | ✅ EnrollmentService | ✅ index, course_override, reservation_ops | |
| sessionReservations | ✅ ReservationService | ✅ index, course_override, reservation_ops | |
| courseOverrides | ✅ CourseService | ✅ index, course_override | |

---

## 2. 구조 불일치 (수정 필요)

### 2.1 pendingMembers 경로 불일치

**기준 구조:** `places/{placeId}/pendingMembers/{docId}` (서브컬렉션)

| 위치 | 현재 사용 경로 | 올바른 경로 |
|------|----------------|-------------|
| Flutter member_service | ✅ places/{placeId}/pendingMembers | - |
| Flutter auth_service (requestPlaceAccess) | ❌ pendingMembers (top-level) | places/{placeId}/pendingMembers |
| Functions (전체) | ❌ pendingMembers (top-level) | places/{placeId}/pendingMembers 또는 collectionGroup |

**영향 함수:** createEnrollmentsFromPendingMembers, cancelEnrollment, removeMemberFromPlace, deletePlace, deleteUserAccount, deleteCourse, bulkMoveReservations, course_override (비정기 세션 삭제 등)

**수정 방안:**
- 특정 문서 조회: `db.collection('places').doc(placeId).collection('pendingMembers').doc(placeId_normalizedPhone)`
- 전화번호로 검색 (createEnrollmentsFromPendingMembers): `db.collectionGroup('pendingMembers').where('phoneNumber', '==', normalizedPhone)`
- placeId로 삭제: `deleteCollectionByPath(db, `places/${placeId}/pendingMembers`)`

### 2.2 adminUsers → places/{placeId}/members

**기준 구조:** 관리자 여부는 `places/{placeId}/members`에서 role으로 판단

| 위치 | 현재 | 수정 후 |
|------|------|---------|
| admin_auth.ts | adminUsers (top-level, userId, placeIds) | collectionGroup('members') 또는 places/{placeId}/members/{uid} |
| index.ts (onPlaceMembershipCreated 알림) | adminUsers.where(placeIds) | places/{placeId}/members에서 canManagePlace 검색 |
| deleteUserAccount | adminUsers.doc(uid) | places/{placeId}/members 중 해당 uid 검색 |

**수정 방안:**
- `assertAdminUid`: collectionGroup('members').where(FieldPath.documentId(), '==', uid) → role in [manager, subManager]
- `isAdminForPlaceUid`: places/{placeId}/members/{uid}.get() → exists && canManagePlace

### 2.3 placeMemberships (레거시)

**기준 구조에 없음.** Functions의 `onPlaceMembershipCreated`, `onPlaceMembershipUpdated`는 `placeMemberships/{id}` 트리거 사용.

- 현재 Flutter는 **places/{placeId}/members**만 사용 (MemberService)
- **placeMemberships**는 "가입 요청(pending) → 승인(approved)" 워크플로우용일 가능성
- 정리: placeMemberships를 아직 사용 중이면 유지, 미사용이면 트리거 비활성화 검토

---

## 3. 구조 외 추가 컬렉션 (기준에 없음)

| 컬렉션 | 용도 | 권장 |
|--------|------|------|
| adminUsers | 관리자 권한 (레거시) | places/{placeId}/members로 마이그레이션 |
| coursePolicies | 코스별 예약 정책 | courses 문서에 통합 또는 유지 |
| bookingWeekOpens | 주차별 예약 오픈 | 별도 유지 (업무용) |
| promotions | 프로모션 | 구조에 없으면 삭제/보류 |

---

## 4. Index 점검

`firestore.indexes.json`:
- reservations, sessionReservations, enrollments, courseOverrides, notifications ✅
- **collectionGroup('pendingMembers')** 전화번호 검색용 인덱스 필요 (구조 변경 시)
- **collectionGroup('members')** uid 검색용 인덱스 필요 (admin_auth 마이그레이션 시)

---

## 5. 수정 완료 사항

1. **admin_auth.ts**: adminUsers → places/{placeId}/members (완료)
2. **pendingMembers 경로**: Functions + Flutter auth_service → places/{placeId}/pendingMembers (완료)
3. **deleteUserAccount**: adminUsers → getManagedPlaceIdsForUid, pendingMembers → collectionGroup (완료)
4. **firestore.indexes.json**: pendingMembers(phoneNumber), members(__name__) collection group 인덱스 추가 (완료)

## 6. 남은 검토 항목

- **placeMemberships 트리거**: 사용 여부 확인 후 유지/제거 결정
